/* lzmq.c -- the Lua `zmq` module: ZeroMQ sockets on the interpreter's uv loop,
 * plus the msgpack value codec (src/bmsgpack.c).
 *
 * C moves bytes; every protocol on top is Lua's: the LLM Station client and
 * any extension that speaks ZMQ. The same
 * plumbing -- one context per interpreter, a socket's ZMQ_FD parked on the uv
 * loop, the edge-triggered ZMQ_EVENTS loop -- also carries src/lstation.c's
 * LLM Station DEALER (src/bzmq.h is the C side of it).
 *
 *   local s = zmq.socket("DEALER", { identity = "node-1" })   -- or ROUTER, REQ, REP
 *   s:connect("tcp://127.0.0.1:5555")                         -- or s:bind(...)
 *   s:on_message(function(frames, sock) ... end)              -- from the loop
 *   s:send({ "", zmq.pack{ type = "HEARTBEAT" } })            -- multipart
 *   local frames, err = s:recv(100)                           -- or pull, bounded
 *   s:close()
 *
 * send never blocks (ZMQ_DONTWAIT): a full queue is nil, why, "again", a ROUTER
 * peer that is gone (router_mandatory) is nil, why, "unreachable". Callbacks
 * run on the main thread from inside uv.run, the same as luv's own callbacks:
 * they must not yield and must not run the loop themselves.
 *
 * Built by default; -DBOGGART_ZMQ=OFF is the escape hatch, and then
 * zmq.built() is false, zmq.socket() answers nil plus why, and the codec still
 * works.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>

#include <lua.h>
#include <lauxlib.h>
#include "bmsgpack.h"
#include "bzmq.h"

#ifdef BOGGART_ZMQ
#include <zmq.h>
#include <uv.h>
extern uv_loop_t *luv_loop(lua_State *L);
#endif

/* ---- the codec (every build) -------------------------------------------- */

static char g_null_key, g_array_key;

/* zmq.setup(null_sentinel, array_sentinel): the JSON sentinels the codec maps
 * nil-in-a-container and the empty array to. A caller passes
 * json.null / json.array. */
static int l_setup(lua_State *L) {
  lua_settop(L, 2);
  lua_pushvalue(L, 1); lua_rawsetp(L, LUA_REGISTRYINDEX, &g_null_key);
  lua_pushvalue(L, 2); lua_rawsetp(L, LUA_REGISTRYINDEX, &g_array_key);
  return 0;
}

/* Push the two sentinels; return their slots (0 when unset). */
static void push_sentinels(lua_State *L, int *null_idx, int *array_idx) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &g_null_key);
  *null_idx = lua_isnil(L, -1) ? 0 : lua_gettop(L);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &g_array_key);
  *array_idx = lua_isnil(L, -1) ? 0 : lua_gettop(L);
}

/* zmq.pack(value) -> bytes | nil, err */
static int l_pack(lua_State *L) {
  lua_settop(L, 1);
  int ni, ai;
  push_sentinels(L, &ni, &ai);
  bmp_buf o = { NULL, 0, 0, 0 };
  const char *err = NULL;
  if (!bmp_pack(L, 1, &o, ni, ai, &err)) {
    bmp_free(&o);
    lua_pushnil(L);
    lua_pushfstring(L, "msgpack: %s", err ? err : "encode failed");
    return 2;
  }
  lua_pushlstring(L, o.p ? o.p : "", o.n);
  bmp_free(&o);
  return 1;
}

/* zmq.unpack(bytes) -> value | nil, err */
static int l_unpack(lua_State *L) {
  size_t n;
  const char *s = luaL_checklstring(L, 1, &n);
  lua_settop(L, 1);
  int ni, ai;
  push_sentinels(L, &ni, &ai);
  const char *err = NULL;
  if (!bmp_unpack(L, (const unsigned char *)s, n, ni, ai, &err)) {
    lua_pushnil(L);
    lua_pushfstring(L, "msgpack: %s", err ? err : "decode failed");
    return 2;
  }
  return 1;
}

