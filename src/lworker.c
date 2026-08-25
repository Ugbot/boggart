/* lworker.c -- real OS worker threads: N threads, N uv loops, N boggart
 * interpreters. The next tier up from the swarm, which is N coroutines on ONE
 * loop and ONE lua_State -- cooperative, one CPU. A worker is for the work
 * that would stall that loop: a long tool, a local model, a big file walk.
 *
 * What a worker is: an OS thread that builds a full boggart interpreter --
 * counting allocator, luaL_openlibs, boggart_open_libs, boggart_boot(L,
 * "worker", version) -- with its OWN uv_loop_t, runs a source string, and
 * exchanges messages with the spawner over two SPSC rings.
 *
 * ---- the hard parts, named -------------------------------------------------
 *
 * 1. NOTHING Lua crosses the thread boundary. A lua_State is single-threaded
 *    by construction; a function or table from the main state is meaningless
 *    (and fatal) in another. So source crosses as TEXT and is compiled in the
 *    worker; data crosses as bytes -- strings and numbers only. Tables are
 *    serialized (json.encode / json.decode) by the caller. This is why the
 *    API looks the way it does, not a convenience shortcut.
 *
 * 2. The loop. luv binds a lua_State to ONE loop (registry luv_ctx). When
 *    ctx->loop is NULL at luaopen_luv, luv creates a fresh inner loop for
 *    that state and registers loop_gc to close it at lua_close. We rely on
 *    exactly that: the worker thread opens luv FIRST, so require("uv") inside
 *    the worker is its own loop and never the main thread's. The main loop is
 *    touched from the worker by uv_async_send only -- the one libuv call that
 *    is documented threadsafe.
 *
 * 3. Thread ownership of the C libs. The bus (lswarm.c) and the mcp client
 *    (lmcp.c) are process globals owned by the main thread; a worker touching
 *    them is a data race, so worker states get erroring stubs for swarm, mcp and
 *    auth.set/clear (see deny_in_worker). http is NOT denied: curl's multi is now
 *    per-loop (lhttp.c keys a CURLM off each state's luv loop), so a worker's
 *    http.begin/pump own a private curl_multi on the worker's own loop -- N
 *    threads, N loops, N multis -- which is what lets a worker run a model turn.
 *    db stays available: SQLite is built
 *    THREADSAFE=2, safe with one connection per thread, and connections are
 *    per-userdata -- and the main state's bog.db is a Lua value, which by (1)
 *    cannot cross at all, so "never share the main connection" is structural,
 *    not a convention. A worker that wants the store opens its own connection
 *    (bog.store.open()), which is the same discipline jwriter.c uses.
 *
 * 4. The counting allocator. lmem.c counts into ONE process-global size_t.
 *    N states incrementing it concurrently is not "a racy statistic": it is
 *    an unsynchronized read-modify-write, i.e. undefined behaviour, and lost
 *    updates corrupt the counter *permanently* -- and the tool memory limit
 *    does before/after deltas on it, so a corrupted count misfires the limit.
 *    Therefore worker states do NOT use boggart_newstate(): each gets its own
 *    allocator counter via lua_Alloc's ud pointer (wk_alloc below), and its
 *    sys.membytes is overridden to read its own numbers. lmem.c and the main
 *    state are untouched; no thread ever writes another thread's counter.
 *
 * 5. Once-init and exit. curl_global_init runs at luaopen_boggart_http; the
 *    main state did that at startup, long before any thread exists, and curl
 *    >= 7.84 makes the call itself threadsafe anyway (both our pinned Windows
 *    8.20 and the macOS/Linux system libcurl qualify). sqlite3_initialize
 *    happened on the main thread when the store opened, and THREADSAFE=2
 *    keeps its global structures mutexed. The lauth credential cache is
 *    lazily loaded on first read, so spawn() force-loads it on the MAIN
 *    thread first (warm_auth) and workers only ever read it. libuv's own
 *    process-global signal setup is behind uv_once. At exit, an atexit
 *    handler (same discipline as jwriter.c) stops and joins every live
 *    worker so no thread outlives main() into static teardown.
 *
 * ---- threading model: ownership, not locking (jwriter.c's idiom) -----------
 *
 * Two bounded SPSC rings per worker, each guarded by two counting semaphores
 * (free slots / filled slots), exactly like jwriter.c and for the same
 * reason: uv_sem_post/uv_sem_wait is the happens-before edge that publishes
 * slot contents, so there are no atomics and no memory-ordering reasoning.
 *   in  ring: producer = main thread (worker.post),   consumer = worker.
 *   out ring: producer = worker (worker.post inside), consumer = main
 *             (recv / join / the on_message uv_async callback -- all of
 *             which run on the main thread, so it is still one consumer).
 * head is touched only by the producer, tail only by the consumer. A slot's
 * string is malloc'd by the producer and freed by the consumer: each record
 * belongs to exactly one thread at a time.
 *
 * Control flow that cannot ride a ring uses dedicated semaphores:
 *   ready    worker posts once its loop + wakeup async exist; spawn() waits,
 *            so post()/stop() can never uv_async_send an uninitialized handle.
 *   stop_sem stop() posts it; the worker trywaits it at every check point.
 *            A semaphore rather than a flag because a plain int written by
 *            one thread and read by another has no ordering at all.
 *   exit_sem worker posts it after writing its result fields; status() on the
 *            main thread trywaits it, and the post/wait pair is what makes
 *            the result fields safely readable.
 *
 * THE ONE LOCK, and why it is justified rather than reached for: the worker's
 * wakeup uv_async_t lives on the worker's loop and must be uv_close'd by the
 * worker before its loop dies -- but the main thread calls uv_async_send on
 * it at arbitrary times. send-after-close is use-after-free, and no ownership
 * argument can order "sender may touch it" against "owner wants to destroy
 * it": liveness of a genuinely shared object is the textbook case a mutex
 * exists for. It is a binary semaphore (`gate`) held for nanoseconds around
 * the send / the accepting=0 hand-off, never while blocking. jwriter.c never
 * needed this because nothing it shares has a destructor before atexit.
 *
 * Stop is COOPERATIVE. stop() posts stop_sem, drops a WKS_STOP sentinel in
 * the in ring (waking a recv() blocked on an empty ring -- and if the ring is
 * full the sentinel doesn't fit, but full means recv is not blocked and the
 * per-call stop_sem check catches it), and wakes the loop. A worker that calls
 * recv()/stopped() shuts down cleanly this way and its source may return a
 * normal result (ok=1).
 *
 * Kill is PREEMPTIVE (the safepoint hook). A worker spinning in pure Lua that
 * never calls recv()/stopped() is caught by a count hook installed on the
 * worker's OWN thread before it runs the source: every WK_HOOK_COUNT VM
 * instructions it trywaits kill_sem, and on success raises a Lua error that
 * unwinds the source's pcall (ok=0). This sidesteps the liveness gate the v1
 * comment worried about: lua_sethook is only ever called on the worker's own
 * state -- the main thread merely uv_sem_post(kill_sem), the same happens-before
 * edge everything else here rides, so no thread touches another's lua_State and
 * the lua_close race cannot arise. kill() also does the cooperative stop, so a
 * worker blocked in C (recv, sys.exec) is still woken. The honest residual: a
 * worker wedged in a C call that runs no VM instructions (a stuck syscall) is
 * not preemptible in-process -- that is the nuclear-teardown case, not this one.
 *
 * Pause/resume ride the same hook. pause() posts pause_sem; at the next
 * safepoint the worker parks on resume_sem (its thread blocks, holding its
 * stack). resume() posts resume_sem. Crucially BOTH stop() and kill() also post
 * resume_sem, so a parked worker unblocks on every wind-down path -- join, gc
 * and atexit can never deadlock on a pause. pause/resume must be balanced by the
 * caller: a resume with no matching pause leaves resume_sem raised, so the next
 * pause parks-then-immediately-wakes (the supervisor tracks state and does not).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "uv.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lworker.h"

/* bogembed.c -- how a boggart interpreter is assembled. No header exists for
 * these (the other callers declare them the same way). */
