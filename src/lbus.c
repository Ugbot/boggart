/* lbus.c -- the messaging fabric core: a pub/sub bus and named work queues,
 * exposed to Lua as the global `bus`. Phase 1 of docs/actors-and-bus.md.
 *
 * Two patterns over one structure:
 *   - PUB/SUB: bus.publish(topic, data) fans out to every subscriber whose glob
 *     pattern matches the topic. This is the observability substrate -- turns,
 *     tools, loops, the supervisor all publish; a trace / the journal / (later)
 *     cross-thread consumers subscribe.
 *   - PUSH/PULL: bus.push(queue, item) / bus.pull(queue) is a named FIFO work
 *     queue -- multi-producer, load-balanced consumers pull the next item.
 *
 * Everything is guarded by ONE uv_mutex, so it is correct the day a worker
 * thread publishes -- even though Phase 1 only drives it from the main thread.
 * The Lua-callback dispatch (pcall) runs WITHOUT the lock held (snapshot the
 * matching refs under the lock, release, then call) so a subscriber that
 * publishes or unsubscribes during dispatch cannot deadlock. Removals are
 * deferred while a dispatch is in flight (a `dead` flag + compaction at depth 0),
 * exactly as lua/events.lua does.
 *
 * Payloads are BYTES (Lua strings). Nothing Lua crosses a thread here; a
 * cross-thread publisher hands over bytes and the main state dispatches -- that
 * routing is Phase 2 (uv_async drain), not built yet.
 */
#include <lua.h>
#include <lauxlib.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <uv.h>

/* luv.c: the uv loop a state's luv context is bound to, and the luv opener --
 * so attach_main can guarantee the main loop exists before it installs the
 * drain async. Same extern-it-here idiom the other .c files use. */
extern uv_loop_t *luv_loop(lua_State *L);
int luaopen_luv(lua_State *L);

/* ---- subscribers ---------------------------------------------------------- */
typedef struct {
  int   id;       /* handle returned to Lua for unsubscribe */
  char *pat;      /* glob pattern, e.g. tool:*  agent.N.turn  or  *  (star=any run) */
  int   ref;      /* LUA_REGISTRYINDEX ref to the callback */
  int   dead;     /* removed during a dispatch; compacted at depth 0 */
} Sub;

/* ---- work-queue items (a bytes FIFO) -------------------------------------- */
typedef struct QItem { struct QItem *next; size_t len; char data[]; } QItem;
typedef struct { char *name; QItem *head, *tail; size_t depth; } Queue;

/* ---- cross-thread pending publications ------------------------------------ */
/* A publish from a non-main thread cannot dispatch (subscriber callbacks live in
 * the main state's registry); it enqueues bytes here and the main state drains
 * and dispatches them via `drain`. */
typedef struct PItem { struct PItem *next; char *topic; char *data; size_t len; } PItem;
#define PEND_MAX 4096

static struct {
  uv_mutex_t mu;
  int        inited;
  lua_State *L;          /* the MAIN state; its registry holds the callback refs
                           * and all dispatch happens on its thread */
  Sub   *subs;  int nsub, capsub, next_id, disp_depth;
  Queue *qs;    int nq,   capq;
  uint64_t published, delivered, dropped;

  /* cross-thread delivery */
  uv_thread_t main_thread; int main_thread_set;  /* captured at init = main */
  uv_async_t  drain;       int attached;          /* installed by attach_main */
  PItem *pend_head, *pend_tail; int pend_n;
} B;

/* Classic iterative wildcard match: `*` matches any run (including empty). */
static int glob_match(const char *p, const char *s) {
  const char *star = NULL, *ss = NULL;
  while (*s) {
    if (*p == '*') { star = p++; ss = s; }
    else if (*p == *s) { p++; s++; }
    else if (star) { p = star + 1; s = ++ss; }
    else return 0;
  }
  while (*p == '*') p++;
  return *p == 0;
}

static void ensure_init(void) {
  if (B.inited) return;
  uv_mutex_init(&B.mu);
  B.next_id = 1;
  /* First open is the main state on the main thread (it boots before any worker
   * exists); this is idempotent, so a worker's later open never overwrites it. */
  B.main_thread = uv_thread_self();
  B.main_thread_set = 1;
  B.inited = 1;
}

