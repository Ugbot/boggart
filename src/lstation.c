/* lstation.c -- native client for LLM Station's ZeroMQ daemon protocol.
 *
 * LLM Station (the C++ IDE daemon) speaks ROUTER/DEALER: one ROUTER socket
 * per workspace, msgpack envelopes, topic pub/sub folded onto the same
 * socket. This module is boggart's DEALER end of that wire -- the transport
 * that replaces the MCP stdio detour when a station is reachable. C moves
 * bytes; every policy decision (which tool, when, what to fall back to) is
 * Lua's, in lua/station.lua. Plan of record: docs/station-zmq.md.
 *
 * STRICTLY OPT-IN. The file is compiled into both binaries unconditionally
 * (the lvoice.c doctrine), but the socket layer exists only when configured
 * with -DBOGGART_STATION=ON; without it, station.built() == false,
 * station.connect() returns nil + an explanatory error, and nothing else in
 * boggart changes. Two pieces work even in a default build, because they
 * need no libzmq: endpoint discovery (a SQLite read of llm-station's own
 * config.db) and the msgpack envelope codec (exposed as station._encode /
 * station._decode so the default-build test suite can exercise the wire
 * format headlessly).
 *
 * The wire, from llm-station's src/daemon/DaemonProtocol.h:
 *   DEALER sends/receives 4 frames -- [empty][channel][corr_id|topic][payload]
 *   (the ROUTER sees 5; libzmq adds and strips the identity frame). The
 *   payload is a msgpack map {msg_type, tool, payload} where the inner
 *   payload is a FLAT map<string,string> -- no ints, no floats, no nesting.
 *   Unknown keys are ignored and missing keys default on both ends, so the
 *   format is forward compatible by construction. Channels: "cmd" (ack now,
 *   result later), "query" (answered inline on the daemon's poll thread --
 *   the interactive path), "sub"/"unsub" (topics); inbound "result",
 *   "event" (frame 2 is the topic, not a corr id) and "error". Two distinct
 *   error keys: payload["error"] is a protocol error, payload["err"] (beside
 *   ok="false") is a tool failure. Both are surfaced to Lua as data.
 *
 * Discovery reads `SELECT port FROM projects WHERE path = ?` from
 * ~/.llm-station/config.db ($LLM_STATION_HOME and $XDG_DATA_HOME override),
 * keyed by the CANONICAL workspace root. A miss means "no station" -- the
 * C++ client's hash-of-path port fallback is deliberately not reimplemented:
 * it is implementation-defined std::hash AND it can collide onto another
 * workspace's live daemon. boggart only ever connects, never binds, so the
 * historic studio bind race cannot recur from here.
 *
 * Crash tolerance is the contract, not a feature. The daemon's correlation
 * state is all in RAM, so a daemon restart makes every outstanding corr_id
 * garbage: pending calls carry deadlines and fail with a clean error rather
 * than being re-awaited, and a dead daemon costs whoever asked one timeout,
 * never a hang. Liveness policy (pings, reconnect backoff, station.up/down
 * bus events) lives in Lua on top of conn:pump() and short call deadlines.
 *
 * Waiting follows lmcp.c: under the swarm scheduler a call handle yields
 * ("io", handle) so other agents keep running; off a coroutine it polls in
 * short slices. Unsolicited event frames become bus events
 * ("station.<topic>", payload as JSON) via bus_emit, the same fabric the
 * studio already attaches to. (A ZMQ_FD/uv_poll integration -- BSTAT-9 --
 * can replace the slice polling later without changing this surface.)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <lua.h>
#include <lauxlib.h>
#include "sqlite3.h"
#include "cJSON.h"

#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#else
#include <unistd.h>
#include <limits.h>
#include <sys/time.h>
#endif

#ifdef BOGGART_STATION
#include <zmq.h>
#endif

void bus_emit(const char *topic, const char *data, size_t len); /* src/lbus.c */

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* ---- endpoint discovery (no libzmq needed) ------------------------------- */

static int st_global_dir(char *out, size_t n) {
  const char *e = getenv("LLM_STATION_HOME");
  if (e && *e) { snprintf(out, n, "%s", e); return 1; }
  e = getenv("XDG_DATA_HOME");
  if (e && *e) { snprintf(out, n, "%s/llm-station", e); return 1; }
  e = getenv("HOME");
#ifdef _WIN32
  if (!e || !*e) e = getenv("USERPROFILE");
#endif
  if (e && *e) { snprintf(out, n, "%s/.llm-station", e); return 1; }
  return 0;
}

static int st_canon(const char *in, char *out, size_t n) {
#ifdef _WIN32
  if (_fullpath(out, in, n)) return 1;
#else
  char buf[PATH_MAX];
  if (realpath(in, buf)) { snprintf(out, n, "%s", buf); return 1; }
#endif
  snprintf(out, n, "%s", in);
  return 1;
}

/* The port for a workspace, or 0 with *err set (static string). Opened
 * read-write when possible -- llm-station's own client notes that WAL reads
 * of the daemon's writes need it -- falling back to read-only. */