void boggart_open_libs(lua_State *L);
int boggart_boot(lua_State *L, const char *mode, const char *version);
int luaopen_luv(lua_State *L);
/* luv.c, LUALIB_API: the loop the given state's luv context is bound to. */
uv_loop_t *luv_loop(lua_State *L);
/* lbus.c: publish a worker lifecycle event onto the fabric. All our call sites
 * are on the main thread (spawn/kill/exit-delivery), so this dispatches inline;
 * a UI or `boggart trace` subscribed to "worker:*" then sees the pool. */
extern void bus_emit(const char *topic, const char *data, size_t len);
/* lhttp.c: tear down this state's curl_multi + socket polls, so a worker that
 * ran http (a model turn) can drain its loop and exit instead of hanging. */
extern void boggart_http_shutdown(lua_State *L);

/* ---- slots and rings ------------------------------------------------------ */

enum { WKS_STR = 0, WKS_NUM = 1, WKS_STOP = 2, WKS_EXIT = 3 };

typedef struct {
  int kind;
  char *str;    /* owned by the slot (WKS_STR), freed by the consumer */
  size_t len;
  double num;   /* WKS_NUM */
} wk_slot;

#define WK_CAP 256u            /* power of two: the wrap is a mask */
#define WK_MASK (WK_CAP - 1u)

typedef struct {
  wk_slot *slots;
  uint32_t head;               /* producer only */
  uint32_t tail;               /* consumer only */
  uv_sem_t space;              /* free slots; producer waits */
  uv_sem_t items;              /* filled slots; consumer waits */
  uint64_t stalls;             /* producer-only diagnostic */
} wk_ring;

static int ring_init(wk_ring *r) {
  r->slots = (wk_slot *)calloc(WK_CAP, sizeof(wk_slot));
  if (!r->slots) return -1;
  r->head = r->tail = 0;
  r->stalls = 0;
  if (uv_sem_init(&r->space, WK_CAP) != 0) { free(r->slots); r->slots = NULL; return -1; }
  if (uv_sem_init(&r->items, 0) != 0) {
    uv_sem_destroy(&r->space); free(r->slots); r->slots = NULL; return -1;
  }
  return 0;
}

/* Only after both sides are quiescent (post-join): frees whatever is still in
 * flight, which is legal then because thread-join is a happens-before edge. */
static void ring_destroy(wk_ring *r) {
  if (!r->slots) return;
  while (r->tail != r->head) {
    free(r->slots[r->tail & WK_MASK].str);
    r->tail++;
  }
  uv_sem_destroy(&r->space);
  uv_sem_destroy(&r->items);
  free(r->slots);
  r->slots = NULL;
}

/* Blocking push: used by the worker (backpressure on a worker is fine -- the
 * main thread drains from recv/join/the async callback, all of which make
 * progress). The MAIN thread never calls this; it uses ring_trypush, because
 * the main thread must never block on a worker's consumption. */
static void ring_push(wk_ring *r, const wk_slot *s) {
  if (uv_sem_trywait(&r->space) != 0) {
    r->stalls++;
    uv_sem_wait(&r->space);
  }
  r->slots[r->head & WK_MASK] = *s; /* ownership of s->str moves here */
  r->head++;
  uv_sem_post(&r->items); /* publishes the slot write to the consumer */
}

static int ring_trypush(wk_ring *r, const wk_slot *s) {
  if (uv_sem_trywait(&r->space) != 0) return -1;
  r->slots[r->head & WK_MASK] = *s;
  r->head++;
  uv_sem_post(&r->items);
  return 0;
}

static int ring_trypop(wk_ring *r, wk_slot *out) {
  if (uv_sem_trywait(&r->items) != 0) return -1;
  *out = r->slots[r->tail & WK_MASK];
  r->tail++;
  uv_sem_post(&r->space);
  return 0;
}

/* Blocking pop, for consumers entitled to block: the worker's recv() with no
 * timeout (stop() always wakes it -- see the header comment), and join(). */
static void ring_pop_wait(wk_ring *r, wk_slot *out) {
  uv_sem_wait(&r->items);
  *out = r->slots[r->tail & WK_MASK];
  r->tail++;
  uv_sem_post(&r->space);
}

/* ---- the worker ----------------------------------------------------------- */

typedef struct worker worker;

/* The main-loop delivery async (on_message mode). Allocated separately from
 * the worker and with .data left NULL on purpose: if the main state shuts
 * down before this closes, luv's loop_gc walks the loop and uv_close()s every
 * handle with luv_close_cb -- which returns immediately on NULL data instead
 * of misreading ours as a luv_handle_t. The wrapper then leaks a few dozen
 * bytes on that one shutdown path, which is the price of not crashing in
 * somebody else's __gc. */
typedef struct {
  uv_async_t a;      /* MUST be first: callbacks recover the wrapper by cast */
  lua_State *L;      /* the spawner's state; callback runs on its thread */
  int cbref;         /* registry ref of the Lua on_message callback */
  worker *w;
} wk_out_async;

struct worker {
  worker *next;              /* g_workers registry; main-thread-only */
  uv_thread_t thread;
  int thread_up;

  char *source; size_t srclen;
  char *version;
  wk_slot arg;               /* opts.arg, copied before the thread starts */
  int has_arg;

  wk_ring in;                /* main -> worker */
  wk_ring out;               /* worker -> main */

  uv_sem_t ready;
  uv_sem_t stop_sem;
  uv_sem_t exit_sem;
  uv_sem_t kill_sem;         /* safepoint kill; the worker's count hook trywaits it */
  uv_sem_t pause_sem;        /* main requests a pause; the hook trywaits it */
  uv_sem_t resume_sem;       /* release a pause; the paused hook blocks on it */
  uv_sem_t gate;             /* THE lock; see the header comment */
  int accepting;             /* guarded by gate once the worker is live */

  uv_async_t async_in;       /* wakeup, on the WORKER's loop */
  int async_in_closed;       /* worker-thread only */