/* Drop dead subscribers once no dispatch is walking the list. Caller holds mu. */
static void compact_locked(lua_State *L) {
  if (B.disp_depth != 0) return;
  int w = 0;
  for (int i = 0; i < B.nsub; i++) {
    if (B.subs[i].dead) {
      luaL_unref(L, LUA_REGISTRYINDEX, B.subs[i].ref);
      free(B.subs[i].pat);
    } else {
      B.subs[w++] = B.subs[i];
    }
  }
  B.nsub = w;
}

/* ---- pub/sub -------------------------------------------------------------- */

/* bus.subscribe(pattern, fn) -> id */
static int l_subscribe(lua_State *L) {
  const char *pat = luaL_checkstring(L, 1);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  ensure_init();
  lua_pushvalue(L, 2);
  int ref = luaL_ref(L, LUA_REGISTRYINDEX);

  uv_mutex_lock(&B.mu);
  B.L = L;   /* the registering (main) state owns the callbacks */
  if (B.nsub == B.capsub) {
    B.capsub = B.capsub ? B.capsub * 2 : 8;
    B.subs = realloc(B.subs, (size_t)B.capsub * sizeof(Sub));
  }
  int id = B.next_id++;
  B.subs[B.nsub++] = (Sub){ .id = id, .pat = strdup(pat), .ref = ref, .dead = 0 };
  uv_mutex_unlock(&B.mu);

  lua_pushinteger(L, id);
  return 1;
}

/* bus.unsubscribe(id) -> bool */
static int l_unsubscribe(lua_State *L) {
  int id = (int)luaL_checkinteger(L, 1);
  int found = 0;
  ensure_init();
  uv_mutex_lock(&B.mu);
  for (int i = 0; i < B.nsub; i++) {
    if (B.subs[i].id == id && !B.subs[i].dead) { B.subs[i].dead = 1; found = 1; break; }
  }
  compact_locked(L);
  uv_mutex_unlock(&B.mu);
  lua_pushboolean(L, found);
  return 1;
}

/* bus.has(pattern) -> bool  -- any subscriber whose pattern would match a topic
 * that also matches `pattern`? Cheap guard so a publisher can skip building a
 * payload nobody wants. Approximate: true if any live subscriber's pattern
 * equals or is `*`, or the queried pattern matches it as a literal. */
static int l_has(lua_State *L) {
  const char *topic = luaL_checkstring(L, 1);
  int any = 0;
  ensure_init();
  uv_mutex_lock(&B.mu);
  for (int i = 0; i < B.nsub; i++) {
    if (!B.subs[i].dead && glob_match(B.subs[i].pat, topic)) { any = 1; break; }
  }
  uv_mutex_unlock(&B.mu);
  lua_pushboolean(L, any);
  return 1;
}

/* Dispatch one (topic,data) to matching subscribers on the MAIN state (B.L).
 * MUST run on the main thread. Snapshots the matching refs under the lock, then
 * pcalls WITHOUT it (so a subscriber may publish/unsubscribe re-entrantly).
 * Returns the number delivered. */
static int deliver(const char *topic, const char *data, size_t dlen) {
  lua_State *L = B.L;
  uv_mutex_lock(&B.mu);
  int *refs = NULL, k = 0, cap = 0;
  for (int i = 0; i < B.nsub; i++) {
    if (B.subs[i].dead || !glob_match(B.subs[i].pat, topic)) continue;
    if (k == cap) { cap = cap ? cap * 2 : 8; refs = realloc(refs, (size_t)cap * sizeof(int)); }
    refs[k++] = B.subs[i].ref;
  }
  B.disp_depth++;
  uv_mutex_unlock(&B.mu);

  for (int j = 0; j < k && L; j++) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, refs[j]);
    if (lua_type(L, -1) != LUA_TFUNCTION) { lua_pop(L, 1); continue; }
    lua_pushstring(L, topic);
    lua_pushlstring(L, data, dlen);
    if (lua_pcall(L, 2, 0, 0) != LUA_OK) lua_pop(L, 1); /* a thrower can't kill us */
  }
  free(refs);

  uv_mutex_lock(&B.mu);
  B.delivered += (uint64_t)k;
  B.disp_depth--;
  compact_locked(B.L);
  uv_mutex_unlock(&B.mu);
  return k;
}