static int l_built(lua_State *L) {
#ifdef BOGGART_ZMQ
  lua_pushboolean(L, 1);
#else
  lua_pushboolean(L, 0);
#endif
  return 1;
}

static int l_version(lua_State *L) {
#ifdef BOGGART_ZMQ
  int a, b, c;
  zmq_version(&a, &b, &c);
  lua_pushfstring(L, "%d.%d.%d", a, b, c);
#else
  lua_pushnil(L);
#endif
  return 1;
}

#ifdef BOGGART_ZMQ

/* ---- the shared context and the tracked owners --------------------------- */

typedef struct { void *owner; void (*closer)(void *); int tag; } ztrack;

typedef struct zbox {
  void *ctx;
  ztrack *tr; int ntr, cap;
  bzmq_watch *watches;      /* live (not neutered) watches, for shutdown */
} zbox;

static char g_ctx_key;

static int zbox_gc(lua_State *L) {
  zbox *b = (zbox *)lua_touserdata(L, 1);
  /* closers untrack themselves; work from a copy */
  while (b->ntr > 0) {
    ztrack t = b->tr[b->ntr - 1];
    b->ntr--;
    if (t.closer) t.closer(t.owner);
  }
  free(b->tr); b->tr = NULL; b->cap = 0;
  if (b->ctx) { zmq_ctx_term(b->ctx); b->ctx = NULL; }
  return 0;
}

static zbox *get_box(lua_State *L) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &g_ctx_key);
  zbox *b = (zbox *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (b) return b;
  b = (zbox *)lua_newuserdatauv(L, sizeof(zbox), 0);
  memset(b, 0, sizeof(*b));
  b->ctx = zmq_ctx_new();
  if (luaL_newmetatable(L, "boggart.zmqctx")) {
    lua_pushcfunction(L, zbox_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &g_ctx_key);
  return b;
}

static zbox *peek_box(lua_State *L) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &g_ctx_key);
  zbox *b = (zbox *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  return b;
}

void *bzmq_context(lua_State *L) { return get_box(L)->ctx; }

int bzmq_track(lua_State *L, void *owner, void (*closer)(void *), int tag) {
  zbox *b = get_box(L);
  if (b->ntr == b->cap) {
    int cap = b->cap ? b->cap * 2 : 16;
    ztrack *nt = (ztrack *)realloc(b->tr, (size_t)cap * sizeof(ztrack));
    if (!nt) return 0;
    b->tr = nt; b->cap = cap;
  }
  b->tr[b->ntr].owner = owner;
  b->tr[b->ntr].closer = closer;
  b->tr[b->ntr].tag = tag;
  b->ntr++;
  return 1;
}

void bzmq_untrack(lua_State *L, void *owner) {
  zbox *b = peek_box(L);
  if (!b) return;
  for (int i = 0; i < b->ntr; i++) {
    if (b->tr[i].owner == owner) {
      b->tr[i] = b->tr[b->ntr - 1];
      b->ntr--;
      return;
    }
  }
}

int bzmq_count(lua_State *L, int tag) {
  zbox *b = peek_box(L);
  int n = 0;
  if (!b) return 0;
  for (int i = 0; i < b->ntr; i++) if (b->tr[i].tag == tag) n++;
  return n;
}

/* ---- watches -------------------------------------------------------------- */

struct bzmq_watch {
  uv_poll_t poll;
  uv_timer_t kick;
  void *sock;
  bzmq_ready_fn ready;
  void *ud;
  int stopped;      /* no more callbacks */
  int neutered;     /* handles handed to luv's exit walk; memory leaks on purpose */
  int closing;      /* handles still to close before free */
  int ref;
  zbox *box;
  bzmq_watch *next;
};

static void watch_unlink(bzmq_watch *w) {
  if (!w->box) return;
  bzmq_watch **pp = &w->box->watches;
  while (*pp) {
    if (*pp == w) { *pp = w->next; break; }
    pp = &(*pp)->next;
  }
  w->box = NULL;
  w->next = NULL;
}

static void kick_cb(uv_timer_t *t);