  /* worker-thread-only while running; readable by main after exit_sem/join */
  lua_State *L;
  int want_loop;             /* worker registered onmessage */
  int wcbref;                /* worker-side onmessage ref, in the worker state */
  int stopped;               /* worker-local latch of stop_sem */
  int killed;                /* worker-local latch: the safepoint hook fired */
  int paused;                /* worker-local: set while blocked in the pause gate */
  int ok;                    /* 1 = source completed, 0 = error */
  int result_kind;           /* WKS_STR / WKS_NUM / -1 = nil */
  char *result_str; size_t result_len;
  double result_num;

  struct { size_t live, peak; } mem;  /* hard part 4: per-worker counter */

  /* main-thread-only bookkeeping */
  /* Display metadata, for worker.list(): so a UI -- or boggart doctor --
   * can see how many workers exist and roughly what each is doing, which the
   * handle-only API could not answer. Owned by the main thread: set once at
   * spawn, last updated only when an out-ring message is drained on the main
   * thread. The worker never writes these, so no lock is needed. */
  uint64_t id;
  char *label;
  char *kind;
  double started;
  char *last;
  int exit_flag;             /* latched from exit_sem */
  int saw_exit;              /* WKS_EXIT consumed from the out ring */
  int joined;
  wk_out_async *outa;        /* NULL unless on_message mode */
  struct pmsg { struct pmsg *next; wk_slot s; } *pend_head, *pend_tail;
};

/* Live workers, for atexit. Main-thread-only by construction: spawn is denied
 * inside workers, and spawn/join/__gc all run on the spawner's thread. */
static worker *g_workers = NULL;
static int g_atexit_done = 0;
static uint64_t g_worker_seq = 0;  /* monotonic ids; main-thread-only */

static const char *WK_SELF = "boggart.worker.self"; /* registry mark */

/* ---- per-worker counting allocator (hard part 4) -------------------------- */
/* Same body as lmem.c's counting_alloc, but the counter travels in ud, so N
 * workers never touch one global and the main state's g_live stays exact. */
static void *wk_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  struct { size_t live, peak; } *m = ud;
  if (nsize == 0) {
    if (ptr) m->live -= osize;
    free(ptr);
    return NULL;
  }
  void *np = realloc(ptr, nsize);
  if (!np) return NULL;
  if (ptr) m->live -= osize;
  m->live += nsize;
  if (m->live > m->peak) m->peak = m->live;
  return np;
}

/* ---- small helpers -------------------------------------------------------- */

static worker *wk_self(lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, WK_SELF);
  worker *h = (worker *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  return h;
}

/* string|number at idx -> slot. Returns 0 or -1 with an error pushed. */
static int slot_from_lua(lua_State *L, int idx, wk_slot *s) {
  memset(s, 0, sizeof(*s));
  int t = lua_type(L, idx);
  if (t == LUA_TNUMBER) {
    s->kind = WKS_NUM;
    s->num = lua_tonumber(L, idx);
    return 0;
  }
  if (t == LUA_TSTRING) {
    size_t len = 0;
    const char *p = lua_tolstring(L, idx, &len);
    s->kind = WKS_STR;
    s->str = (char *)malloc(len + 1);
    if (!s->str) { lua_pushliteral(L, "out of memory"); return -1; }
    memcpy(s->str, p, len);
    s->str[len] = '\0';
    s->len = len;
    return 0;
  }
  lua_pushliteral(L,
    "worker messages are strings and numbers only; tables cannot be shared "
    "between lua_States -- serialize with json.encode and decode on the other side");
  return -1;
}

static void slot_push_value(lua_State *L, const wk_slot *s) {
  if (s->kind == WKS_NUM) lua_pushnumber(L, s->num);
  else lua_pushlstring(L, s->str ? s->str : "", s->len);
}

static int traceback(lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  if (msg == NULL) msg = "(non-string error)";
  luaL_traceback(L, L, msg, 1);
  return 1;
}

/* ---- deny list (hard part 3) ---------------------------------------------- */

static int l_denied(lua_State *L) {
  return luaL_error(L, "%s is owned by the main thread and not available in a "
                       "worker; talk to the main thread with worker.post/recv",
                    lua_tostring(L, lua_upvalueindex(1)));
}

/* Replace a whole capability global with a table whose every lookup yields an
 * erroring function: reads stay strict-clean, use fails with a sentence. */
static int l_deny_index(lua_State *L) {
  lua_pushvalue(L, lua_upvalueindex(1)); /* the lib name */
  lua_pushcclosure(L, l_denied, 1);
  return 1;
}

static void deny_global(lua_State *L, const char *name) {
  lua_newtable(L);            /* the stub */
  lua_newtable(L);            /* its metatable */
  lua_pushstring(L, name);
  lua_pushcclosure(L, l_deny_index, 1);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, -2);
  lua_setglobal(L, name);
}

static void deny_field(lua_State *L, const char *lib, const char *field) {
  lua_getglobal(L, lib);
  if (lua_istable(L, -1)) {
    lua_pushfstring(L, "%s.%s", lib, field);
    lua_pushcclosure(L, l_denied, 1);
    lua_setfield(L, -2, field);
  }
  lua_pop(L, 1);
}

/* ---- worker-side Lua API (registered into the WORKER state) --------------- */

static int wl_membytes(lua_State *L) {
  worker *h = (worker *)lua_touserdata(L, lua_upvalueindex(1));
  lua_pushinteger(L, (lua_Integer)h->mem.live);
  lua_pushinteger(L, (lua_Integer)h->mem.peak);
  return 2;
}

static int wk_check_stop(worker *h) {
  if (h->stopped) return 1;
  if (uv_sem_trywait(&h->stop_sem) == 0) h->stopped = 1;
  return h->stopped;
}

/* worker.post(msg) -- worker -> main. Blocks if the out ring is full: that is
 * backpressure on the worker, and the main side always drains eventually
 * (recv, join, or the on_message async). A worker posting to a main thread
 * that never drains blocks here until stop-then-join drains it -- join's
 * drain loop is what makes that not a deadlock. */
static int wl_post(lua_State *L) {
  worker *h = wk_self(L);
  wk_slot s;
  if (slot_from_lua(L, 1, &s) != 0) return lua_error(L);
  ring_push(&h->out, &s);
  /* outa is written by the main thread before uv_thread_create and closed
   * only after uv_thread_join, so it is stable for this thread's lifetime. */
  if (h->outa) uv_async_send(&h->outa->a);
  lua_pushboolean(L, 1);
  return 1;
}

/* worker.recv([timeout_ms]) -> value | nil,"stop" | nil,"timeout"
 * No timeout means block: stop() is guaranteed to wake a blocked recv (empty
 * ring => the stop sentinel fit; full ring => recv was never blocked). The
 * timed variant polls at 1ms -- crude, but bounded and honest; uv semaphores
 * have no timed wait. */