/* Copy bytes into a pending node for the main thread to dispatch, wake it if
 * attached. Drop-on-full (tallied) so a producer never blocks on the consumer. */
static void enqueue_cross(const char *topic, const char *data, size_t dlen) {
  PItem *p = (PItem *)malloc(sizeof *p);
  if (!p) return;
  p->next = NULL; p->len = dlen;
  p->topic = strdup(topic);
  p->data = (char *)malloc(dlen ? dlen : 1);
  if (!p->topic || !p->data) { free(p->topic); free(p->data); free(p); return; }
  memcpy(p->data, data, dlen);
  uv_mutex_lock(&B.mu);
  int attached = B.attached;
  if (B.pend_n >= PEND_MAX) {
    B.dropped++;
    uv_mutex_unlock(&B.mu);
    free(p->topic); free(p->data); free(p);
    return;
  }
  if (B.pend_tail) B.pend_tail->next = p; else B.pend_head = p;
  B.pend_tail = p; B.pend_n++;
  uv_mutex_unlock(&B.mu);
  if (attached) uv_async_send(&B.drain);
}

/* The main-loop drain: fires when a worker publish is queued. Splices the whole
 * pending list out under the lock, then dispatches it lock-free on the main
 * state. */
static void bus_drain_cb(uv_async_t *a) {
  (void)a;
  uv_mutex_lock(&B.mu);
  PItem *list = B.pend_head;
  B.pend_head = B.pend_tail = NULL; B.pend_n = 0;
  uv_mutex_unlock(&B.mu);
  while (list) {
    PItem *p = list; list = p->next;
    deliver(p->topic, p->data, p->len);
    free(p->topic); free(p->data); free(p);
  }
}

/* bus.publish(topic, data?) -> delivered_count (0 for a cross-thread publish,
 * which is dispatched later on the main thread). */
static int l_publish(lua_State *L) {
  const char *topic = luaL_checkstring(L, 1);
  size_t dlen = 0;
  const char *data = luaL_optlstring(L, 2, "", &dlen);
  ensure_init();

  uv_thread_t self = uv_thread_self();
  int cross = B.main_thread_set && !uv_thread_equal(&B.main_thread, &self);

  uv_mutex_lock(&B.mu);
  B.published++;
  uv_mutex_unlock(&B.mu);

  if (cross) {
    enqueue_cross(topic, data, dlen); /* off the main thread: never touch B.L */
    lua_pushinteger(L, 0);
    return 1;
  }

  lua_pushinteger(L, deliver(topic, data, dlen));
  return 1;
}

/* bus_emit -- the C-callable publish, for the runtime itself (lworker.c emits
 * worker lifecycle here). Same thread rule as l_publish: dispatch inline on the
 * main thread, enqueue from any other. No Lua state needed by the caller. */
void bus_emit(const char *topic, const char *data, size_t len);
void bus_emit(const char *topic, const char *data, size_t len) {
  uv_thread_t self;
  int cross;
  ensure_init();
  self = uv_thread_self();
  cross = B.main_thread_set && !uv_thread_equal(&B.main_thread, &self);
  uv_mutex_lock(&B.mu);
  B.published++;
  uv_mutex_unlock(&B.mu);
  if (cross) enqueue_cross(topic, data ? data : "", len);
  else deliver(topic, data ? data : "", len);
}

/* ---- work queues (push/pull) --------------------------------------------- */
static Queue *find_queue_locked(const char *name, int create) {
  for (int i = 0; i < B.nq; i++) if (strcmp(B.qs[i].name, name) == 0) return &B.qs[i];
  if (!create) return NULL;
  if (B.nq == B.capq) { B.capq = B.capq ? B.capq * 2 : 8; B.qs = realloc(B.qs, (size_t)B.capq * sizeof(Queue)); }
  B.qs[B.nq] = (Queue){ .name = strdup(name), .head = NULL, .tail = NULL, .depth = 0 };
  return &B.qs[B.nq++];
}