static void watch_run(bzmq_watch *w) {
  if (!w || w->stopped) return;
  for (;;) {
    int more = w->ready(w->ud);
    if (w->stopped) return;
    if (more) { uv_timer_start(&w->kick, kick_cb, 0, 0); return; }
    int ev = 0;
    size_t sz = sizeof ev;
    if (zmq_getsockopt(w->sock, ZMQ_EVENTS, &ev, &sz) != 0) return;
    if (!(ev & ZMQ_POLLIN)) return;
  }
}

static void poll_cb(uv_poll_t *h, int status, int events) {
  (void)status; (void)events;
  watch_run((bzmq_watch *)h->data);
}

static void kick_cb(uv_timer_t *t) { watch_run((bzmq_watch *)t->data); }

static void watch_close_cb(uv_handle_t *h) {
  bzmq_watch *w = (bzmq_watch *)h->data;
  if (!w) return;
  if (--w->closing == 0) free(w);
}

bzmq_watch *bzmq_watch_start(lua_State *L, void *sock, bzmq_ready_fn ready,
                             void *ud, int ref) {
  uv_loop_t *loop = luv_loop(L);
  if (!loop) return NULL;
  zmq_fd_t fd;
  size_t sz = sizeof fd;
  if (zmq_getsockopt(sock, ZMQ_FD, &fd, &sz) != 0) return NULL;
  bzmq_watch *w = (bzmq_watch *)calloc(1, sizeof(*w));
  if (!w) return NULL;
  if (uv_poll_init_socket(loop, &w->poll, (uv_os_sock_t)fd) != 0) { free(w); return NULL; }
  w->poll.data = w;
  if (uv_timer_init(loop, &w->kick) != 0) {
    w->closing = 1;
    uv_close((uv_handle_t *)&w->poll, watch_close_cb);
    return NULL;
  }
  w->kick.data = w;
  w->sock = sock; w->ready = ready; w->ud = ud; w->ref = ref;
  if (uv_poll_start(&w->poll, UV_READABLE, poll_cb) != 0) {
    w->closing = 2;
    uv_close((uv_handle_t *)&w->poll, watch_close_cb);
    uv_close((uv_handle_t *)&w->kick, watch_close_cb);
    return NULL;
  }
  if (!ref) {
    uv_unref((uv_handle_t *)&w->poll);
    uv_unref((uv_handle_t *)&w->kick);
  }
  zbox *b = get_box(L);
  w->box = b;
  w->next = b->watches;
  b->watches = w;
  /* Messages may already be queued (a fast peer): their edge happened before
   * the poll existed. One zero-delay drain catches them. */
  uv_timer_start(&w->kick, kick_cb, 0, 0);
  return w;
}

void bzmq_watch_kick(bzmq_watch *w) {
  if (!w || w->stopped || w->neutered) return;
  uv_timer_start(&w->kick, kick_cb, 0, 0);
}

void bzmq_watch_ref(bzmq_watch *w, int ref) {
  if (!w || w->stopped || w->neutered) return;
  w->ref = ref;
  if (ref) { uv_ref((uv_handle_t *)&w->poll); uv_ref((uv_handle_t *)&w->kick); }
  else { uv_unref((uv_handle_t *)&w->poll); uv_unref((uv_handle_t *)&w->kick); }
}

void bzmq_watch_stop(bzmq_watch *w) {
  if (!w || w->stopped) return;
  w->stopped = 1;
  if (w->neutered) return;         /* luv's exit walk owns the handles now */
  watch_unlink(w);
  uv_poll_stop(&w->poll);
  uv_timer_stop(&w->kick);
  w->closing = 2;
  uv_close((uv_handle_t *)&w->poll, watch_close_cb);
  uv_close((uv_handle_t *)&w->kick, watch_close_cb);
}

/* Stop each watch's handles and NULL their data so luv's loop_gc close-walk
 * (which casts handle->data to its own type) no-ops on them; the watch memory
 * leaks at exit on purpose, since that walk still touches the handles. */