static int wl_recv(lua_State *L) {
  worker *h = wk_self(L);
  int has_timeout = !lua_isnoneornil(L, 1);
  uint64_t deadline = 0;
  if (has_timeout)
    deadline = uv_hrtime() + (uint64_t)(luaL_checknumber(L, 1) * 1e6);
  for (;;) {
    if (wk_check_stop(h)) { lua_pushnil(L); lua_pushliteral(L, "stop"); return 2; }
    wk_slot s;
    int got = ring_trypop(&h->in, &s);
    if (got != 0 && !has_timeout) { ring_pop_wait(&h->in, &s); got = 0; }
    if (got == 0) {
      if (s.kind == WKS_STOP) {
        h->stopped = 1;
        lua_pushnil(L); lua_pushliteral(L, "stop");
        return 2;
      }
      slot_push_value(L, &s);
      free(s.str);
      return 1;
    }
    if (uv_hrtime() >= deadline) { lua_pushnil(L); lua_pushliteral(L, "timeout"); return 2; }
    uv_sleep(1);
  }
}

/* worker.onmessage(fn): switch to loop mode -- after the source returns, the
 * worker sits in uv_run and fn is called per message until stop(). Ref the
 * async so the loop stays alive, and self-wake once so anything already
 * queued is delivered without waiting for the next post. */
static int wl_onmessage(lua_State *L) {
  worker *h = wk_self(L);
  luaL_checktype(L, 1, LUA_TFUNCTION);
  if (h->wcbref != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, h->wcbref);
  lua_pushvalue(L, 1);
  h->wcbref = luaL_ref(L, LUA_REGISTRYINDEX);
  h->want_loop = 1;
  uv_ref((uv_handle_t *)&h->async_in);
  uv_async_send(&h->async_in);
  return 0;
}

static int wl_stopped(lua_State *L) {
  lua_pushboolean(L, wk_check_stop(wk_self(L)));
  return 1;
}

/* The worker's wakeup. With an onmessage callback it drains the in ring and
 * dispatches; without one it deliberately does NOT touch the ring -- those
 * messages belong to recv(), and a wakeup that fired while the source was
 * running its own uv.run (sys.exec does) must not steal them. */
static void in_async_cb(uv_async_t *a) {
  worker *h = (worker *)a->data;
  if (wk_check_stop(h)) {
    uv_unref((uv_handle_t *)&h->async_in);
    uv_stop(luv_loop(h->L));
    /* fall through: still drain below so a queued STOP sentinel is consumed */
  }
  if (h->wcbref == LUA_NOREF) return;
  wk_slot s;
  while (ring_trypop(&h->in, &s) == 0) {
    if (s.kind == WKS_STOP) {
      h->stopped = 1;
      uv_unref((uv_handle_t *)&h->async_in);
      uv_stop(luv_loop(h->L));
      continue;
    }
    lua_State *L = h->L;
    lua_pushcfunction(L, traceback);
    int mh = lua_gettop(L); /* absolute: the stack is not ours to assume empty */
    lua_rawgeti(L, LUA_REGISTRYINDEX, h->wcbref);
    slot_push_value(L, &s);
    free(s.str);
    if (lua_pcall(L, 1, 0, mh) != LUA_OK) {
      fprintf(stderr, "worker onmessage error: %s\n", lua_tostring(L, -1));
      lua_pop(L, 1);
    }
    lua_pop(L, 1); /* traceback fn */
  }
}

static void in_async_closed_cb(uv_handle_t *hd) {
  ((worker *)hd->data)->async_in_closed = 1;
}

/* Overwrite the main-side worker API with the worker-side half, mark the
 * state, apply the deny list, and point sys.membytes at this worker's own
 * counter. Runs BEFORE boggart_boot so strict-mode global locking (which
 * boot enables in worker mode) never sees these writes. */
static void wk_open_self(lua_State *L, worker *h) {
  lua_pushlightuserdata(L, h);
  lua_setfield(L, LUA_REGISTRYINDEX, WK_SELF);

  lua_getglobal(L, "worker");
  if (!lua_istable(L, -1)) { lua_pop(L, 1); lua_newtable(L); }
  lua_pushcfunction(L, wl_post);      lua_setfield(L, -2, "post");
  lua_pushcfunction(L, wl_recv);      lua_setfield(L, -2, "recv");
  lua_pushcfunction(L, wl_onmessage); lua_setfield(L, -2, "onmessage");
  lua_pushcfunction(L, wl_stopped);   lua_setfield(L, -2, "stopped");
  /* one level of workers only: a worker spawning workers would need a
   * spawner registry that is no longer main-thread-owned. Denied, in C. */
  lua_pushliteral(L, "worker.spawn"); lua_pushcclosure(L, l_denied, 1);
  lua_setfield(L, -2, "spawn");
  lua_pushliteral(L, "worker.join");  lua_pushcclosure(L, l_denied, 1);
  lua_setfield(L, -2, "join");
  lua_pushliteral(L, "worker.stop");  lua_pushcclosure(L, l_denied, 1);
  lua_setfield(L, -2, "stop");
  lua_pushliteral(L, "worker.kill");  lua_pushcclosure(L, l_denied, 1);
  lua_setfield(L, -2, "kill");
  lua_pushliteral(L, "worker.pause"); lua_pushcclosure(L, l_denied, 1);
  lua_setfield(L, -2, "pause");
  lua_pushliteral(L, "worker.resume"); lua_pushcclosure(L, l_denied, 1);
  lua_setfield(L, -2, "resume");
  if (h->has_arg) { slot_push_value(L, &h->arg); lua_setfield(L, -2, "arg"); }
  lua_setglobal(L, "worker");

  /* hard part 3: the main thread owns these. NOT http: curl's multi is now
   * per-loop (lhttp.c keys a CURLM off each state's luv loop), so a worker's
   * http.begin/pump build and drive their OWN curl_multi on the worker's OWN
   * loop -- N threads, N loops, N multis, no sharing. That is the whole point of
   * making curl per-loop, and it is what lets a worker run a model turn. */
  deny_global(L, "swarm");
  deny_global(L, "mcp");
  deny_field(L, "auth", "set");     /* cache + file writes; reads are fine */
  deny_field(L, "auth", "clear");
  /* bus.publish is safe from a worker (bytes are queued and dispatched on the
   * main state); subscribe/unsubscribe/attach_main are NOT -- they would store
   * callbacks in this state's registry or repoint dispatch at it. Push/pull are
   * thread-safe byte queues and stay available. */
  deny_field(L, "bus", "subscribe");
  deny_field(L, "bus", "unsubscribe");
  deny_field(L, "bus", "attach_main");

  /* hard part 4: this state's bytes, not the global counter. */
  lua_getglobal(L, "sys");
  if (lua_istable(L, -1)) {
    lua_pushlightuserdata(L, h);
    lua_pushcclosure(L, wl_membytes, 1);
    lua_setfield(L, -2, "membytes");
  }
  lua_pop(L, 1);
}

/* ---- the worker thread ---------------------------------------------------- */

static void wk_capture_result(lua_State *L, worker *h, int ok) {
  h->ok = ok;
  h->result_kind = -1;
  int t = lua_type(L, -1);
  if (t == LUA_TNUMBER) {
    h->result_kind = WKS_NUM;
    h->result_num = lua_tonumber(L, -1);
  } else if (t != LUA_TNIL && t != LUA_TNONE) {
    size_t len = 0;
    const char *p = luaL_tolstring(L, -1, &len); /* pushes; strings pass through */
    h->result_kind = WKS_STR;
    h->result_str = (char *)malloc(len + 1);
    if (h->result_str) { memcpy(h->result_str, p, len); h->result_str[len] = '\0'; h->result_len = len; }
    lua_pop(L, 1);
  }
}