static int st_lookup_port(const char *workspace, const char **err) {
  char canon[PATH_MAX], dir[PATH_MAX], dbpath[PATH_MAX + 32];
  *err = NULL;
  if (!workspace || !*workspace) { *err = "no workspace path"; return 0; }
  st_canon(workspace, canon, sizeof canon);
  if (!st_global_dir(dir, sizeof dir)) { *err = "no home directory"; return 0; }
  snprintf(dbpath, sizeof dbpath, "%s/config.db", dir);

  sqlite3 *db = NULL;
  if (sqlite3_open_v2(dbpath, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
    if (db) sqlite3_close(db);
    db = NULL;
    if (sqlite3_open_v2(dbpath, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
      if (db) sqlite3_close(db);
      *err = "no llm-station config.db (is llm-station installed?)";
      return 0;
    }
  }
  sqlite3_busy_timeout(db, 1000);

  sqlite3_stmt *stmt = NULL;
  int port = 0;
  if (sqlite3_prepare_v2(db, "SELECT port FROM projects WHERE path = ?", -1,
                         &stmt, NULL) == SQLITE_OK) {
    sqlite3_bind_text(stmt, 1, canon, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW) port = sqlite3_column_int(stmt, 0);
  }
  if (stmt) sqlite3_finalize(stmt);
  sqlite3_close(db);

  if (port <= 0)
    *err = "workspace not registered with llm-station (no projects row)";
  return port;
}

/* station.endpoint([workspace]) -> "tcp://127.0.0.1:<port>", port | nil, why.
 * Discovery only -- says where a daemon WOULD be, not whether one is alive. */
static int l_endpoint(lua_State *L) {
  const char *ws = luaL_optstring(L, 1, ".");
  const char *err = NULL;
  int port = st_lookup_port(ws, &err);
  if (port <= 0) {
    lua_pushnil(L);
    lua_pushstring(L, err ? err : "not found");
    return 2;
  }
  lua_pushfstring(L, "tcp://127.0.0.1:%d", port);
  lua_pushinteger(L, port);
  return 2;
}

/* ---- msgpack envelope codec (no libzmq needed) ---------------------------
 * Exactly the subset the wire uses: maps and strings. Encoding emits fixmap/
 * map16/map32 and fixstr/str8/str16/str32; decoding additionally skips over
 * any other well-formed value so an envelope that grows a non-string field
 * some day degrades to "key ignored", not "connection broken". */

typedef struct { luaL_Buffer b; lua_State *L; } stbuf;

static void mp_bytes(stbuf *o, const void *p, size_t n) {
  luaL_addlstring(&o->b, (const char *)p, n);
}
static void mp_u8(stbuf *o, unsigned char c) { luaL_addchar(&o->b, (char)c); }

static void mp_str(stbuf *o, const char *s, size_t n) {
  if (n < 32) {
    mp_u8(o, (unsigned char)(0xa0 | n));
  } else if (n < 256) {
    mp_u8(o, 0xd9); mp_u8(o, (unsigned char)n);
  } else if (n < 65536) {
    mp_u8(o, 0xda); mp_u8(o, (unsigned char)(n >> 8)); mp_u8(o, (unsigned char)n);
  } else {
    mp_u8(o, 0xdb);
    mp_u8(o, (unsigned char)(n >> 24)); mp_u8(o, (unsigned char)(n >> 16));
    mp_u8(o, (unsigned char)(n >> 8));  mp_u8(o, (unsigned char)n);
  }
  mp_bytes(o, s, n);
}

static void mp_map_header(stbuf *o, size_t n) {
  if (n < 16) {
    mp_u8(o, (unsigned char)(0x80 | n));
  } else if (n < 65536) {
    mp_u8(o, 0xde); mp_u8(o, (unsigned char)(n >> 8)); mp_u8(o, (unsigned char)n);
  } else {
    mp_u8(o, 0xdf);
    mp_u8(o, (unsigned char)(n >> 24)); mp_u8(o, (unsigned char)(n >> 16));
    mp_u8(o, (unsigned char)(n >> 8));  mp_u8(o, (unsigned char)n);
  }
}

/* Encode {msg_type, tool, payload} from (msg_type, tool|nil, table|nil) at
 * stack slots base..base+2, leaving the encoded string on top. The inner
 * payload accepts string keys with string-or-number values (numbers are
 * stringified -- the wire is flat strings by design, STATION-138). */
static int envelope_encode(lua_State *L, int base) {
  size_t mtn, tooln;
  const char *mt = luaL_checklstring(L, base, &mtn);
  const char *tool = luaL_optlstring(L, base + 1, "", &tooln);
  int has_payload = !lua_isnoneornil(L, base + 2);
  if (has_payload) luaL_checktype(L, base + 2, LUA_TTABLE);

  stbuf o;
  o.L = L;
  luaL_buffinit(L, &o.b);
  mp_map_header(&o, 3);
  mp_str(&o, "msg_type", 8); mp_str(&o, mt, mtn);
  mp_str(&o, "tool", 4);     mp_str(&o, tool, tooln);
  mp_str(&o, "payload", 7);

  size_t count = 0;
  if (has_payload) {
    lua_pushnil(L);
    while (lua_next(L, base + 2)) {
      if (lua_type(L, -2) == LUA_TSTRING &&
          (lua_type(L, -1) == LUA_TSTRING || lua_type(L, -1) == LUA_TNUMBER))
        count++;
      lua_pop(L, 1);
    }
  }
  mp_map_header(&o, count);
  if (has_payload) {
    lua_pushnil(L);
    while (lua_next(L, base + 2)) {
      if (lua_type(L, -2) == LUA_TSTRING &&
          (lua_type(L, -1) == LUA_TSTRING || lua_type(L, -1) == LUA_TNUMBER)) {
        size_t kn, vn;
        const char *k = lua_tolstring(L, -2, &kn);
        /* tolstring on the VALUE copy, never the key: converting the key in
         * place would corrupt lua_next's traversal. */
        lua_pushvalue(L, -1);
        const char *v = lua_tolstring(L, -1, &vn);
        mp_str(&o, k, kn);
        mp_str(&o, v, vn);
        lua_pop(L, 1);
      }
      lua_pop(L, 1);
    }
  }
  luaL_pushresult(&o.b);
  return 1;
}

static int l_encode(lua_State *L) { return envelope_encode(L, 1); }

/* -- decoding -- */

typedef struct { const unsigned char *p, *end; } stcur;

static int rd_need(stcur *c, size_t n) { return (size_t)(c->end - c->p) >= n; }

static int rd_str(stcur *c, const char **s, size_t *n) {
  if (!rd_need(c, 1)) return 0;
  unsigned char t = *c->p;
  size_t len;
  if ((t & 0xe0) == 0xa0)      { len = t & 0x1f; c->p += 1; }
  else if (t == 0xd9) { if (!rd_need(c, 2)) return 0; len = c->p[1]; c->p += 2; }
  else if (t == 0xda) { if (!rd_need(c, 3)) return 0; len = ((size_t)c->p[1] << 8) | c->p[2]; c->p += 3; }
  else if (t == 0xdb) { if (!rd_need(c, 5)) return 0;
    len = ((size_t)c->p[1] << 24) | ((size_t)c->p[2] << 16) |
          ((size_t)c->p[3] << 8) | c->p[4]; c->p += 5; }
  else return 0;
  if (!rd_need(c, len)) return 0;
  *s = (const char *)c->p; *n = len; c->p += len;
  return 1;
}

static int rd_map_header(stcur *c, size_t *n) {
  if (!rd_need(c, 1)) return 0;
  unsigned char t = *c->p;
  if ((t & 0xf0) == 0x80)      { *n = t & 0x0f; c->p += 1; return 1; }
  if (t == 0xde) { if (!rd_need(c, 3)) return 0; *n = ((size_t)c->p[1] << 8) | c->p[2]; c->p += 3; return 1; }
  if (t == 0xdf) { if (!rd_need(c, 5)) return 0;
    *n = ((size_t)c->p[1] << 24) | ((size_t)c->p[2] << 16) |
         ((size_t)c->p[3] << 8) | c->p[4]; c->p += 5; return 1; }
  return 0;
}

/* Skip one well-formed value of any common type, so unknown fields are
 * ignored rather than fatal. Depth-capped: the wire is flat, so anything
 * deeply nested is garbage, and refusing beats recursing. */
static int rd_skip(stcur *c, int depth) {
  if (depth > 8 || !rd_need(c, 1)) return 0;
  unsigned char t = *c->p;
  const char *s; size_t n;
  if ((t & 0xe0) == 0xa0 || t == 0xd9 || t == 0xda || t == 0xdb)
    return rd_str(c, &s, &n);
  if ((t & 0xf0) == 0x80 || t == 0xde || t == 0xdf) {
    if (!rd_map_header(c, &n)) return 0;
    for (size_t i = 0; i < n * 2; i++)
      if (!rd_skip(c, depth + 1)) return 0;
    return 1;
  }
  if ((t & 0xf0) == 0x90 || t == 0xdc || t == 0xdd) { /* arrays */
    size_t cnt;
    if ((t & 0xf0) == 0x90) { cnt = t & 0x0f; c->p += 1; }
    else if (t == 0xdc) { if (!rd_need(c, 3)) return 0; cnt = ((size_t)c->p[1] << 8) | c->p[2]; c->p += 3; }
    else { if (!rd_need(c, 5)) return 0;
      cnt = ((size_t)c->p[1] << 24) | ((size_t)c->p[2] << 16) |
            ((size_t)c->p[3] << 8) | c->p[4]; c->p += 5; }
    for (size_t i = 0; i < cnt; i++)
      if (!rd_skip(c, depth + 1)) return 0;
    return 1;
  }
  if (t <= 0x7f || t >= 0xe0) { c->p += 1; return 1; }         /* fixint */
  if (t == 0xc0 || t == 0xc2 || t == 0xc3) { c->p += 1; return 1; } /* nil/bool */
  switch (t) { /* sized scalars and bins */
    case 0xcc: case 0xd0: n = 2; break;
    case 0xcd: case 0xd1: n = 3; break;
    case 0xce: case 0xd2: case 0xca: n = 5; break;
    case 0xcf: case 0xd3: case 0xcb: n = 9; break;
    case 0xc4: if (!rd_need(c, 2)) return 0; n = 2 + c->p[1]; break;
    case 0xc5: if (!rd_need(c, 3)) return 0; n = 3 + (((size_t)c->p[1] << 8) | c->p[2]); break;
    default: return 0;
  }
  if (!rd_need(c, n)) return 0;
  c->p += n;
  return 1;
}

/* Decode an envelope into (msg_type, tool, payload_table); pushes those three
 * onto the stack and returns 3, or pushes nil + error and returns 2. */
static int envelope_decode(lua_State *L, const unsigned char *data, size_t len) {
  stcur c = { data, data + len };
  size_t fields;
  if (!rd_map_header(&c, &fields)) {
    lua_pushnil(L); lua_pushliteral(L, "not a msgpack map");
    return 2;
  }
  lua_pushliteral(L, "");           /* msg_type placeholder */
  lua_pushliteral(L, "");           /* tool placeholder */
  lua_newtable(L);                  /* payload */
  int base = lua_gettop(L) - 2;

  for (size_t i = 0; i < fields; i++) {
    const char *k; size_t kn;
    if (!rd_str(&c, &k, &kn)) goto bad;
    if (kn == 8 && memcmp(k, "msg_type", 8) == 0) {
      const char *v; size_t vn;
      if (!rd_str(&c, &v, &vn)) goto bad;
      lua_pushlstring(L, v, vn); lua_replace(L, base);
    } else if (kn == 4 && memcmp(k, "tool", 4) == 0) {
      const char *v; size_t vn;
      if (!rd_str(&c, &v, &vn)) goto bad;
      lua_pushlstring(L, v, vn); lua_replace(L, base + 1);
    } else if (kn == 7 && memcmp(k, "payload", 7) == 0) {
      size_t pairs;
      if (!rd_map_header(&c, &pairs)) goto bad;
      for (size_t j = 0; j < pairs; j++) {
        const char *pk; size_t pkn;
        if (!rd_str(&c, &pk, &pkn)) goto bad;
        const char *pv; size_t pvn;
        stcur save = c;
        if (rd_str(&c, &pv, &pvn)) {
          lua_pushlstring(L, pk, pkn);
          lua_pushlstring(L, pv, pvn);
          lua_rawset(L, base + 2);
        } else {
          c = save;
          if (!rd_skip(&c, 0)) goto bad; /* non-string value: key ignored */
        }
      }
    } else {
      if (!rd_skip(&c, 0)) goto bad;
    }
  }
  return 3;
bad:
  lua_settop(L, base - 1);
  lua_pushnil(L); lua_pushliteral(L, "truncated or malformed envelope");
  return 2;
}

static int l_decode(lua_State *L) {
  size_t n;
  const char *s = luaL_checklstring(L, 1, &n);
  return envelope_decode(L, (const unsigned char *)s, n);
}

/* ---- built / available ---------------------------------------------------- */

static int l_built(lua_State *L) {
#ifdef BOGGART_STATION
  lua_pushboolean(L, 1);
#else
  lua_pushboolean(L, 0);
#endif
  return 1;
}

/* built AND the workspace is registered. Not a liveness probe -- that is a
 * ping over a connection, and policy in lua/station.lua. */
static int l_available(lua_State *L) {
#ifdef BOGGART_STATION
  const char *ws = luaL_optstring(L, 1, ".");
  const char *err = NULL;
  lua_pushboolean(L, st_lookup_port(ws, &err) > 0);
#else
  (void)L;
  lua_pushboolean(L, 0);
#endif
  return 1;
}

#ifdef BOGGART_STATION

/* ---- the DEALER connection ------------------------------------------------ */

#define API_TYPE_STATION "boggart.station"
#define API_TYPE_STCALL  "boggart.stationcall"
#define ST_MAX_PENDING 64
#define ST_MAX_CONNS 16
#define ST_YIELD_MS 10   /* poll slice before yielding under the scheduler */
#define ST_SLICE_MS 25   /* poll slice when blocking off-coroutine */
#define ST_DEFAULT_TIMEOUT_MS 30000

static uint64_t now_ms(void) {
#ifdef _WIN32
  return (uint64_t)GetTickCount64();
#else
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (uint64_t)tv.tv_sec * 1000 + (uint64_t)(tv.tv_usec / 1000);
#endif
}

typedef struct stconn stconn;

typedef struct stcall {
  stconn *c;                /* NULL after the conn closes under it */
  char corr[48];
  int done;
  int acked;                /* cmd channel: daemon acked, result still due */
  char channel[16];         /* reply channel: result / error */
  char *reply; size_t reply_n; /* raw envelope bytes, malloc'd */
  const char *err;          /* static string when failed */
  uint64_t deadline;
} stcall;

struct stconn {
  void *sock;               /* NULL after close */
  int dead;
  char endpoint[64];
  stcall *pending[ST_MAX_PENDING];
  struct zctxbox *box;
};

/* One zmq context per interpreter, in the registry. Its __gc closes any
 * socket still open BEFORE zmq_ctx_term: term blocks until every socket is
 * closed, and __gc order between the context and a leftover connection is
 * undefined -- resolving that here is what makes lua_close never hang. */
typedef struct zctxbox {
  void *ctx;
  stconn *conns[ST_MAX_CONNS];
} zctxbox;

static char g_zctx_key;

static void conn_fail_pending(stconn *c, const char *why) {
  for (int i = 0; i < ST_MAX_PENDING; i++) {
    stcall *h = c->pending[i];
    if (h && !h->done) { h->err = why; h->done = 1; }
    if (h) h->c = NULL;
    c->pending[i] = NULL;
  }
}

static void conn_close(stconn *c) {
  if (c->sock) { zmq_close(c->sock); c->sock = NULL; }
  c->dead = 1;
  conn_fail_pending(c, "station connection closed");
  if (c->box) {
    for (int i = 0; i < ST_MAX_CONNS; i++)
      if (c->box->conns[i] == c) c->box->conns[i] = NULL;
    c->box = NULL;
  }
}

static int zctx_gc(lua_State *L) {
  zctxbox *b = (zctxbox *)lua_touserdata(L, 1);
  for (int i = 0; i < ST_MAX_CONNS; i++)
    if (b->conns[i]) conn_close(b->conns[i]);
  if (b->ctx) { zmq_ctx_term(b->ctx); b->ctx = NULL; }
  return 0;
}

static zctxbox *get_ctx(lua_State *L) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &g_zctx_key);
  zctxbox *b = (zctxbox *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (b) return b;
  b = (zctxbox *)lua_newuserdatauv(L, sizeof(zctxbox), 0);
  memset(b, 0, sizeof(*b));
  b->ctx = zmq_ctx_new();
  if (luaL_newmetatable(L, "boggart.stationctx")) {
    lua_pushcfunction(L, zctx_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_setmetatable(L, -2);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &g_zctx_key);
  return b;
}

/* Deliver one inbound multipart message. frames[0] is the empty delimiter;
 * [1] channel, [2] corr id or topic, [3] the envelope. */
static void route_message(stconn *c, char frames[][256], size_t lens[],
                          const unsigned char *payload, size_t payload_n,
                          lua_State *L) {
  const char *channel = frames[1];
  if (strcmp(channel, "event") == 0) {
    /* Topic pub/sub: re-emit on boggart's bus as station.<topic>, envelope
     * flattened to JSON. Subscribers in Lua (CLI scheduler or the studio,
     * which already calls bus.attach_main) pick it up identically. */
    stcur cur = { payload, payload + payload_n };
    size_t fields;
    cJSON *o = cJSON_CreateObject();
    if (rd_map_header(&cur, &fields)) {
      for (size_t i = 0; i < fields; i++) {
        const char *k; size_t kn;
        if (!rd_str(&cur, &k, &kn)) break;
        char key[64];
        snprintf(key, sizeof key, "%.*s", (int)(kn < 63 ? kn : 63), k);
        const char *v; size_t vn;
        stcur save = cur;
        if (rd_str(&cur, &v, &vn)) {
          cJSON_AddItemToObject(o, key, cJSON_CreateString(""));
          /* replace with a bounded copy (cJSON needs a NUL-terminated str) */
          char *vs = (char *)malloc(vn + 1);
          if (vs) {
            memcpy(vs, v, vn); vs[vn] = 0;
            cJSON_ReplaceItemInObject(o, key, cJSON_CreateString(vs));
            free(vs);
          }
        } else if (kn == 7 && memcmp(k, "payload", 7) == 0) {
          size_t pairs;
          if (!rd_map_header(&cur, &pairs)) break;
          for (size_t j = 0; j < pairs; j++) {
            const char *pk; size_t pkn, pvn; const char *pv;
            if (!rd_str(&cur, &pk, &pkn)) { j = pairs; break; }
            stcur ps = cur;
            if (rd_str(&cur, &pv, &pvn)) {
              char pkey[64];
              snprintf(pkey, sizeof pkey, "%.*s", (int)(pkn < 63 ? pkn : 63), pk);
              char *pvs = (char *)malloc(pvn + 1);
              if (pvs) {
                memcpy(pvs, pv, pvn); pvs[pvn] = 0;
                cJSON_AddItemToObject(o, pkey, cJSON_CreateString(pvs));
                free(pvs);
              }
            } else { cur = ps; if (!rd_skip(&cur, 0)) { j = pairs; } }
          }
        } else {
          cur = save;
          if (!rd_skip(&cur, 0)) break;
        }
      }
    }
    char topic[300];
    snprintf(topic, sizeof topic, "station.%s", frames[2]);
    char *json = cJSON_PrintUnformatted(o);
    if (json) { bus_emit(topic, json, strlen(json)); free(json); }
    cJSON_Delete(o);
    (void)L; (void)lens;
    return;
  }

  /* result / error / ack: match the corr id against a pending call. A corr
   * we no longer know is a stale reply from before a timeout or restart --
   * dropped, exactly as the client-side staleness rule requires.
   *
   * The cmd channel is two-phase: the daemon replies msg_type "ack"
   * IMMEDIATELY and posts the real tool_result later under the SAME corr id
   * (the work runs on a detached thread its side). An ack therefore marks
   * the call acked but leaves it pending -- completing on the ack would
   * throw the actual result away, which the first live test against a real
   * daemon demonstrated within the hour. */
  for (int i = 0; i < ST_MAX_PENDING; i++) {
    stcall *h = c->pending[i];
    if (h && !h->done && strcmp(h->corr, frames[2]) == 0) {
      stcur mc = { payload, payload + payload_n };
      size_t fields;
      int is_ack = 0;
      if (rd_map_header(&mc, &fields)) {
        for (size_t f = 0; f < fields; f++) {
          const char *k; size_t kn;
          if (!rd_str(&mc, &k, &kn)) break;
          if (kn == 8 && memcmp(k, "msg_type", 8) == 0) {
            const char *v; size_t vn;
            if (rd_str(&mc, &v, &vn) && vn == 3 && memcmp(v, "ack", 3) == 0)
              is_ack = 1;
            break;
          }
          if (!rd_skip(&mc, 0)) break;
        }
      }
      if (is_ack) { h->acked = 1; return; }
      snprintf(h->channel, sizeof h->channel, "%s", channel);
      h->reply = (char *)malloc(payload_n ? payload_n : 1);
      if (h->reply) { memcpy(h->reply, payload, payload_n); h->reply_n = payload_n; }
      else { h->err = "out of memory"; }
      h->done = 1;
      c->pending[i] = NULL;
      h->c = NULL;
      return;
    }
  }
}

/* Drain every message currently queued on the socket. Non-blocking; safe to
 * call any time. Returns the number of messages consumed. */
static int conn_drain(stconn *c, lua_State *L) {
  int consumed = 0;
  if (!c->sock) return 0;
  for (;;) {
    char frames[4][256];
    size_t lens[4] = { 0, 0, 0, 0 };
    unsigned char *payload = NULL;
    size_t payload_n = 0;
    int nframe = 0, more = 1, ok = 1;

    while (more) {
      zmq_msg_t m;
      zmq_msg_init(&m);
      if (zmq_msg_recv(&m, c->sock, ZMQ_DONTWAIT) < 0) {
        zmq_msg_close(&m);
        if (nframe == 0) return consumed;      /* nothing queued */
        ok = 0;                                 /* torn message: drop */
        break;
      }
      size_t n = zmq_msg_size(&m);
      if (nframe < 3) {
        size_t cp = n < 255 ? n : 255;
        memcpy(frames[nframe], zmq_msg_data(&m), cp);
        frames[nframe][cp] = 0;
        lens[nframe] = n;
      } else if (nframe == 3) {
        payload = (unsigned char *)malloc(n ? n : 1);
        if (payload) { memcpy(payload, zmq_msg_data(&m), n); payload_n = n; }
      }
      more = zmq_msg_more(&m);
      zmq_msg_close(&m);
      nframe++;
      if (nframe > 8) { ok = 0; break; }        /* not our protocol; drop */
    }

    if (ok && nframe >= 4)
      route_message(c, frames, lens, payload ? payload : (unsigned char *)"",
                    payload_n, L);
    free(payload);
    consumed++;
  }
}

/* Block up to `ms` for socket readability, then drain. */
static void conn_poll(stconn *c, lua_State *L, int ms) {
  if (!c->sock) return;
  zmq_pollitem_t it = { c->sock, 0, ZMQ_POLLIN, 0 };
  zmq_poll(&it, 1, ms);
  conn_drain(c, L);
}

static int send_frames(stconn *c, const char *channel, const char *corr,
                       const char *payload, size_t payload_n) {
  if (!c->sock || c->dead) return -1;
  if (zmq_send(c->sock, "", 0, ZMQ_SNDMORE) < 0) return -1;
  if (zmq_send(c->sock, channel, strlen(channel), ZMQ_SNDMORE) < 0) return -1;
  if (zmq_send(c->sock, corr, strlen(corr), ZMQ_SNDMORE) < 0) return -1;
  if (zmq_send(c->sock, payload, payload_n, 0) < 0) return -1;
  return 0;
}

/* ---- Lua surface: connection ---------------------------------------------- */

static stconn *check_conn(lua_State *L) {
  stconn *c = (stconn *)luaL_checkudata(L, 1, API_TYPE_STATION);
  return c;
}

static int l_conn_close(lua_State *L) {
  stconn *c = (stconn *)luaL_checkudata(L, 1, API_TYPE_STATION);
  conn_close(c);
  return 0;
}

static uint64_t g_corr_seq = 0;

/* conn:request(channel, msg_type[, tool[, payload[, timeout_ms]]]) -> handle.
 * Fire the envelope and hand back a call handle; handle:wait() collects the
 * reply. "query" is the interactive channel; "cmd" acks now and results
 * later under the SAME corr id, so one handle serves both. */
static int l_conn_request(lua_State *L) {
  stconn *c = check_conn(L);
  const char *channel = luaL_checkstring(L, 2);
  luaL_checkstring(L, 3); /* msg_type; encoded below */
  int timeout = (int)luaL_optinteger(L, 6, ST_DEFAULT_TIMEOUT_MS);
  if (!c->sock || c->dead)
    return luaL_error(L, "station connection is closed");

  int slot = -1;
  for (int i = 0; i < ST_MAX_PENDING; i++)
    if (!c->pending[i]) { slot = i; break; }
  if (slot < 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "too many in-flight station calls");
    return 2;
  }

  envelope_encode(L, 3); /* msg_type @3, tool @4, payload @5 -> pushes bytes */
  size_t pn;
  const char *pb = lua_tolstring(L, -1, &pn);

  stcall *h = (stcall *)lua_newuserdatauv(L, sizeof(stcall), 1);
  memset(h, 0, sizeof(*h));
  h->c = c;
  snprintf(h->corr, sizeof h->corr, "bog-%d-%llu",
#ifdef _WIN32
           (int)GetCurrentProcessId(),
#else
           (int)getpid(),
#endif
           (unsigned long long)(++g_corr_seq));
  h->deadline = now_ms() + (uint64_t)(timeout > 0 ? timeout : ST_DEFAULT_TIMEOUT_MS);
  luaL_setmetatable(L, API_TYPE_STCALL);
  lua_pushvalue(L, 1);              /* pin the connection in the uservalue */
  lua_setiuservalue(L, -2, 1);

  if (send_frames(c, channel, h->corr, pb, pn) != 0) {
    h->err = "station send failed (daemon gone?)";
    h->done = 1;
    return 1;
  }
  c->pending[slot] = h;
  return 1;
}

/* conn:subscribe(topic) / conn:unsubscribe(topic). Fire-and-forget; events
 * arrive on the bus as "station.<topic>" whenever the socket is drained
 * (any wait, or conn:pump). Re-issue after a daemon restart -- its
 * subscription table was RAM. */
static int sub_common(lua_State *L, const char *channel) {
  stconn *c = check_conn(L);
  const char *topic = luaL_checkstring(L, 2);
  if (!c->sock || c->dead)
    return luaL_error(L, "station connection is closed");
  lua_settop(L, 2);
  lua_pushstring(L, channel);       /* msg_type mirrors the channel name */
  lua_pushliteral(L, "");
  lua_newtable(L);
  lua_pushstring(L, topic);
  lua_setfield(L, -2, "topic");
  envelope_encode(L, 3);
  size_t pn;
  const char *pb = lua_tolstring(L, -1, &pn);
  char corr[48];
  snprintf(corr, sizeof corr, "bog-sub-%llu", (unsigned long long)(++g_corr_seq));
  if (send_frames(c, channel, corr, pb, pn) != 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "station send failed");
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int l_conn_subscribe(lua_State *L) { return sub_common(L, "sub"); }
static int l_conn_unsubscribe(lua_State *L) { return sub_common(L, "unsub"); }

/* conn:pump([ms]) -> messages consumed. Drives event delivery when no call
 * is outstanding; a UI calls this from its frame loop or a timer. */
static int l_conn_pump(lua_State *L) {
  stconn *c = check_conn(L);
  int ms = (int)luaL_optinteger(L, 2, 0);
  if (!c->sock) { lua_pushinteger(L, 0); return 1; }
  if (ms > 0) conn_poll(c, L, ms);
  lua_pushinteger(L, conn_drain(c, L));
  return 1;
}

/* ---- Lua surface: call handle --------------------------------------------- */

#define HANDLE_IDX 1

static int call_push(lua_State *L, stcall *h) {
  if (h->err) { lua_pushnil(L); lua_pushstring(L, h->err); return 2; }
  int n = envelope_decode(L, (const unsigned char *)(h->reply ? h->reply : ""),
                          h->reply_n);
  if (n == 2) return 2;  /* nil, decode error */
  /* (msg_type, tool, payload) -> return payload, msg_type, channel; the
   * error channel and the two error keys are data for Lua to rule on. */
  lua_pushvalue(L, -1);            /* payload */
  lua_pushvalue(L, -4);            /* msg_type */
  lua_pushstring(L, h->channel[0] ? h->channel : "result");
  return 3;
}

static void call_check_deadline(stcall *h) {
  if (!h->done && now_ms() > h->deadline) {
    h->err = "station call timed out";
    h->done = 1;
    if (h->c) {
      for (int i = 0; i < ST_MAX_PENDING; i++)
        if (h->c->pending[i] == h) h->c->pending[i] = NULL;
      h->c = NULL;
    }
  }
}

static int call_wait(lua_State *L);

static int call_cont(lua_State *L, int status, lua_KContext ctx) {
  (void)status; (void)ctx;
  lua_settop(L, HANDLE_IDX);
  return call_wait(L);
}

/* Wait for the reply: yields ("io", handle) under the scheduler, polls in
 * slices otherwise -- exactly lmcp.c's shape, so the studio's frame loop and
 * the swarm scheduler both keep breathing while a call is in flight. */
static int call_wait(lua_State *L) {
  stcall *h = (stcall *)luaL_checkudata(L, HANDLE_IDX, API_TYPE_STCALL);
  for (;;) {
    if (h->done) return call_push(L, h);
    if (h->c) conn_poll(h->c, L, lua_isyieldable(L) ? ST_YIELD_MS : ST_SLICE_MS);
    call_check_deadline(h);
    if (h->done) return call_push(L, h);
    if (lua_isyieldable(L)) {
      lua_pushliteral(L, "io");
      lua_pushvalue(L, HANDLE_IDX);
      return lua_yieldk(L, 2, 0, call_cont);
    }
  }
}

static int l_call_wait(lua_State *L) {
  lua_settop(L, HANDLE_IDX);
  return call_wait(L);
}

static int l_call_done(lua_State *L) {
  stcall *h = (stcall *)luaL_checkudata(L, 1, API_TYPE_STCALL);
  if (h->c) conn_drain(h->c, L);
  call_check_deadline(h);
  lua_pushboolean(L, h->done);
  return 1;
}

/* h:cancel() -- give up on the call. Locally the handle fails immediately
 * ("cancelled") and its corr id is forgotten, so a late reply is dropped as
 * stale; a best-effort `cancel` query also tells the daemon to drop the
 * result instead of routing it. Idempotent. */
static int l_call_cancel(lua_State *L) {
  stcall *h = (stcall *)luaL_checkudata(L, 1, API_TYPE_STCALL);
  if (h->done) { lua_pushboolean(L, 1); return 1; }
  stconn *c = h->c;
  if (c) {
    for (int i = 0; i < ST_MAX_PENDING; i++)
      if (c->pending[i] == h) c->pending[i] = NULL;
    h->c = NULL;
    if (c->sock && !c->dead) {
      /* fixmap{msg_type:"cancel", tool:"", payload:{corr_id:<corr>}} */
      char env[128];
      size_t cn = strlen(h->corr);
      size_t n = 0;
      env[n++] = (char)0x83;
      env[n++] = (char)0xa8; memcpy(env + n, "msg_type", 8); n += 8;
      env[n++] = (char)0xa6; memcpy(env + n, "cancel", 6); n += 6;
      env[n++] = (char)0xa4; memcpy(env + n, "tool", 4); n += 4;
      env[n++] = (char)0xa0;
      env[n++] = (char)0xa7; memcpy(env + n, "payload", 7); n += 7;
      env[n++] = (char)0x81;
      env[n++] = (char)0xa7; memcpy(env + n, "corr_id", 7); n += 7;
      env[n++] = (char)(0xa0 | (cn < 32 ? cn : 31));
      memcpy(env + n, h->corr, cn < 32 ? cn : 31); n += (cn < 32 ? cn : 31);
      char corr[48];
      snprintf(corr, sizeof corr, "bog-cancel-%llu",
               (unsigned long long)(++g_corr_seq));
      send_frames(c, "query", corr, env, n);
    }
  }
  h->err = "cancelled";
  h->done = 1;
  lua_pushboolean(L, 1);
  return 1;
}

static int l_call_gc(lua_State *L) {
  stcall *h = (stcall *)luaL_checkudata(L, 1, API_TYPE_STCALL);
  if (h->c) {
    for (int i = 0; i < ST_MAX_PENDING; i++)
      if (h->c->pending[i] == h) h->c->pending[i] = NULL;
    h->c = NULL;
  }
  free(h->reply);
  h->reply = NULL;
  return 0;
}

/* ---- connect --------------------------------------------------------------- */

/* station.connect([workspace]) -> conn | nil, err. Resolves the workspace's
 * port and connects a DEALER. zmq connects lazily, so success here means
 * "socket aimed", not "daemon alive" -- ping it (query/ping) to find out. */
static int l_connect(lua_State *L) {
  const char *ws = luaL_optstring(L, 1, ".");
  const char *err = NULL;
  int port = st_lookup_port(ws, &err);
  if (port <= 0) {
    lua_pushnil(L);
    lua_pushstring(L, err ? err : "no station for workspace");
    return 2;
  }

  zctxbox *box = get_ctx(L);
  if (!box->ctx) { lua_pushnil(L); lua_pushliteral(L, "zmq context failed"); return 2; }
  int slot = -1;
  for (int i = 0; i < ST_MAX_CONNS; i++)
    if (!box->conns[i]) { slot = i; break; }
  if (slot < 0) { lua_pushnil(L); lua_pushliteral(L, "too many station connections"); return 2; }

  stconn *c = (stconn *)lua_newuserdatauv(L, sizeof(stconn), 0);
  memset(c, 0, sizeof(*c));
  luaL_setmetatable(L, API_TYPE_STATION);

  c->sock = zmq_socket(box->ctx, ZMQ_DEALER);
  if (!c->sock) {
    c->dead = 1;
    lua_pushnil(L); lua_pushliteral(L, "zmq socket failed");
    return 2;
  }
  char rid[64];
  snprintf(rid, sizeof rid, "boggart-%d-%llu",
#ifdef _WIN32
           (int)GetCurrentProcessId(),
#else
           (int)getpid(),
#endif
           (unsigned long long)(++g_corr_seq));
  int zero = 0, sndtimeo = 5000;
  zmq_setsockopt(c->sock, ZMQ_ROUTING_ID, rid, strlen(rid));
  zmq_setsockopt(c->sock, ZMQ_LINGER, &zero, sizeof zero);
  zmq_setsockopt(c->sock, ZMQ_SNDTIMEO, &sndtimeo, sizeof sndtimeo);
  snprintf(c->endpoint, sizeof c->endpoint, "tcp://127.0.0.1:%d", port);
  if (zmq_connect(c->sock, c->endpoint) != 0) {
    conn_close(c);
    lua_pushnil(L); lua_pushliteral(L, "zmq connect failed");
    return 2;
  }
  c->box = box;
  box->conns[slot] = c;
  return 1;
}

static int l_conn_endpoint_of(lua_State *L) {
  stconn *c = check_conn(L);
  lua_pushstring(L, c->endpoint);
  return 1;
}

#else /* !BOGGART_STATION ---------------------------------------------------- */

static int l_connect(lua_State *L) {
  lua_pushnil(L);
  lua_pushliteral(L,
    "station support not built (configure with -DBOGGART_STATION=ON)");
  return 2;
}

#endif /* BOGGART_STATION */

/* ---- registration ---------------------------------------------------------- */

static const luaL_Reg station_lib[] = {
  { "built", l_built },
  { "available", l_available },
  { "endpoint", l_endpoint },
  { "connect", l_connect },
  { "_encode", l_encode },
  { "_decode", l_decode },
  { NULL, NULL }
};

int luaopen_boggart_station(lua_State *L) {
#ifdef BOGGART_STATION
  luaL_newmetatable(L, API_TYPE_STATION);
  lua_newtable(L);
  lua_pushcfunction(L, l_conn_request);     lua_setfield(L, -2, "request");
  lua_pushcfunction(L, l_conn_subscribe);   lua_setfield(L, -2, "subscribe");
  lua_pushcfunction(L, l_conn_unsubscribe); lua_setfield(L, -2, "unsubscribe");
  lua_pushcfunction(L, l_conn_pump);        lua_setfield(L, -2, "pump");
  lua_pushcfunction(L, l_conn_endpoint_of); lua_setfield(L, -2, "endpoint");
  lua_pushcfunction(L, l_conn_close);       lua_setfield(L, -2, "close");
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, l_conn_close);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_STCALL);
  lua_newtable(L);
  lua_pushcfunction(L, l_call_wait);   lua_setfield(L, -2, "wait");
  lua_pushcfunction(L, l_call_done);   lua_setfield(L, -2, "done");
  lua_pushcfunction(L, l_call_cancel); lua_setfield(L, -2, "cancel");
  lua_pushcfunction(L, l_call_gc);     lua_setfield(L, -2, "close");
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, l_call_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
#endif
  luaL_newlib(L, station_lib);
  return 1;
}