void boggart_zmq_shutdown(lua_State *L) {
  zbox *b = peek_box(L);
  if (!b) return;
  bzmq_watch *w = b->watches;
  while (w) {
    bzmq_watch *next = w->next;
    uv_poll_stop(&w->poll);
    uv_timer_stop(&w->kick);
    w->poll.data = NULL;
    w->kick.data = NULL;
    w->neutered = 1;
    w->stopped = 1;
    w->box = NULL;
    w->next = NULL;
    w = next;
  }
  b->watches = NULL;
}

/* ---- the Lua socket -------------------------------------------------------- */

#define LZ_SOCK "boggart.zmq.socket"
#define LZ_BATCH 64          /* messages per wake before yielding the loop */
#define LZ_MAX_FRAMES 256    /* a message with more frames is not ours: dropped */

typedef struct lzsock {
  void *sock;               /* NULL once closed */
  int type;
  int ref;                  /* keep the loop alive while watching */
  bzmq_watch *w;
  lua_State *ML;            /* main thread: callbacks run there */
  int cb_ref, self_ref;
  lua_State *owner_L;       /* for untrack */
} lzsock;

static const struct { const char *name; int type; } k_types[] = {
  { "DEALER", ZMQ_DEALER }, { "ROUTER", ZMQ_ROUTER }, { "REQ", ZMQ_REQ },
  { "REP", ZMQ_REP }, { "PUB", ZMQ_PUB }, { "SUB", ZMQ_SUB },
  { "PUSH", ZMQ_PUSH }, { "PULL", ZMQ_PULL }, { "PAIR", ZMQ_PAIR },
  { NULL, 0 }
};

static const char *type_name(int t) {
  for (int i = 0; k_types[i].name; i++) if (k_types[i].type == t) return k_types[i].name;
  return "?";
}

static void lz_drop_refs(lzsock *s) {
  lua_State *L = s->ML;
  if (!L) return;
  if (s->cb_ref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, s->cb_ref); s->cb_ref = LUA_NOREF; }
  if (s->self_ref != LUA_NOREF) { luaL_unref(L, LUA_REGISTRYINDEX, s->self_ref); s->self_ref = LUA_NOREF; }
}

static void lz_close(lzsock *s) {
  if (s->w) { bzmq_watch_stop(s->w); s->w = NULL; }
  lz_drop_refs(s);
  if (s->sock) { zmq_close(s->sock); s->sock = NULL; }
}

static void lz_closer(void *owner) { lz_close((lzsock *)owner); }

static lzsock *check_sock(lua_State *L) {
  return (lzsock *)luaL_checkudata(L, 1, LZ_SOCK);
}

static lzsock *check_open(lua_State *L) {
  lzsock *s = check_sock(L);
  if (!s->sock) luaL_error(L, "zmq: socket is closed");
  return s;
}

static int push_zerr(lua_State *L, const char *what) {
  int e = zmq_errno();
  lua_pushnil(L);
  lua_pushfstring(L, "%s: %s", what, zmq_strerror(e));
  lua_pushstring(L, e == EAGAIN ? "again" : e == EHOSTUNREACH ? "unreachable"
                 : e == ETERM || e == ENOTSOCK ? "closed" : "error");
  return 3;
}

static void opt_int(lua_State *L, int t, const char *k, void *sock, int opt) {
  lua_getfield(L, t, k);
  if (lua_isinteger(L, -1) || lua_isnumber(L, -1)) {
    int v = (int)lua_tointeger(L, -1);
    zmq_setsockopt(sock, opt, &v, sizeof v);
  } else if (lua_isboolean(L, -1)) {
    int v = lua_toboolean(L, -1);
    zmq_setsockopt(sock, opt, &v, sizeof v);
  }
  lua_pop(L, 1);
}

/* zmq.socket(type[, opts]) -> sock | nil, err
 * opts: identity, linger (default 0), sndhwm, rcvhwm, maxmsgsize (default
 * 16 MiB; -1 = none), router_mandatory, immediate, reconnect_ivl,
 * reconnect_ivl_max, heartbeat_ivl, heartbeat_timeout, heartbeat_ttl,
 * subscribe (SUB), ref (default true). */