/* bus.push(queue, item) -> true */
static int l_push(lua_State *L) {
  const char *qn = luaL_checkstring(L, 1);
  size_t n = 0;
  const char *d = luaL_checklstring(L, 2, &n);
  ensure_init();
  QItem *it = malloc(sizeof(QItem) + n);
  it->next = NULL; it->len = n; memcpy(it->data, d, n);
  uv_mutex_lock(&B.mu);
  Queue *Q = find_queue_locked(qn, 1);
  if (Q->tail) Q->tail->next = it; else Q->head = it;
  Q->tail = it; Q->depth++;
  uv_mutex_unlock(&B.mu);
  lua_pushboolean(L, 1);
  return 1;
}

/* bus.pull(queue) -> item | nil   (non-blocking) */
static int l_pull(lua_State *L) {
  const char *qn = luaL_checkstring(L, 1);
  ensure_init();
  uv_mutex_lock(&B.mu);
  Queue *Q = find_queue_locked(qn, 0);
  QItem *it = Q ? Q->head : NULL;
  if (it) { Q->head = it->next; if (!Q->head) Q->tail = NULL; Q->depth--; }
  uv_mutex_unlock(&B.mu);
  if (!it) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, it->data, it->len);
  free(it);
  return 1;
}

/* bus.qlen(queue) -> n */
static int l_qlen(lua_State *L) {
  const char *qn = luaL_checkstring(L, 1);
  ensure_init();
  uv_mutex_lock(&B.mu);
  Queue *Q = find_queue_locked(qn, 0);
  lua_Integer n = Q ? (lua_Integer)Q->depth : 0;
  uv_mutex_unlock(&B.mu);
  lua_pushinteger(L, n);
  return 1;
}

/* bus.stats() -> { published, delivered, subscribers, queues } */
static int l_stats(lua_State *L) {
  ensure_init();
  uv_mutex_lock(&B.mu);
  uint64_t pub = B.published, del = B.delivered;
  int nsub = 0; for (int i = 0; i < B.nsub; i++) if (!B.subs[i].dead) nsub++;
  int nq = B.nq;
  uv_mutex_unlock(&B.mu);
  lua_newtable(L);
  lua_pushinteger(L, (lua_Integer)pub);  lua_setfield(L, -2, "published");
  lua_pushinteger(L, (lua_Integer)del);  lua_setfield(L, -2, "delivered");
  lua_pushinteger(L, nsub);              lua_setfield(L, -2, "subscribers");
  lua_pushinteger(L, nq);                lua_setfield(L, -2, "queues");
  return 1;
}

/* bus.attach_main() -- called once on the main thread (from activate_agents),
 * after its uv loop exists: records the main state for dispatch, installs the
 * drain async, and flushes anything a worker queued before attach. Idempotent. */
static int l_attach_main(lua_State *L) {
  ensure_init();
  luaL_requiref(L, "uv", luaopen_luv, 0); lua_pop(L, 1); /* guarantee the loop */
  uv_loop_t *loop = luv_loop(L);
  uv_mutex_lock(&B.mu);
  B.L = L;
  int first = !B.attached;
  if (first) {
    uv_async_init(loop, &B.drain, bus_drain_cb);
    uv_unref((uv_handle_t *)&B.drain); /* the drain must not hold the loop open */
    B.attached = 1;
  }
  uv_mutex_unlock(&B.mu);
  bus_drain_cb(&B.drain); /* flush any pre-attach backlog */
  lua_pushboolean(L, 1);
  return 1;
}

static const luaL_Reg bus_lib[] = {
  { "attach_main", l_attach_main },
  { "publish",     l_publish },
  { "subscribe",   l_subscribe },
  { "unsubscribe", l_unsubscribe },
  { "has",         l_has },
  { "push",        l_push },
  { "pull",        l_pull },
  { "qlen",        l_qlen },
  { "stats",       l_stats },
  { NULL, NULL }
};

int luaopen_boggart_bus(lua_State *L);
int luaopen_boggart_bus(lua_State *L) {
  ensure_init();
  luaL_newlib(L, bus_lib);
  return 1;
}