/* VM instructions between safepoints. Large enough that the per-check
 * uv_sem_trywait is lost in the noise of real compute (~one trywait per
 * sub-millisecond of Lua), small enough that a kill lands promptly. */
#define WK_HOOK_COUNT 100000

/* The safepoint. Installed on the worker's own state before it runs the source,
 * so it only ever fires on that thread -- the main thread signals by posting
 * kill_sem/pause_sem, never by touching this state. The worker pointer rides the
 * state's extraspace (set in worker_main), an O(1) read with no Lua-stack
 * traffic. Kill unwinds; pause blocks the worker thread here until resumed.
 * Both stop() and kill() post resume_sem, so a paused worker always unblocks on
 * any wind-down path -- there is no teardown that can deadlock on a pause. */
static void wk_safepoint_hook(lua_State *L, lua_Debug *ar) {
  (void)ar;
  worker *h = *(worker **)lua_getextraspace(L);
  if (!h) return;
  if (uv_sem_trywait(&h->kill_sem) == 0) {
    h->killed = 1;
    luaL_error(L, "worker killed at safepoint"); /* unwinds the source pcall */
  }
  if (uv_sem_trywait(&h->pause_sem) == 0) {
    h->paused = 1;
    uv_sem_wait(&h->resume_sem); /* parks the thread until resume/stop/kill */
    h->paused = 0;
    /* a kill delivered while parked takes effect the moment we wake */
    if (uv_sem_trywait(&h->kill_sem) == 0) {
      h->killed = 1;
      luaL_error(L, "worker killed at safepoint");
    }
  }
}

static void worker_main(void *arg) {
  worker *h = (worker *)arg;

  /* Third argument: Lua 5.5's hashing seed, same choice lmem.c makes. */
  lua_State *L = lua_newstate(wk_alloc, &h->mem, luaL_makeseed(NULL));
  if (!L) {
    /* Still honour the protocol: spawn() is blocked on `ready`, and join()
     * will wait for the EXIT sentinel. Never leave either hanging. */
    h->ok = 0; h->result_kind = WKS_STR;
    h->result_str = strdup("worker: cannot create Lua state");
    h->result_len = h->result_str ? strlen(h->result_str) : 0;
    uv_sem_post(&h->ready);
    uv_sem_post(&h->exit_sem);
    wk_slot s; memset(&s, 0, sizeof s); s.kind = WKS_EXIT;
    ring_push(&h->out, &s);
    if (h->outa) uv_async_send(&h->outa->a);
    return;
  }
  h->L = L;
  h->wcbref = LUA_NOREF;
  luaL_openlibs(L);

  /* Hard part 2, done exactly here: open luv BEFORE anything else can, so
   * this state's luv context creates its own fresh loop (luv only creates
   * one when ctx->loop is NULL) -- never the main thread's. luaL_requiref
   * also records it in package.loaded, so boot/proc's require("uv") get the
   * same table instead of re-running luaopen_luv. */
  luaL_requiref(L, "uv", luaopen_luv, 0);
  lua_pop(L, 1);
  uv_loop_t *loop = luv_loop(L);

  uv_async_init(loop, &h->async_in, in_async_cb);
  h->async_in.data = h;
  uv_unref((uv_handle_t *)&h->async_in); /* a wakeup must not hold the loop open */
  h->accepting = 1; /* published to the main thread by the `ready` post */
  uv_sem_post(&h->ready);

  /* Assemble the boggart interpreter -- open_libs + boot is the identity;
   * without it this is just "a lua_State on a thread", not a boggart. */
  boggart_open_libs(L);
  wk_open_self(L, h);

  if (boggart_boot(L, "worker", h->version) != 0) {
    const char *e = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1)
                                                   : "worker boot failed";
    h->ok = 0; h->result_kind = WKS_STR;
    h->result_str = strdup(e);
    h->result_len = h->result_str ? strlen(h->result_str) : 0;
  } else {
    /* Arm the safepoint: from here on a runaway pure-Lua source is preemptible
     * by kill(). extraspace carries `h` to the hook; the hook is on THIS state
     * only, so nothing crosses a thread but the kill_sem post. */
    *(worker **)lua_getextraspace(L) = h;
    lua_sethook(L, wk_safepoint_hook, LUA_MASKCOUNT, WK_HOOK_COUNT);
    lua_pushcfunction(L, traceback);
    int base = lua_gettop(L);
    if (luaL_loadbuffer(L, h->source, h->srclen, "@worker") != LUA_OK) {
      wk_capture_result(L, h, 0);
    } else if (lua_pcall(L, 0, 1, base) != LUA_OK) {
      wk_capture_result(L, h, 0);
    } else {
      wk_capture_result(L, h, 1);
    }
    lua_settop(L, 0);
  }

  /* A plain worker's run-out must not block on an idle keep-alive curl socket
   * (a completed model turn leaves one referenced); tear http down first so the
   * loop can drain. An onmessage worker keeps http alive for its message loop
   * and is shut down after it. Idempotent, and a no-op if the worker did no
   * HTTP. This is also what lets a worker run a model turn AND exit cleanly. */
  if (!h->want_loop) boggart_http_shutdown(L);

  /* Run the loop out. Plain workers: everything the source started (timers,
   * sys.exec pipes) has already finished or finishes here, then uv_run
   * returns because the only remaining handle -- the wakeup -- is unref'd.
   * onmessage workers: the wakeup is ref'd, so this IS the message loop, and
   * it exits via uv_stop when stop() arrives. */
  if (!(h->want_loop && !h->ok)) /* an errored source gets no message loop */
    uv_run(loop, UV_RUN_DEFAULT);

  /* Teardown. Order matters and each step is load-bearing:
   * 1. close the gate so the main thread stops uv_async_send-ing a handle
   *    that is about to die (THE lock; see the top comment);
   * 2. close the wakeup and run the loop until the close lands, because a
   *    uv handle is not dead at uv_close() but at its close callback;
   * 3. lua_close: luv's loop_gc closes every remaining handle and the loop
   *    itself -- the loop's memory is a Lua userdata and dies with the
   *    state, so nothing may touch `loop` after this line;
   * 4. only then publish the exit, so a joiner can never observe "exited"
   *    while the state or loop still exists. */
  boggart_http_shutdown(L); /* onmessage path + neutralise curl handles before */
                            /* lua_close's loop_gc (idempotent after the above) */
  uv_sem_wait(&h->gate);
  h->accepting = 0;
  uv_sem_post(&h->gate);
  uv_close((uv_handle_t *)&h->async_in, in_async_closed_cb);
  while (!h->async_in_closed) uv_run(loop, UV_RUN_ONCE);
  lua_close(L);
  h->L = NULL;

  uv_sem_post(&h->exit_sem); /* result fields are now readable via status() */
  wk_slot s; memset(&s, 0, sizeof s); s.kind = WKS_EXIT;
  ring_push(&h->out, &s);    /* join()'s wait target; may block, join drains */
  if (h->outa) uv_async_send(&h->outa->a);
}