static int l_socket(lua_State *L) {
  const char *tn = luaL_checkstring(L, 1);
  int type = -1;
  for (int i = 0; k_types[i].name; i++)
    if (strcmp(k_types[i].name, tn) == 0) type = k_types[i].type;
  if (type < 0) return luaL_error(L, "zmq.socket: unknown socket type '%s'", tn);
  int has_opts = lua_istable(L, 2);
  zbox *b = get_box(L);
  if (!b->ctx) { lua_pushnil(L); lua_pushliteral(L, "zmq context failed"); return 2; }

  lzsock *s = (lzsock *)lua_newuserdatauv(L, sizeof(lzsock), 0);
  memset(s, 0, sizeof(*s));
  s->cb_ref = s->self_ref = LUA_NOREF;
  s->type = type;
  s->ref = 1;
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
  s->ML = lua_tothread(L, -1);
  lua_pop(L, 1);
  s->owner_L = s->ML;
  luaL_setmetatable(L, LZ_SOCK);

  s->sock = zmq_socket(b->ctx, type);
  if (!s->sock) return push_zerr(L, "zmq_socket");
  int zero = 0;
  int64_t maxmsg = 16 * 1024 * 1024;
  zmq_setsockopt(s->sock, ZMQ_LINGER, &zero, sizeof zero);
  if (has_opts) {
    lua_getfield(L, 2, "identity");
    if (lua_type(L, -1) == LUA_TSTRING) {
      size_t n; const char *id = lua_tolstring(L, -1, &n);
      if (n == 0 || n > 255) { lz_close(s); return luaL_error(L, "zmq.socket: identity must be 1..255 bytes"); }
      zmq_setsockopt(s->sock, ZMQ_ROUTING_ID, id, n);
    }
    lua_pop(L, 1);
    lua_getfield(L, 2, "maxmsgsize");
    if (lua_isinteger(L, -1)) maxmsg = (int64_t)lua_tointeger(L, -1);
    lua_pop(L, 1);
    opt_int(L, 2, "linger", s->sock, ZMQ_LINGER);
    opt_int(L, 2, "sndhwm", s->sock, ZMQ_SNDHWM);
    opt_int(L, 2, "rcvhwm", s->sock, ZMQ_RCVHWM);
    opt_int(L, 2, "router_mandatory", s->sock, ZMQ_ROUTER_MANDATORY);
    opt_int(L, 2, "immediate", s->sock, ZMQ_IMMEDIATE);
    opt_int(L, 2, "reconnect_ivl", s->sock, ZMQ_RECONNECT_IVL);
    opt_int(L, 2, "reconnect_ivl_max", s->sock, ZMQ_RECONNECT_IVL_MAX);
    opt_int(L, 2, "heartbeat_ivl", s->sock, ZMQ_HEARTBEAT_IVL);
    opt_int(L, 2, "heartbeat_timeout", s->sock, ZMQ_HEARTBEAT_TIMEOUT);
    opt_int(L, 2, "heartbeat_ttl", s->sock, ZMQ_HEARTBEAT_TTL);
    lua_getfield(L, 2, "subscribe");
    if (type == ZMQ_SUB && lua_type(L, -1) == LUA_TSTRING) {
      size_t n; const char *t = lua_tolstring(L, -1, &n);
      zmq_setsockopt(s->sock, ZMQ_SUBSCRIBE, t, n);
    }
    lua_pop(L, 1);
    lua_getfield(L, 2, "ref");
    if (lua_isboolean(L, -1)) s->ref = lua_toboolean(L, -1);
    lua_pop(L, 1);
  }
  zmq_setsockopt(s->sock, ZMQ_MAXMSGSIZE, &maxmsg, sizeof maxmsg);
  if (!bzmq_track(L, s, lz_closer, BZMQ_TAG_LZMQ)) {
    lz_close(s);
    lua_pushnil(L); lua_pushliteral(L, "out of memory");
    return 2;
  }
  return 1;
}

static int endpoint_op(lua_State *L, int (*op)(void *, const char *), const char *what) {
  lzsock *s = check_open(L);
  const char *ep = luaL_checkstring(L, 2);
  if (op(s->sock, ep) != 0) return push_zerr(L, what);
  lua_pushboolean(L, 1);
  return 1;
}
static int l_bind(lua_State *L) { return endpoint_op(L, zmq_bind, "bind"); }
static int l_connect(lua_State *L) { return endpoint_op(L, zmq_connect, "connect"); }
static int l_unbind(lua_State *L) { return endpoint_op(L, zmq_unbind, "unbind"); }
static int l_disconnect(lua_State *L) { return endpoint_op(L, zmq_disconnect, "disconnect"); }

/* s:endpoint() -> the last bound/connected endpoint (a tcp://host:* bind
 * reports the port the kernel picked). */
static int l_endpoint(lua_State *L) {
  lzsock *s = check_open(L);
  char buf[256];
  size_t sz = sizeof buf;
  if (zmq_getsockopt(s->sock, ZMQ_LAST_ENDPOINT, buf, &sz) != 0) return push_zerr(L, "endpoint");
  lua_pushstring(L, buf);
  return 1;
}

static int l_identity(lua_State *L) {
  lzsock *s = check_open(L);
  char buf[256];
  size_t sz = sizeof buf;
  if (zmq_getsockopt(s->sock, ZMQ_ROUTING_ID, buf, &sz) != 0) return push_zerr(L, "identity");
  lua_pushlstring(L, buf, sz);
  return 1;
}

static int l_type(lua_State *L) {
  lzsock *s = check_sock(L);
  lua_pushstring(L, type_name(s->type));
  return 1;
}

/* s:send(frames) -> true | nil, err, code. frames: a string (one frame) or an
 * array of strings (multipart). Never blocks. */