/* ---- main-side ------------------------------------------------------------ */

static worker **check_handle(lua_State *L) {
  worker **ud = (worker **)luaL_checkudata(L, 1, "boggart.worker");
  if (!*ud) luaL_error(L, "worker handle already collected");
  return ud;
}

/* Latch "the source has finished" without consuming messages. The exit_sem
 * trywait is the happens-before edge that makes ok/result readable here. */
static int wk_exited(worker *h) {
  if (h->exit_flag) return 1;
  if (uv_sem_trywait(&h->exit_sem) == 0) h->exit_flag = 1;
  return h->exit_flag;
}

/* Emit a worker lifecycle event. Payload is just the id (safe to format -- no
 * user text, no escaping); the topic carries the verb and worker.list() has the
 * rest. Main-thread call sites only. */
static void wk_emit(worker *h, const char *topic) {
  char buf[48];
  int n = snprintf(buf, sizeof buf, "{\"id\":%llu}", (unsigned long long)h->id);
  if (n > 0) bus_emit(topic, buf, (size_t)n);
}

static void pend_append(worker *h, wk_slot *s) {
  struct pmsg *p = (struct pmsg *)malloc(sizeof *p);
  if (!p) { free(s->str); return; } /* drop on OOM, freeing the payload */
  p->s = *s;
  p->next = NULL;
  if (h->pend_tail) h->pend_tail->next = p; else h->pend_head = p;
  h->pend_tail = p;
}

/* Deliver one drained out-ring slot on the main thread: EXIT latches, a
 * message goes to the on_message callback if there is one, else it is queued
 * for worker.recv(). `allow_lua` is 0 during __gc, where re-entering Lua from
 * a finalizer's C path is a place bugs live. */
static void deliver_out(worker *h, wk_slot *s, int allow_lua) {
  if (s->kind == WKS_EXIT) {
    h->saw_exit = 1;
    /* Not during __gc (allow_lua=0): emitting dispatches to Lua subscribers, and
     * re-entering Lua from a finalizer is the hazard this flag guards. */
    if (allow_lua) wk_emit(h, "worker:exited");
    return;
  }
  /* Remember the last string a worker posted, for worker.list(). Main-thread
   * only (this function is), so the swap is unguarded by design. A number
   * message leaves the previous line standing -- the display wants words. */
  if (s->kind == WKS_STR && s->str) {
    free(h->last);
    h->last = strdup(s->str);
  }
  if (h->outa && allow_lua) {
    lua_State *L = h->outa->L;
    lua_pushcfunction(L, traceback);
    int mh = lua_gettop(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, h->outa->cbref);
    slot_push_value(L, s);
    free(s->str);
    if (lua_pcall(L, 1, 0, mh) != LUA_OK) {
      fprintf(stderr, "worker on_message error: %s\n", lua_tostring(L, -1));
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return;
  }
  pend_append(h, s);
}

static void out_async_cb(uv_async_t *a) {
  wk_out_async *oa = (wk_out_async *)a; /* .a is the first member */
  worker *h = oa->w;
  wk_slot s;
  while (ring_trypop(&h->out, &s) == 0) deliver_out(h, &s, 1);
}

static void out_async_free_cb(uv_handle_t *hd) {
  free(hd); /* the wk_out_async wrapper; .a is first, so hd is the wrapper */
}

static void wk_stop_signal(worker *h) {
  uv_sem_post(&h->stop_sem);
  /* Unblock a parked worker so it can wind down; harmless if it is not parked
   * (the stray token makes the next pause a no-op, but a stopping worker gets no
   * next pause). This is what makes join/gc/atexit deadlock-free against pause. */
  uv_sem_post(&h->resume_sem);
  wk_slot s; memset(&s, 0, sizeof s); s.kind = WKS_STOP;
  /* Best effort: a full ring cannot take the sentinel, but full also means
   * the worker is not blocked in recv, and every recv checks stop_sem. */
  ring_trypush(&h->in, &s);
  uv_sem_wait(&h->gate);
  if (h->accepting) uv_async_send(&h->async_in);
  uv_sem_post(&h->gate);
}

/* Preemptive kill: post kill_sem (the worker's count hook trywaits it and raises)
 * AND do the cooperative stop, so a worker blocked in C (recv, sys.exec) is woken
 * while a worker spinning in Lua is unwound at the next safepoint. */
static void wk_kill_signal(worker *h) {
  uv_sem_post(&h->kill_sem);
  wk_stop_signal(h);
}

/* Drain until EXIT, then join the thread. The drain is not a nicety: a worker
 * blocked pushing into a full out ring is unblocked precisely by this loop,
 * which is what makes stop-then-join deadlock-free. */
static void wk_join_thread(worker *h, int allow_lua) {
  while (!h->saw_exit) {
    wk_slot s;
    ring_pop_wait(&h->out, &s);
    deliver_out(h, &s, allow_lua);
  }
  if (h->thread_up) {
    uv_thread_join(&h->thread);
    h->thread_up = 0;
  }
  h->joined = 1;
  wk_exited(h); /* keep the semaphore accounting tidy and the latch set */
}

static void wk_close_outa(worker *h) {
  if (!h->outa) return;
  luaL_unref(h->outa->L, LUA_REGISTRYINDEX, h->outa->cbref);
  /* If the main state is shutting down, luv's loop_gc may already have
   * walked the loop and closed this handle (safely: .data is NULL). Closing
   * it twice would abort inside libuv. */
  if (!uv_is_closing((uv_handle_t *)&h->outa->a))
    uv_close((uv_handle_t *)&h->outa->a, out_async_free_cb);
  h->outa = NULL; /* freed by the close callback when the loop next turns */
}

static void wk_free(worker *h) {
  ring_destroy(&h->in);
  ring_destroy(&h->out);
  uv_sem_destroy(&h->ready);
  uv_sem_destroy(&h->stop_sem);
  uv_sem_destroy(&h->exit_sem);
  uv_sem_destroy(&h->kill_sem);
  uv_sem_destroy(&h->pause_sem);
  uv_sem_destroy(&h->resume_sem);
  uv_sem_destroy(&h->gate);
  while (h->pend_head) {
    struct pmsg *p = h->pend_head;
    h->pend_head = p->next;
    free(p->s.str);
    free(p);
  }
  free(h->source);
  free(h->version);
  free(h->arg.str);
  free(h->result_str);
  free(h->label);
  free(h->kind);
  free(h->last);
  /* unlink from the registry */
  worker **it = &g_workers;
  while (*it && *it != h) it = &(*it)->next;
  if (*it) *it = h->next;
  free(h);
}

/* atexit, in jwriter.c's mould: no thread may outlive main() into static
 * teardown (a worker touching sqlite or curl while their atexit handlers run
 * is a crash at the worst possible moment). Normally this list is empty --
 * lua_close ran every handle's __gc, which joins. Like jwriter, it waits
 * rather than kills: a worker that ignores stop hangs the exit, loudly, which
 * is the honest failure mode when there is no portable timed join. */
static void workers_atexit(void) {
  for (worker *w = g_workers; w; w = w->next) {
    if (w->thread_up && !w->joined) {
      wk_stop_signal(w);
      wk_join_thread(w, 0);
    }
  }
}

/* Force lauth's lazy credential cache to load on the MAIN thread, before any
 * worker exists to race the load (hard part 5). Reads after that are of
 * settled memory -- except a concurrent /auth set on the main thread, which
 * workers cannot prevent; that residual race is documented, and set/clear
 * are denied inside workers so it can only originate from the main REPL. */
static void warm_auth(lua_State *L) {
  lua_getglobal(L, "auth");
  if (lua_istable(L, -1)) {
    lua_getfield(L, -1, "base_url");
    if (lua_isfunction(L, -1)) lua_pcall(L, 0, 0, 0);
    else lua_pop(L, 1);
  }
  lua_pop(L, 1);
}

/* worker.spawn(source [, opts]) -> handle
 * opts.arg        string|number, exposed as worker.arg in the worker
 * opts.on_message fn(msg), called on THIS state's uv loop per posted message
 *                 (requires the loop to actually run: uv.run / swarm mode) */
static int l_spawn(lua_State *L) {
  if (wk_self(L))
    return luaL_error(L, "worker.spawn: not available inside a worker (one level only)");
  size_t srclen = 0;
  const char *src = luaL_checklstring(L, 1, &srclen);
  int has_opts = lua_istable(L, 2);

  warm_auth(L);

  worker *h = (worker *)calloc(1, sizeof *h);
  if (!h) return luaL_error(L, "out of memory");
  h->result_kind = -1;

  h->source = (char *)malloc(srclen + 1);
  if (!h->source) { free(h); return luaL_error(L, "out of memory"); }
  memcpy(h->source, src, srclen);
  h->source[srclen] = '\0';
  h->srclen = srclen;

  lua_getglobal(L, "boggart");
  if (lua_istable(L, -1)) {
    lua_getfield(L, -1, "version");
    h->version = strdup(lua_isstring(L, -1) ? lua_tostring(L, -1) : "worker");
    lua_pop(L, 1);
  } else h->version = strdup("worker");
  lua_pop(L, 1);

  if (has_opts) {
    lua_getfield(L, 2, "arg");
    if (!lua_isnil(L, -1)) {
      if (slot_from_lua(L, -1, &h->arg) != 0) {
        free(h->source); free(h->version); free(h);
        return lua_error(L);
      }
      h->has_arg = 1;
    }
    lua_pop(L, 1);
  }

  int rc = ring_init(&h->in);
  if (rc == 0) rc = ring_init(&h->out);
  if (rc == 0) rc = uv_sem_init(&h->ready, 0);
  if (rc == 0) rc = uv_sem_init(&h->stop_sem, 0);
  if (rc == 0) rc = uv_sem_init(&h->exit_sem, 0);
  if (rc == 0) rc = uv_sem_init(&h->kill_sem, 0);
  if (rc == 0) rc = uv_sem_init(&h->pause_sem, 0);
  if (rc == 0) rc = uv_sem_init(&h->resume_sem, 0);
  if (rc == 0) rc = uv_sem_init(&h->gate, 1);
  if (rc != 0) {
    /* Partial init: destroying an uninitialized sem is UB, so be exact. */
    ring_destroy(&h->in); ring_destroy(&h->out);
    free(h->source); free(h->version); free(h->arg.str); free(h);
    return luaL_error(L, "worker: resource init failed");
  }

  if (has_opts) {
    lua_getfield(L, 2, "on_message");
    if (lua_isfunction(L, -1)) {
      /* The delivery async needs THIS state's loop; make sure luv (and so
       * the loop) exists. requiref is idempotent via package.loaded. */
      luaL_requiref(L, "uv", luaopen_luv, 0);
      lua_pop(L, 1);
      wk_out_async *oa = (wk_out_async *)calloc(1, sizeof *oa);
      if (!oa) { lua_pop(L, 1); wk_free(h); return luaL_error(L, "out of memory"); }
      uv_async_init(luv_loop(L), &oa->a, out_async_cb);
      oa->a.data = NULL;       /* deliberate; see wk_out_async's comment */
      uv_unref((uv_handle_t *)&oa->a); /* deliveries must not hold the loop open */
      oa->L = L;
      oa->w = h;
      lua_pushvalue(L, -1);
      oa->cbref = luaL_ref(L, LUA_REGISTRYINDEX);
      h->outa = oa;
    }
    lua_pop(L, 1);
  }

  /* Display metadata, copied before the thread starts so list() reads
   * strings the worker never touches. */
  h->id = ++g_worker_seq;
  h->started = (double)time(NULL);
  if (has_opts) {
    lua_getfield(L, 2, "label"); if (lua_isstring(L, -1)) h->label = strdup(lua_tostring(L, -1)); lua_pop(L, 1);
    lua_getfield(L, 2, "kind");  if (lua_isstring(L, -1)) h->kind  = strdup(lua_tostring(L, -1)); lua_pop(L, 1);
  }
  if (!h->label) { char b[32]; snprintf(b, sizeof b, "worker %llu", (unsigned long long)h->id); h->label = strdup(b); }
  if (!h->kind)  h->kind = strdup("task");

  if (!g_atexit_done) { atexit(workers_atexit); g_atexit_done = 1; }
  h->next = g_workers;
  g_workers = h;

  if (uv_thread_create(&h->thread, worker_main, h) != 0) {
    wk_close_outa(h);
    wk_free(h);
    return luaL_error(L, "worker: thread creation failed");
  }
  h->thread_up = 1;

  /* Until the worker's loop and wakeup async exist, post()/stop() would
   * uv_async_send into uninitialized memory. The worker posts `ready` the
   * moment they do (before boot, so this waits microseconds, not a boot). */
  uv_sem_wait(&h->ready);

  worker **ud = (worker **)lua_newuserdata(L, sizeof(worker *));
  *ud = h;
  luaL_setmetatable(L, "boggart.worker");
  wk_emit(h, "worker:spawned");
  return 1;
}

/* worker.post(handle, msg) -> true | nil,"full" | nil,"exited"
 * Never blocks: the main thread must not wait on a worker's consumption. */
static int l_post(lua_State *L) {
  worker *h = *check_handle(L);
  if (h->joined || wk_exited(h)) {
    lua_pushnil(L); lua_pushliteral(L, "exited");
    return 2;
  }
  wk_slot s;
  if (slot_from_lua(L, 2, &s) != 0) return lua_error(L);
  if (ring_trypush(&h->in, &s) != 0) {
    free(s.str);
    lua_pushnil(L); lua_pushliteral(L, "full");
    return 2;
  }
  uv_sem_wait(&h->gate);
  if (h->accepting) uv_async_send(&h->async_in);
  uv_sem_post(&h->gate);
  lua_pushboolean(L, 1);
  return 1;
}

/* worker.recv(handle [, timeout_ms]) -> value | nil,"exit" | nil,"timeout"
 * Bounded by default (10s): an unbounded wait on a worker that never posts
 * is exactly the runaway this codebase has been bitten by. */
static int l_recv(lua_State *L) {
  worker *h = *check_handle(L);
  double ms = luaL_optnumber(L, 2, 10000);
  uint64_t deadline = uv_hrtime() + (uint64_t)(ms * 1e6);
  for (;;) {
    if (h->pend_head) {
      struct pmsg *p = h->pend_head;
      h->pend_head = p->next;
      if (!h->pend_head) h->pend_tail = NULL;
      slot_push_value(L, &p->s);
      free(p->s.str);
      free(p);
      return 1;
    }
    if (h->saw_exit) { lua_pushnil(L); lua_pushliteral(L, "exit"); return 2; }
    wk_slot s;
    if (ring_trypop(&h->out, &s) == 0) {
      if (s.kind == WKS_EXIT) { h->saw_exit = 1; continue; }
      slot_push_value(L, &s);
      free(s.str);
      return 1;
    }
    if (uv_hrtime() >= deadline) { lua_pushnil(L); lua_pushliteral(L, "timeout"); return 2; }
    uv_sleep(1);
  }
}

static int l_stop(lua_State *L) {
  worker *h = *check_handle(L);
  if (!h->joined) wk_stop_signal(h);
  return 0;
}

/* worker.kill(handle) -- preempt a runaway worker. Unlike stop() (cooperative,
 * the source may still return ok), kill unwinds the source with an error at the
 * next Lua safepoint, so join() reports ok=false. */
static int l_kill(lua_State *L) {
  worker *h = *check_handle(L);
  if (!h->joined) { wk_kill_signal(h); wk_emit(h, "worker:killed"); }
  return 0;
}

/* worker.pause(handle) -- park the worker at its next Lua safepoint. Takes
 * effect only while it is running Lua (a worker blocked in a C call pauses when
 * it next returns to the VM). Balance with resume(). */
static int l_pause(lua_State *L) {
  worker *h = *check_handle(L);
  if (!h->joined && !wk_exited(h)) { uv_sem_post(&h->pause_sem); wk_emit(h, "worker:paused"); }
  return 0;
}

/* worker.resume(handle) -- release a paused worker. */
static int l_resume(lua_State *L) {
  worker *h = *check_handle(L);
  if (!h->joined) { uv_sem_post(&h->resume_sem); wk_emit(h, "worker:resumed"); }
  return 0;
}

/* worker.join(handle) -> ok, result
 * ok is whether the source completed; result is its return value (string or
 * number, per the boundary rules) or the error string with traceback. */
static int l_join(lua_State *L) {
  worker *h = *check_handle(L);
  if (!h->joined) wk_join_thread(h, 1);
  wk_close_outa(h);
  lua_pushboolean(L, h->ok);
  if (h->result_kind == WKS_NUM) lua_pushnumber(L, h->result_num);
  else if (h->result_kind == WKS_STR) lua_pushlstring(L, h->result_str ? h->result_str : "", h->result_len);
  else lua_pushnil(L);
  return 2;
}

static int l_status(lua_State *L) {
  worker *h = *check_handle(L);
  if (h->joined) lua_pushliteral(L, "joined");
  else if (wk_exited(h)) lua_pushstring(L, h->killed ? "killed" : (h->ok ? "done" : "error"));
  else if (h->paused) lua_pushliteral(L, "paused"); /* best-effort display read */
  else lua_pushliteral(L, "running");
  return 1;
}

/* A collected handle must not leave a live thread behind: stop, join (without
 * re-entering Lua -- we may be inside lua_close), release everything. */
static int l_gc(lua_State *L) {
  worker **ud = (worker **)luaL_checkudata(L, 1, "boggart.worker");
  worker *h = *ud;
  if (!h) return 0;
  if (!h->joined) {
    wk_stop_signal(h);
    wk_join_thread(h, 0);
  }
  wk_close_outa(h);
  wk_free(h);
  *ud = NULL;
  return 0;
}

static int l_tostring(lua_State *L) {
  worker **ud = (worker **)luaL_checkudata(L, 1, "boggart.worker");
  lua_pushfstring(L, "worker: %p", (void *)*ud);
  return 1;
}

/* worker.list() -> array of { id, label, kind, status, elapsed, last }.
 *
 * Walks the same g_workers registry atexit uses -- the authoritative list of
 * live threads, tracked in C rather than in a Lua wrapper, because a wrapper
 * only sees what was spawned through it. This is the introspection a UI needs:
 * how many workers, and roughly what each is on.
 *
 * Main-thread-only, like everything that touches g_workers. Reads a worker's
 * own status the way l_status does; `last` is the most recent string it posted,
 * captured in deliver_out. No lock: the metadata is main-thread-owned and the
 * status booleans it reads are set-once by the worker and separated by the
 * exit semaphore's happens-before. */
static int l_list(lua_State *L) {
  double now = (double)time(NULL);
  lua_newtable(L);
  int i = 0;
  for (worker *h = g_workers; h; h = h->next) {
    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)h->id);        lua_setfield(L, -2, "id");
    lua_pushstring(L, h->label ? h->label : "?");  lua_setfield(L, -2, "label");
    lua_pushstring(L, h->kind ? h->kind : "task"); lua_setfield(L, -2, "kind");
    const char *st = h->joined ? "joined"
                   : wk_exited(h) ? (h->killed ? "killed" : (h->ok ? "done" : "error"))
                   : h->paused ? "paused"
                   : "running";
    lua_pushstring(L, st);                         lua_setfield(L, -2, "status");
    lua_pushnumber(L, now - h->started);           lua_setfield(L, -2, "elapsed");
    if (h->last) { lua_pushstring(L, h->last); lua_setfield(L, -2, "last"); }
    lua_rawseti(L, -2, ++i);
  }
  return 1;
}

/* worker.count() -> running, total. The cheap summary for a status bar. */
static int l_count(lua_State *L) {
  int running = 0, total = 0;
  for (worker *h = g_workers; h; h = h->next) {
    total++;
    if (!h->joined && !wk_exited(h)) running++;
  }
  lua_pushinteger(L, running);
  lua_pushinteger(L, total);
  return 2;
}

static const luaL_Reg worker_lib[] = {
  {"list",   l_list},
  {"count",  l_count},
  {"spawn",  l_spawn},
  {"post",   l_post},
  {"recv",   l_recv},
  {"stop",   l_stop},
  {"kill",   l_kill},
  {"pause",  l_pause},
  {"resume", l_resume},
  {"join",   l_join},
  {"status", l_status},
  {NULL, NULL}
};

int luaopen_boggart_worker(lua_State *L) {
  if (luaL_newmetatable(L, "boggart.worker")) {
    lua_pushcfunction(L, l_gc);       lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, l_tostring); lua_setfield(L, -2, "__tostring");
  }
  lua_pop(L, 1);
  luaL_newlib(L, worker_lib);
  return 1;
}