static int l_send(lua_State *L) {
  lzsock *s = check_open(L);
  int n;
  if (lua_type(L, 2) == LUA_TSTRING) n = 1;
  else {
    luaL_checktype(L, 2, LUA_TTABLE);
    n = (int)lua_rawlen(L, 2);
    if (n < 1) return luaL_error(L, "zmq send: no frames");
    for (int i = 1; i <= n; i++) {
      if (lua_rawgeti(L, 2, i) != LUA_TSTRING) return luaL_error(L, "zmq send: frame %d is not a string", i);
      lua_pop(L, 1);
    }
  }
  for (int i = 1; i <= n; i++) {
    size_t len;
    const char *p;
    if (n == 1 && lua_type(L, 2) == LUA_TSTRING) p = lua_tolstring(L, 2, &len);
    else { lua_rawgeti(L, 2, i); p = lua_tolstring(L, -1, &len); lua_pop(L, 1); }
    int flags = ZMQ_DONTWAIT | (i < n ? ZMQ_SNDMORE : 0);
    if (zmq_send(s->sock, p, len, flags) < 0) {
      /* A failure on frame 1 sends nothing; later frames cannot fail with
       * EAGAIN once the first went (libzmq queues a message atomically). */
      return push_zerr(L, "send");
    }
  }
  /* The send may have consumed the fd edge for messages already queued. */
  if (s->w) {
    int ev = 0; size_t sz = sizeof ev;
    if (zmq_getsockopt(s->sock, ZMQ_EVENTS, &ev, &sz) == 0 && (ev & ZMQ_POLLIN))
      bzmq_watch_kick(s->w);
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* Receive one whole message without waiting: pushes a frames table and
 * returns 1, returns 0 when nothing is queued, -1 on a torn/oversize one. */
static int recv_frames(lua_State *L, lzsock *s) {
  int nframe = 0, more = 1, ok = 1;
  while (more) {
    zmq_msg_t m;
    zmq_msg_init(&m);
    if (zmq_msg_recv(&m, s->sock, ZMQ_DONTWAIT) < 0) {
      zmq_msg_close(&m);
      if (nframe == 0) return 0;
      ok = 0;
      break;
    }
    if (nframe == 0) lua_createtable(L, 4, 0);
    if (nframe < LZ_MAX_FRAMES) {
      lua_pushlstring(L, (const char *)zmq_msg_data(&m), zmq_msg_size(&m));
      lua_rawseti(L, -2, nframe + 1);
    } else ok = 0;
    more = zmq_msg_more(&m);
    zmq_msg_close(&m);
    nframe++;
  }
  if (!ok) { lua_pop(L, 1); return -1; }
  return 1;
}

/* s:recv([timeout_ms]) -> frames | nil, "timeout" | err. Pull mode (no
 * on_message): waits up to timeout_ms (0 = just look; -1 = forever, never
 * under the scheduler). */
static int l_recv(lua_State *L) {
  lzsock *s = check_open(L);
  int ms = (int)luaL_optinteger(L, 2, 0);
  if (s->cb_ref != LUA_NOREF) return luaL_error(L, "zmq recv: socket has an on_message handler");
  for (;;) {
    int r = recv_frames(L, s);
    if (r == 1) return 1;
    if (r < 0) continue;            /* dropped a malformed message; look again */
    if (ms == 0) break;
    zmq_pollitem_t it = { s->sock, 0, ZMQ_POLLIN, 0 };
    int pr = zmq_poll(&it, 1, ms);
    if (pr < 0) return push_zerr(L, "poll");
    if (pr == 0) break;
    ms = 0;                         /* readable: one more look, then give up */
    r = recv_frames(L, s);
    if (r == 1) return 1;
    break;
  }
  lua_pushnil(L);
  lua_pushliteral(L, "timeout");
  return 2;
}

static int lz_traceback(lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  luaL_traceback(L, L, msg ? msg : "(non-string error)", 1);
  return 1;
}

static int lz_ready(void *ud) {
  lzsock *s = (lzsock *)ud;
  lua_State *L = s->ML;
  for (int n = 0; n < LZ_BATCH; n++) {
    if (!s->sock || s->cb_ref == LUA_NOREF) return 0;
    int top = lua_gettop(L);
    if (!lua_checkstack(L, 8)) return 0;
    lua_pushcfunction(L, lz_traceback);
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->cb_ref);
    int r = recv_frames(L, s);
    if (r == 0) { lua_settop(L, top); return 0; }
    if (r < 0) { lua_settop(L, top); continue; }
    lua_rawgeti(L, LUA_REGISTRYINDEX, s->self_ref);
    if (lua_pcall(L, 2, 0, top + 1) != LUA_OK) {
      const char *why = lua_tostring(L, -1);
      fprintf(stderr, "zmq: on_message handler failed: %s\n", why ? why : "?");
    }
    lua_settop(L, top);
  }
  return 1;
}

/* s:on_message(fn | nil): fn(frames, sock) runs from the loop for every
 * message. Setting one parks the socket on the loop (and, unless ref=false,
 * keeps the loop alive); nil detaches. */
static int l_on_message(lua_State *L) {
  lzsock *s = check_open(L);
  if (lua_isnoneornil(L, 2)) {
    if (s->w) { bzmq_watch_stop(s->w); s->w = NULL; }
    lz_drop_refs(s);
    lua_pushboolean(L, 1);
    return 1;
  }
  luaL_checktype(L, 2, LUA_TFUNCTION);
  lz_drop_refs(s);
  lua_pushvalue(L, 2);
  s->cb_ref = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_pushvalue(L, 1);
  s->self_ref = luaL_ref(L, LUA_REGISTRYINDEX);   /* a watched socket is not garbage */
  if (!s->w) {
    s->w = bzmq_watch_start(L, s->sock, lz_ready, s, s->ref);
    if (!s->w) {
      lz_drop_refs(s);
      lua_pushnil(L);
      lua_pushliteral(L, "zmq: cannot watch the socket on the uv loop");
      return 2;
    }
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* s:ref(bool): whether a watched socket keeps the loop alive. */
static int l_ref(lua_State *L) {
  lzsock *s = check_sock(L);
  s->ref = lua_toboolean(L, 2);
  if (s->w) bzmq_watch_ref(s->w, s->ref);
  return 0;
}

/* s:pump([ms]) -> handled. Waits up to ms for input, then runs the
 * on_message handler for everything queued: for callers with no loop. */
static int l_pump(lua_State *L) {
  lzsock *s = check_open(L);
  int ms = (int)luaL_optinteger(L, 2, 0);
  if (s->cb_ref == LUA_NOREF) return luaL_error(L, "zmq pump: no on_message handler");
  if (ms > 0) {
    zmq_pollitem_t it = { s->sock, 0, ZMQ_POLLIN, 0 };
    zmq_poll(&it, 1, ms);
  }
  lz_ready(s);
  lua_pushboolean(L, 1);
  return 1;
}

static int l_events(lua_State *L) {
  lzsock *s = check_open(L);
  int ev = 0; size_t sz = sizeof ev;
  zmq_getsockopt(s->sock, ZMQ_EVENTS, &ev, &sz);
  lua_pushboolean(L, ev & ZMQ_POLLIN);
  lua_pushboolean(L, ev & ZMQ_POLLOUT);
  return 2;
}

static int l_close(lua_State *L) {
  lzsock *s = check_sock(L);
  if (s->sock || s->w) {
    lz_close(s);
    bzmq_untrack(L, s);
  }
  return 0;
}

static int l_is_closed(lua_State *L) {
  lzsock *s = check_sock(L);
  lua_pushboolean(L, s->sock == NULL);
  return 1;
}

static int l_tostring(lua_State *L) {
  lzsock *s = check_sock(L);
  lua_pushfstring(L, "zmq.socket(%s%s)", type_name(s->type), s->sock ? "" : ", closed");
  return 1;
}

static int l_socket_api(lua_State *L) { return l_socket(L); }

#else /* !BOGGART_ZMQ */

void *bzmq_context(lua_State *L) { (void)L; return NULL; }
int bzmq_track(lua_State *L, void *o, void (*c)(void *), int t) { (void)L; (void)o; (void)c; (void)t; return 0; }
void bzmq_untrack(lua_State *L, void *o) { (void)L; (void)o; }
int bzmq_count(lua_State *L, int t) { (void)L; (void)t; return 0; }
bzmq_watch *bzmq_watch_start(lua_State *L, void *s, bzmq_ready_fn r, void *u, int ref) {
  (void)L; (void)s; (void)r; (void)u; (void)ref; return NULL;
}
void bzmq_watch_stop(bzmq_watch *w) { (void)w; }
void bzmq_watch_kick(bzmq_watch *w) { (void)w; }
void bzmq_watch_ref(bzmq_watch *w, int ref) { (void)w; (void)ref; }
void boggart_zmq_shutdown(lua_State *L) { (void)L; }

static int l_socket_api(lua_State *L) {
  lua_pushnil(L);
  lua_pushliteral(L, "zmq support not built (configure with -DBOGGART_ZMQ=ON)");
  return 2;
}

#endif /* BOGGART_ZMQ */

static const luaL_Reg zmq_lib[] = {
  { "built", l_built },
  { "version", l_version },
  { "socket", l_socket_api },
  { "pack", l_pack },
  { "unpack", l_unpack },
  { "setup", l_setup },
  { NULL, NULL }
};

int luaopen_boggart_zmq(lua_State *L);
int luaopen_boggart_zmq(lua_State *L) {
#ifdef BOGGART_ZMQ
  if (luaL_newmetatable(L, LZ_SOCK)) {
    static const luaL_Reg m[] = {
      { "bind", l_bind }, { "connect", l_connect }, { "unbind", l_unbind },
      { "disconnect", l_disconnect }, { "endpoint", l_endpoint },
      { "identity", l_identity }, { "type", l_type }, { "send", l_send },
      { "recv", l_recv }, { "on_message", l_on_message }, { "ref", l_ref },
      { "pump", l_pump }, { "events", l_events }, { "close", l_close },
      { "closed", l_is_closed }, { NULL, NULL }
    };
    luaL_newlib(L, m);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, l_close);
    lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, l_tostring);
    lua_setfield(L, -2, "__tostring");
  }
  lua_pop(L, 1);
#endif
  luaL_newlib(L, zmq_lib);
  return 1;
}
