/* lmcp.c -- MCP (Model Context Protocol) client, in C, on libuv.
 *
 * The client lives here; a thin Lua layer (lua/mcphost.lua) drives it and
 * registers discovered tools into the normal tool registry. Two transports:
 *   - stdio: launch the server as a subprocess (uv_spawn) and exchange
 *     newline-delimited JSON-RPC over uv_pipe_t stdin/stdout, kept alive across
 *     calls. No fork/exec/poll/waitpid: libuv covers POSIX and Windows, and it
 *     does the Windows command-line quoting for us.
 *   - Streamable HTTP: JSON-RPC over HTTP POST via libcurl (response may be
 *     application/json or an SSE stream), with Mcp-Session-Id + protocol header.
 * Uses vendored cJSON to build/parse messages. Responses are correlated by
 * JSON-RPC id, buffering out-of-order responses so concurrent in-flight calls
 * over one connection stay correct.
 *
 * Two protocol generations, negotiated per connection rather than configured:
 *   - legacy (2025-11-25 and earlier): an `initialize` + `notifications/
 *     initialized` handshake states the version once, and the connection (an
 *     Mcp-Session-Id on HTTP) carries that state afterwards;
 *   - modern (2026-07-28): no handshake at all. The protocol is stateless, so
 *     every request restates the version, the client's capabilities and its
 *     identity in params._meta, and on HTTP mirrors method and name into the
 *     required Mcp-Method / Mcp-Name headers. No session id exists.
 * connect() probes with `server/discover` -- which modern servers MUST
 * implement -- and falls back to the handshake on any answer that is neither a
 * modern result nor a modern error. See probe_discover() for why the fallback
 * cannot be keyed to a single error code.
 *
 * Reads are event-driven, never blocking: uv_read_start feeds a per-connection
 * buffer, complete lines are framed and parked on a pending-response list, and
 * a caller picks its response off that list by id. Nothing in a libuv callback
 * touches the Lua state.
 *
 * Waiting is therefore a policy, not a mechanic, and there are two:
 *   - inside a coroutine (swarm mode) `conn:call` yields ("io", handle) to the
 *     cooperative scheduler exactly like an async HTTP request does, so an MCP
 *     call in flight no longer freezes every other agent's LLM stream;
 *   - on the main thread it pumps the loop in short slices until the response
 *     arrives (same observable behaviour as before, finer granularity).
 *
 * Lua surface (the sync half is unchanged):
 *   mcp.connect{transport=, command=, args=, env=, url=, headers=} -> conn | nil,err
 *   mcp.pump(ms)                       -> advance all MCP connections once
 *   conn:tools()               -> tools_json_string | nil,err   (tools/list)
 *   conn:call(name, args_json) -> result_json_string | nil,err  (tools/call)
 *   conn:begin(name, args_json)-> handle                        (async tools/call)
 *     handle:status()          -> "running" | "done", result | "error", msg
 *     handle:take()            -> result_json_string ("" until done)
 *     handle:close()
 *   conn:info()                -> json: {era, protocol, transport, serverInfo?,
 *                                       capabilities?, instructions?}
 *   conn:close()
 */
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <curl/curl.h>
#include "uv.h"

#include "cJSON.h"
#include "lua.h"
#include "lauxlib.h"

#define API_TYPE_MCP "boggart.mcp"
#define API_TYPE_CALL "boggart.mcpcall"
#define MCP_PROTO_LEGACY "2025-11-25" /* newest handshake-based revision */
#define MCP_PROTO_MODERN "2026-07-28" /* newest stateless revision */
#define MCP_TIMEOUT 60 /* seconds per request */
/* The version probe gets its own, much shorter deadline: a legacy server is
 * allowed to answer an unknown pre-initialize method with nothing at all, and
 * silence is one of the three outcomes the probe has to distinguish. 10s is
 * long enough for a server that is slow to start reading stdin (npx spawning
 * node, say) and short enough that a mute one does not stall connect for a
 * minute before the handshake it was always going to need. */
#define MCP_PROBE_TIMEOUT 10
#define MCP_SLICE_MS 50 /* blocking-wait slice (main thread) */
#define MCP_YIELD_MS 2  /* loop wait before yielding to the scheduler */
#define MCP_MAX_PENDING 128 /* cap on undelivered responses per connection */

/* The reserved _meta keys the modern revision carries on every message. */
#define META_PROTOCOL "io.modelcontextprotocol/protocolVersion"
#define META_CLIENT_INFO "io.modelcontextprotocol/clientInfo"
#define META_CLIENT_CAPS "io.modelcontextprotocol/clientCapabilities"
#define META_SERVER_INFO "io.modelcontextprotocol/serverInfo"

/* MCP error codes this client reasons about. -32020/-32021/-32022 come from
 * the range the spec reserves for itself, so receiving any of them is proof
 * the peer speaks a modern revision even when the request failed. */
#define MCP_E_HEADER_MISMATCH -32020
#define MCP_E_MISSING_CAP -32021
#define MCP_E_BAD_VERSION -32022

enum { T_STDIO, T_HTTP };
enum { ERA_LEGACY, ERA_MODERN };

/* Modern revisions this client speaks, newest first. Version strings are ISO
 * dates, so "newest" is just their descending order. */
static const char *MODERN_VERSIONS[] = { MCP_PROTO_MODERN };
#define N_MODERN_VERSIONS ((int)(sizeof(MODERN_VERSIONS) / sizeof(MODERN_VERSIONS[0])))

/* Transient error text handed to Lua; copied by lua_pushstring immediately.
 * Two buffers alternately, so wrapping one message inside another
 * (seterr("...: %s", previous_seterr_result)) never copies onto itself. */
static char g_err[2][512];
static int g_err_slot = 0;
static const char *seterr(const char *fmt, ...) {
  va_list ap;
  g_err_slot ^= 1;
  va_start(ap, fmt);
  vsnprintf(g_err[g_err_slot], sizeof(g_err[0]), fmt, ap);
  va_end(ap);
  return g_err[g_err_slot];
}

/* ---- the event loop -------------------------------------------------------
 * boggart has exactly one uv loop: the one luv creates for this lua_State.
 *
 * This module used to run a private loop, on the reasoning that running the
 * *default* loop here would advance handles owned by other modules at
 * arbitrary points. That was right about uv_default_loop() and wrong about the
 * conclusion. With separate loops, blocking in one starves every other -- an
 * MCP call would stop advancing subprocesses and timers, which is precisely
 * the class of stall this port removed from MCP itself. One shared loop means
 * a single uv.run("nowait") from lua/sched.lua drives everything.
 *
 * Advancing another module's handles is not a hazard here: no uv callback in
 * boggart re-enters Lua (they only mutate C state that Lua reads afterwards),
 * so there is no reentrancy to protect against.
 */

/* From luv.h. Declared rather than included so luv's headers stay off this
 * target's include path -- it is the only symbol we need. */
extern uv_loop_t *luv_loop(lua_State *L);

static uv_loop_t *g_loop = NULL;
static uv_timer_t g_wake;

static int loop_ensure(lua_State *L) {
  if (g_loop) return 0;
  /* luv is registered as package.preload["uv"] (see src/boggart.c) and the
   * loop is created inside luaopen_luv, so it must be instantiated before
   * luv_loop() has anything to hand back. */
  lua_getglobal(L, "require");
  lua_pushliteral(L, "uv");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) { lua_pop(L, 1); return -1; }
  lua_pop(L, 1);

  uv_loop_t *loop = luv_loop(L);
  if (!loop) return -1;
  if (uv_timer_init(loop, &g_wake) != 0) return -1;
  g_loop = loop;
  return 0;
}

static uint64_t now_ms(void) { return uv_hrtime() / 1000000ull; }

static void wake_cb(uv_timer_t *t) { (void)t; } /* only there to bound the wait */

static void reap_dead(void); /* frees connections whose handles have all closed */

/* Advance every MCP connection once. wait_ms > 0 blocks at most that long,
 * returning as soon as anything happens; 0 is a pure non-blocking poll. */
static void mcp_pump(int wait_ms) {
  if (g_loop) {
    if (wait_ms > 0) {
      uv_timer_start(&g_wake, wake_cb, (uint64_t)wait_ms, 0);
      uv_run(g_loop, UV_RUN_ONCE);
      uv_timer_stop(&g_wake);
    } else {
      uv_run(g_loop, UV_RUN_NOWAIT);
    }
  }
  reap_dead();
}

/* ---- connection state ----------------------------------------------------- */
typedef struct pending {
  int id;
  cJSON *msg; /* owned */
  struct pending *next;
} pending;

/* The half of a connection libuv can still reference after the Lua userdata is
 * gone: heap-allocated and refcounted (one ref per live handle / in-flight
 * write, plus one for the owning userdata), freed by the last release. */
typedef struct mcpio {
  int refs;
  uv_process_t proc;
  uv_pipe_t cin;  /* child stdin  -- we write */
  uv_pipe_t cout; /* child stdout -- we read  */
  int have_proc;    /* the process handle is registered with the loop */
  int proc_spawned; /* ...and a child actually exists behind it */
  int have_in, have_out;
  int proc_exited;
  int64_t exit_status;
  int eof;    /* child stdout closed */
  int io_err; /* first fatal read/write error (uv errno) */
  char *rbuf;
  size_t rlen, rcap;
  pending *pend;
  int npend;
  struct mcpio *dead_next; /* graveyard link, see io_release */
} mcpio;

typedef struct {
  int transport;
  int next_id;
  int dead;
  mcpio *io; /* both transports: owns the pending-response list */
  /* protocol generation, decided once at connect and constant afterwards */
  int era;            /* ERA_LEGACY | ERA_MODERN */
  char *proto;        /* the negotiated protocol version */
  char *server_info;  /* JSON: from initialize, or a modern result's _meta */
  char *caps;         /* JSON: the server's capabilities, as it stated them */
  char *instructions; /* server usage notes, if it offered any */
  /* http */
  char *url;
  struct curl_slist *user_headers;
  char *session; /* Mcp-Session-Id -- legacy only: modern MCP has no session */
} mcpconn;

/* An in-flight (or finished) request. Mirrors the httpreq handle in lhttp.c so
 * the scheduler's coroutine.yield("io", req) protocol works unchanged. */
typedef struct {
  mcpconn *c;  /* borrowed; pinned by uservalue 1 */
  int id;
  int done;
  int want_tools; /* unwrap result.tools (tools/list) */
  int want_raw;   /* keep the whole JSON-RPC response (connect probe) */
  uint64_t deadline; /* now_ms() value, 0 = none */
  char *out; /* result JSON (owned) */
  char *err; /* error text (owned) */
} mcpcall;

/* The uv handles live *inside* mcpio, and libuv keeps walking its closing /
 * endgame list after invoking a close callback -- so a struct whose last
 * reference drops inside one close callback must not be freed until the loop
 * has finished the iteration. Park it here; mcp_pump frees it once uv_run has
 * returned. */
static mcpio *g_dead = NULL;

static void io_release(mcpio *io) {
  if (!io) return;
  if (--io->refs > 0) return;
  io->dead_next = g_dead;
  g_dead = io;
}

static void reap_dead(void) {
  while (g_dead) {
    mcpio *io = g_dead;
    g_dead = io->dead_next;
    while (io->pend) { pending *p = io->pend; io->pend = p->next; cJSON_Delete(p->msg); free(p); }
    free(io->rbuf);
    free(io);
  }
}

static void on_close(uv_handle_t *h) { io_release((mcpio *)h->data); }

/* ---- small helpers -------------------------------------------------------- */
static cJSON *build_request(const char *method, int id, cJSON *params /*owned*/) {
  cJSON *o = cJSON_CreateObject();
  cJSON_AddStringToObject(o, "jsonrpc", "2.0");
  if (id >= 0) cJSON_AddNumberToObject(o, "id", id);
  cJSON_AddStringToObject(o, "method", method);
  if (params) cJSON_AddItemToObject(o, "params", params);
  return o;
}

static int is_response(cJSON *m) {
  return cJSON_GetObjectItem(m, "result") != NULL || cJSON_GetObjectItem(m, "error") != NULL;
}

static cJSON *client_info(void) {
  cJSON *ci = cJSON_CreateObject();
  cJSON_AddStringToObject(ci, "name", "boggart");
  cJSON_AddStringToObject(ci, "version", "0.1.0");
  return ci;
}

/* Client capabilities, in both generations: deliberately empty.
 *
 * boggart implements no roots, no sampling and no elicitation, and saying so
 * is load-bearing rather than merely honest. A modern server MUST NOT ask for
 * a capability the client did not declare -- it has to fail the request with
 * MissingRequiredClientCapability instead -- so an empty object is what keeps
 * a server from handing us an input request we have no way to satisfy. */
static cJSON *client_caps(void) { return cJSON_CreateObject(); }

/* Attach the per-request metadata a modern request must carry.
 *
 * There is no handshake to state the version, the capabilities or the client's
 * identity once, so every request restates them. This is called from the one
 * place every outgoing request passes through (start_call), because "every
 * request" is a property that a new call site would otherwise be free to
 * forget: a request missing _meta is malformed and the server MUST reject it. */
static cJSON *with_meta(mcpconn *c, cJSON *params) {
  if (!params) params = cJSON_CreateObject();
  cJSON *meta = cJSON_CreateObject();
  cJSON_AddStringToObject(meta, META_PROTOCOL, c->proto ? c->proto : MCP_PROTO_MODERN);
  cJSON_AddItemToObject(meta, META_CLIENT_INFO, client_info());
  cJSON_AddItemToObject(meta, META_CLIENT_CAPS, client_caps());
  cJSON_DeleteItemFromObject(params, "_meta"); /* ours wins over any caller's */
  cJSON_AddItemToObject(params, "_meta", meta);
  return params;
}

static void set_str(char **slot, const char *v) {
  free(*slot);
  *slot = v ? strdup(v) : NULL;
}

/* Remember whatever a result told us about the server, in either generation.
 * Modern servers put serverInfo in the result's _meta rather than in a
 * handshake, so this runs on ordinary results too, not only at connect. */
static void capture_server_info(mcpconn *c, cJSON *result) {
  if (!result) return;
  cJSON *meta = cJSON_GetObjectItem(result, "_meta");
  cJSON *si = meta ? cJSON_GetObjectItem(meta, META_SERVER_INFO) : NULL;
  if (!si) si = cJSON_GetObjectItem(result, "serverInfo"); /* legacy handshake */
  if (si && !c->server_info) c->server_info = cJSON_PrintUnformatted(si);
  cJSON *caps = cJSON_GetObjectItem(result, "capabilities");
  if (caps && !c->caps) c->caps = cJSON_PrintUnformatted(caps);
  cJSON *ins = cJSON_GetObjectItem(result, "instructions");
  if (cJSON_IsString(ins) && !c->instructions) set_str(&c->instructions, ins->valuestring);
}

static void push_pending(mcpio *io, int id, cJSON *msg /*owned*/) {
  pending *p = malloc(sizeof(pending));
  if (!p) { cJSON_Delete(msg); return; }
  p->id = id; p->msg = msg; p->next = io->pend;
  io->pend = p; io->npend++;
  /* Responses whose waiter timed out would otherwise accumulate forever; drop
   * the oldest once the list is implausibly long. */
  while (io->npend > MCP_MAX_PENDING) {
    pending **pp = &io->pend;
    while ((*pp)->next) pp = &(*pp)->next;
    pending *old = *pp; *pp = NULL;
    cJSON_Delete(old->msg); free(old); io->npend--;
  }
}

static cJSON *take_pending(mcpio *io, int id) {
  if (!io) return NULL;
  for (pending **pp = &io->pend; *pp; pp = &(*pp)->next) {
    if ((*pp)->id == id) {
      pending *p = *pp; *pp = p->next;
      cJSON *m = p->msg; free(p); io->npend--;
      return m;
    }
  }
  return NULL;
}

/* ---- stdio transport: libuv callbacks (never touch Lua) ------------------- */
/* Frame complete newline-delimited messages out of the read buffer and park
 * every response on the pending list. Called from the read callback, so a
 * connection drains itself whenever the loop runs -- no Lua involvement. */
static void io_drain(mcpio *io) {
  for (;;) {
    char *nl = io->rbuf ? memchr(io->rbuf, '\n', io->rlen) : NULL;
    if (!nl) return;
    size_t linelen = (size_t)(nl - io->rbuf);
    cJSON *msg = cJSON_ParseWithLength(io->rbuf, linelen);
    size_t consumed = linelen + 1;
    memmove(io->rbuf, io->rbuf + consumed, io->rlen - consumed);
    io->rlen -= consumed;
    if (!msg) continue; /* skip an unparseable line */
    cJSON *idf = cJSON_GetObjectItem(msg, "id");
    if (is_response(msg) && cJSON_IsNumber(idf)) push_pending(io, idf->valueint, msg);
    else cJSON_Delete(msg); /* server notification/request: ignored in v1 */
  }
}

static void io_alloc(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  mcpio *io = (mcpio *)h->data;
  const size_t want = 65536;
  (void)suggested;
  if (io->rcap - io->rlen < want) {
    size_t ncap = io->rcap ? io->rcap * 2 : want;
    while (ncap - io->rlen < want) ncap *= 2;
    char *nb = realloc(io->rbuf, ncap);
    if (!nb) { *buf = uv_buf_init(NULL, 0); return; } /* -> UV_ENOBUFS */
    io->rbuf = nb; io->rcap = ncap;
  }
  *buf = uv_buf_init(io->rbuf + io->rlen, (unsigned int)(io->rcap - io->rlen));
}

static void io_read(uv_stream_t *s, ssize_t nread, const uv_buf_t *buf) {
  mcpio *io = (mcpio *)s->data;
  (void)buf;
  if (nread > 0) { io->rlen += (size_t)nread; io_drain(io); return; }
  if (nread == 0) return; /* nothing available yet */
  io->eof = 1; /* UV_EOF: the server exited */
  if (nread != UV_EOF && !io->io_err) io->io_err = (int)nread;
  uv_read_stop(s);
}

/* NOT on_exit(): glibc declares an on_exit() in <stdlib.h>, so a static
 * function of that name is a conflicting declaration and fails to compile on
 * Linux. macOS has no such function, which is why this only showed up in CI. */
static void on_proc_exit(uv_process_t *p, int64_t exit_status, int term_signal) {
  mcpio *io = (mcpio *)p->data;
  (void)term_signal;
  io->proc_exited = 1;
  io->exit_status = exit_status;
}

typedef struct { uv_write_t req; char *data; mcpio *io; } wreq;

static void on_write(uv_write_t *req, int status) {
  wreq *w = (wreq *)req; /* uv_write_t is the first member */
  mcpio *io = w->io;
  if (status < 0 && io && !io->io_err) io->io_err = status;
  free(w->data);
  free(w);
  io_release(io);
}

/* Queue one JSON-RPC frame on the child's stdin. Never blocks: libuv buffers
 * whatever the pipe cannot take right now. */
static int stdio_send(mcpconn *c, cJSON *req /*borrowed*/) {
  mcpio *io = c->io;
  char *s = cJSON_PrintUnformatted(req);
  if (!s) return -1;
  size_t sl = strlen(s);
  char *line = realloc(s, sl + 2);
  if (!line) { free(s); return -1; }
  line[sl] = '\n'; line[sl + 1] = 0;
  if (!io || !io->have_in || uv_is_closing((uv_handle_t *)&io->cin)) { free(line); return -1; }
  wreq *w = malloc(sizeof(wreq));
  if (!w) { free(line); return -1; }
  w->data = line; w->io = io;
  uv_buf_t b = uv_buf_init(line, (unsigned int)(sl + 1));
  io->refs++;
  if (uv_write(&w->req, (uv_stream_t *)&io->cin, &b, 1, on_write) != 0) {
    io->refs--; free(line); free(w);
    return -1;
  }
  return 0;
}

/* ---- HTTP transport ------------------------------------------------------- */
typedef struct { char *buf; size_t len, cap; } growbuf;

static size_t gb_write(char *ptr, size_t sz, size_t nm, void *ud) {
  growbuf *g = ud; size_t n = sz * nm;
  if (g->len + n + 1 > g->cap) {
    size_t nc = g->cap ? g->cap * 2 : 8192;
    while (nc < g->len + n + 1) nc *= 2;
    char *nb = realloc(g->buf, nc); if (!nb) return 0;
    g->buf = nb; g->cap = nc;
  }
  memcpy(g->buf + g->len, ptr, n); g->len += n; g->buf[g->len] = 0;
  return n;
}

static size_t hdr_cb(char *ptr, size_t sz, size_t nm, void *ud) {
  mcpconn *c = ud; size_t n = sz * nm;
  const char *key = "mcp-session-id:";
  /* Sessions were removed in 2026-07-28. A dual-era server may still emit the
   * header out of habit; storing it would only get it echoed back on requests
   * that are supposed to be stateless. */
  if (c->era == ERA_MODERN) return n;
  size_t klen = strlen(key);
  if (n >= klen) {
    /* case-insensitive prefix match */
    int match = 1;
    for (size_t i = 0; i < klen; i++) {
      char a = ptr[i]; if (a >= 'A' && a <= 'Z') a += 32;
      if (a != key[i]) { match = 0; break; }
    }
    if (match) {
      const char *v = ptr + klen; size_t vlen = n - klen;
      while (vlen && (*v == ' ' || *v == '\t')) { v++; vlen--; }
      while (vlen && (v[vlen - 1] == '\r' || v[vlen - 1] == '\n' || v[vlen - 1] == ' ')) vlen--;
      free(c->session);
      c->session = malloc(vlen + 1);
      memcpy(c->session, v, vlen); c->session[vlen] = 0;
    }
  }
  return n;
}

/* ---- modern HTTP request metadata -----------------------------------------
 * 2026-07-28 mirrors two body fields into headers so that load balancers and
 * gateways can route without parsing the body: Mcp-Method (the method) and
 * Mcp-Name (params.name, or params.uri for resources/read). Both are REQUIRED,
 * and the server MUST reject a request whose header and body disagree.
 *
 * Not implemented: the x-mcp-header extension, which lets a server nominate
 * tool *parameters* to be mirrored into Mcp-Param-<Name> headers. Clients MUST
 * support it, and boggart does not: the annotation lives in the tool's
 * inputSchema, which the Lua registration layer holds and never hands to this
 * C client, so the client cannot see which arguments to mirror. Servers that
 * use it will answer HeaderMismatch (-32020), which surfaces as a plain tool
 * error rather than as silent misrouting. */
static const char *B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/* HTTP field values are visible ASCII with no leading or trailing space.
 * Anything else -- and anything that would be mistaken for the sentinel below
 * -- has to travel Base64-encoded. */
static int header_safe(const char *s) {
  size_t n = strlen(s);
  if (n == 0) return 1;
  if (s[0] == ' ' || s[0] == '\t' || s[n - 1] == ' ' || s[n - 1] == '\t') return 0;
  if (n >= 11 && strncmp(s, "=?base64?", 9) == 0 && strcmp(s + n - 2, "?=") == 0) return 0;
  for (size_t i = 0; i < n; i++) {
    unsigned char ch = (unsigned char)s[i];
    if (ch < 0x20 || ch > 0x7e) return 0;
  }
  return 1;
}

/* The header value for a name, encoded as =?base64?...?= when it cannot be
 * carried literally. Caller frees. */
static char *header_value(const char *s) {
  if (header_safe(s)) return strdup(s);
  size_t n = strlen(s);
  size_t enc = ((n + 2) / 3) * 4;
  char *out = malloc(9 + enc + 2 + 1);
  if (!out) return NULL;
  memcpy(out, "=?base64?", 9);
  char *p = out + 9;
  for (size_t i = 0; i < n; i += 3) {
    unsigned v = (unsigned char)s[i] << 16;
    if (i + 1 < n) v |= (unsigned char)s[i + 1] << 8;
    if (i + 2 < n) v |= (unsigned char)s[i + 2];
    *p++ = B64[(v >> 18) & 63];
    *p++ = B64[(v >> 12) & 63];
    *p++ = (i + 1 < n) ? B64[(v >> 6) & 63] : '=';
    *p++ = (i + 2 < n) ? B64[v & 63] : '=';
  }
  memcpy(p, "?=", 3);
  return out;
}

/* The value Mcp-Name must carry for this request, or NULL when the method has
 * no name to mirror. */
static const char *mcp_name_of(cJSON *params) {
  if (!params) return NULL;
  cJSON *n = cJSON_GetObjectItem(params, "name");
  if (cJSON_IsString(n)) return n->valuestring;
  cJSON *u = cJSON_GetObjectItem(params, "uri");
  if (cJSON_IsString(u)) return u->valuestring;
  return NULL;
}

static struct curl_slist *append_hdr(struct curl_slist *h, const char *key, const char *val) {
  size_t n = strlen(key) + strlen(val) + 4;
  char *s = malloc(n);
  if (!s) return h;
  snprintf(s, n, "%s: %s", key, val);
  h = curl_slist_append(h, s);
  free(s);
  return h;
}

/* Parse a JSON-RPC message out of an HTTP body that is either a bare JSON
 * object or an SSE stream (find the data: line whose object is a response). */
static cJSON *parse_http_body(const char *body, int id) {
  cJSON *whole = cJSON_Parse(body);
  if (whole && is_response(whole)) return whole;
  if (whole) cJSON_Delete(whole);
  /* SSE: scan data: lines */
  const char *p = body;
  cJSON *found = NULL;
  while (p && *p) {
    const char *nl = strchr(p, '\n');
    size_t linelen = nl ? (size_t)(nl - p) : strlen(p);
    if (linelen >= 6 && strncmp(p, "data: ", 6) == 0) {
      cJSON *m = cJSON_ParseWithLength(p + 6, linelen - 6);
      if (m && is_response(m)) {
        cJSON *idf = cJSON_GetObjectItem(m, "id");
        if (cJSON_IsNumber(idf) && idf->valueint == id) { found = m; break; }
      }
      if (m) cJSON_Delete(m);
    }
    if (!nl) break;
    p = nl + 1;
  }
  return found;
}

static cJSON *http_transact(mcpconn *c, const char *method, int id, cJSON *params, const char **err) {
  /* Read the mirrored fields before build_request takes ownership of params. */
  char *name_hdr = NULL;
  if (c->era == ERA_MODERN) {
    const char *nm = mcp_name_of(params);
    if (nm) name_hdr = header_value(nm);
  }
  cJSON *req = build_request(method, id, params);
  char *body = cJSON_PrintUnformatted(req);
  cJSON_Delete(req);

  CURL *e = curl_easy_init();
  if (!e) { free(body); free(name_hdr); *err = "curl_easy_init failed"; return NULL; }
  struct curl_slist *h = NULL;
  h = curl_slist_append(h, "content-type: application/json");
  h = curl_slist_append(h, "accept: application/json, text/event-stream");
  /* Must match the version in the body's _meta, or a modern server answers
   * HeaderMismatch; legacy servers want the negotiated version here too. */
  h = append_hdr(h, "mcp-protocol-version", c->proto ? c->proto : MCP_PROTO_LEGACY);
  if (c->era == ERA_MODERN) {
    h = append_hdr(h, "mcp-method", method);
    if (name_hdr) h = append_hdr(h, "mcp-name", name_hdr);
  } else if (c->session) {
    h = append_hdr(h, "mcp-session-id", c->session);
  }
  free(name_hdr);
  for (struct curl_slist *u = c->user_headers; u; u = u->next) h = curl_slist_append(h, u->data);

  growbuf g = { 0 };
  curl_easy_setopt(e, CURLOPT_URL, c->url);
  curl_easy_setopt(e, CURLOPT_POST, 1L);
  curl_easy_setopt(e, CURLOPT_POSTFIELDS, body);
  curl_easy_setopt(e, CURLOPT_HTTPHEADER, h);
  curl_easy_setopt(e, CURLOPT_WRITEFUNCTION, gb_write);
  curl_easy_setopt(e, CURLOPT_WRITEDATA, &g);
  curl_easy_setopt(e, CURLOPT_HEADERFUNCTION, hdr_cb);
  curl_easy_setopt(e, CURLOPT_HEADERDATA, c);
  curl_easy_setopt(e, CURLOPT_TIMEOUT, (long)MCP_TIMEOUT);
  curl_easy_setopt(e, CURLOPT_NOSIGNAL, 1L);
  CURLcode rc = curl_easy_perform(e);
  long status = 0;
  curl_easy_getinfo(e, CURLINFO_RESPONSE_CODE, &status);
  curl_slist_free_all(h);
  curl_easy_cleanup(e);
  free(body);

  if (rc != CURLE_OK) { free(g.buf); *err = curl_easy_strerror(rc); return NULL; }
  if (status == 202 || g.len == 0) { free(g.buf); *err = "no JSON-RPC response in HTTP body"; return NULL; }
  cJSON *resp = g.buf ? parse_http_body(g.buf, id) : NULL;
  free(g.buf);
  if (!resp) { *err = "no JSON-RPC response in HTTP body"; return NULL; }
  return resp;
}

/* ---- request start / completion ------------------------------------------ */
/* Send a request and return its id (or -1 with *err). Takes ownership of
 * params. The HTTP transport is still synchronous: it completes here and parks
 * the response on the same pending list the stdio reader feeds. */
static int start_call(mcpconn *c, const char *method, cJSON *params, const char **err) {
  *err = NULL;
  if (c->dead || !c->io) {
    if (params) cJSON_Delete(params);
    *err = "connection is dead";
    return -1;
  }
  int id = c->next_id++;
  if (c->era == ERA_MODERN) params = with_meta(c, params);
  if (c->transport == T_STDIO) {
    cJSON *req = build_request(method, id, params);
    int rc = stdio_send(c, req);
    cJSON_Delete(req);
    if (rc != 0) { c->dead = 1; *err = "write to server failed"; return -1; }
    return id;
  }
  cJSON *resp = http_transact(c, method, id, params, err);
  if (!resp) return -1;
  push_pending(c->io, id, resp);
  return id;
}

/* Comma-joined array of strings, truncated to fit. For error text only. */
static void join_strings(cJSON *arr, char *buf, size_t n) {
  size_t used = 0;
  buf[0] = 0;
  cJSON *v;
  cJSON_ArrayForEach(v, arr) {
    if (!cJSON_IsString(v)) continue;
    int w = snprintf(buf + used, n - used, "%s%s", used ? ", " : "", v->valuestring);
    if (w < 0 || (size_t)w >= n - used) { used = n - 1; break; }
    used += (size_t)w;
  }
}

/* Human-readable text for a JSON-RPC error object. UnsupportedProtocolVersion
 * carries the versions the server does support, and that list is the whole
 * diagnosis, so it goes into the message rather than being dropped. */
static const char *rpc_error_text(cJSON *errobj) {
  cJSON *msg = cJSON_GetObjectItem(errobj, "message");
  cJSON *code = cJSON_GetObjectItem(errobj, "code");
  const char *m = cJSON_IsString(msg) ? msg->valuestring : "unknown";
  cJSON *data = cJSON_GetObjectItem(errobj, "data");
  cJSON *sup = data ? cJSON_GetObjectItem(data, "supported") : NULL;
  if (cJSON_IsNumber(code) && code->valueint == MCP_E_BAD_VERSION && cJSON_IsArray(sup)) {
    char list[256];
    join_strings(sup, list, sizeof(list));
    return seterr("mcp error: %s (server supports: %s)", m, list);
  }
  return seterr("mcp error: %s", m);
}

/* Whether a result may be handed to the caller as the answer, or the reason it
 * may not.
 *
 * 2026-07-28 made every result polymorphic: `resultType` says whether what came
 * back is the answer ("complete") or a request for more input from the client
 * ("input_required", the MRTR pattern -- the server wants an elicitation, a
 * sampling turn or the roots list before it can finish). An older server sends
 * no resultType at all, and clients MUST read that absence as "complete".
 *
 * The trap this exists to close: an input_required result still looks like a
 * plausible object, and passing it up as though it were the tool's output would
 * hand the model an interim protocol artefact and call it an answer.
 *
 * boggart does not implement MRTR. It declares no client capabilities, so a
 * conforming server has no legal input request to make of it, and the honest
 * response to one is a tool error naming what was asked for -- not silence, and
 * not a fabricated answer. */
static const char *bad_result_type(mcpconn *c, cJSON *result) {
  if (!result || c->era != ERA_MODERN) return NULL;
  cJSON *rt = cJSON_GetObjectItem(result, "resultType");
  if (!cJSON_IsString(rt)) return NULL; /* absent == complete */
  if (strcmp(rt->valuestring, "complete") == 0) return NULL;
  if (strcmp(rt->valuestring, "input_required") == 0) {
    char asked[256];
    size_t used = 0;
    asked[0] = 0;
    cJSON *reqs = cJSON_GetObjectItem(result, "inputRequests");
    cJSON *r;
    cJSON_ArrayForEach(r, reqs) {
      cJSON *m = cJSON_GetObjectItem(r, "method");
      if (!cJSON_IsString(m)) continue;
      int w = snprintf(asked + used, sizeof(asked) - used, "%s%s", used ? ", " : "", m->valuestring);
      if (w < 0 || (size_t)w >= sizeof(asked) - used) break;
      used += (size_t)w;
    }
    return seterr("mcp: the server asked for more input (%s) before it can answer; "
                  "boggart does not implement MRTR, so nothing was completed",
                  used ? asked : "no requests given");
  }
  /* An unrecognized resultType MUST be treated as invalid, not guessed at. */
  return seterr("mcp: unrecognized resultType '%s'", rt->valuestring);
}

static void call_finish(mcpcall *h, cJSON *resp /*owned*/) {
  if (h->want_raw) {
    h->out = cJSON_PrintUnformatted(resp);
    if (!h->out) h->out = strdup("{}");
    cJSON_Delete(resp);
    h->done = 1;
    return;
  }
  cJSON *errobj = cJSON_GetObjectItem(resp, "error");
  if (errobj) {
    h->err = strdup(rpc_error_text(errobj));
  } else {
    cJSON *result = cJSON_GetObjectItem(resp, "result");
    capture_server_info(h->c, result);
    const char *bad = bad_result_type(h->c, result);
    if (bad) {
      h->err = strdup(bad);
      cJSON_Delete(resp);
      h->done = 1;
      return;
    }
    cJSON *pick = result;
    if (h->want_tools && result) {
      cJSON *t = cJSON_GetObjectItem(result, "tools");
      if (t) pick = t;
    }
    h->out = pick ? cJSON_PrintUnformatted(pick) : NULL;
    if (!h->out) h->out = strdup(h->want_tools ? "[]" : "{}");
  }
  cJSON_Delete(resp);
  h->done = 1;
}

/* One step towards completion: look for our response, otherwise let the loop
 * run (at most wait_ms) and look again. */
static void call_poll(mcpcall *h, int wait_ms) {
  if (h->done) return;
  mcpconn *c = h->c;
  cJSON *resp = take_pending(c->io, h->id);
  if (!resp) {
    mcp_pump(wait_ms);
    resp = take_pending(c->io, h->id);
  }
  if (resp) { call_finish(h, resp); return; }
  if (!c->io || c->io->eof || c->io->io_err) {
    c->dead = 1;
    h->err = strdup("no response (server exited)");
    h->done = 1;
    return;
  }
  if (h->deadline && now_ms() >= h->deadline) {
    h->err = strdup("no response (timeout)");
    h->done = 1;
  }
}

/* Blocking round trip, for callers that cannot yield (the connect path).
 * Returns the whole JSON-RPC response -- error responses included, because the
 * version probe decides what kind of server it is talking to from the error
 * *code* -- or NULL with *err set when nothing came back at all. */
static cJSON *transact_raw(mcpconn *c, const char *method, cJSON *params,
                           int timeout_s, const char **err) {
  int id = start_call(c, method, params, err);
  if (id < 0) return NULL;
  uint64_t deadline = now_ms() + (uint64_t)timeout_s * 1000;
  for (;;) {
    cJSON *resp = take_pending(c->io, id);
    if (!resp) mcp_pump(MCP_SLICE_MS);
    if (!resp) resp = take_pending(c->io, id);
    if (resp) return resp;
    if (!c->io || c->io->eof || c->io->io_err) {
      c->dead = 1; *err = "no response (server exited)"; return NULL;
    }
    if (now_ms() >= deadline) { *err = "no response (timeout)"; return NULL; }
  }
}

/* transact_raw, reduced to the success case: the detached "result" (caller
 * owns) or NULL with *err set. */
static cJSON *transact_sync(mcpconn *c, const char *method, cJSON *params, const char **err) {
  cJSON *resp = transact_raw(c, method, params, MCP_TIMEOUT, err);
  if (!resp) return NULL;
  cJSON *errobj = cJSON_GetObjectItem(resp, "error");
  if (errobj) {
    *err = rpc_error_text(errobj);
    cJSON_Delete(resp);
    return NULL;
  }
  cJSON *result = cJSON_DetachItemFromObject(resp, "result");
  cJSON_Delete(resp);
  return result ? result : cJSON_CreateObject();
}

/* Fire-and-forget notification (no id, no response awaited). Legacy only: the
 * modern revision defines no client-to-server notification we send. */
static void notify(mcpconn *c, const char *method) {
  cJSON *req = build_request(method, -1, NULL);
  if (c->transport == T_STDIO) {
    stdio_send(c, req);
    cJSON_Delete(req);
    mcp_pump(0); /* let the write start immediately */
    return;
  }
  char *s = cJSON_PrintUnformatted(req);
  cJSON_Delete(req);
  CURL *h = curl_easy_init();
  if (h) {
    struct curl_slist *hl = NULL;
    hl = curl_slist_append(hl, "content-type: application/json");
    hl = append_hdr(hl, "mcp-protocol-version", c->proto ? c->proto : MCP_PROTO_LEGACY);
    if (c->session) hl = append_hdr(hl, "mcp-session-id", c->session);
    for (struct curl_slist *u = c->user_headers; u; u = u->next) hl = curl_slist_append(hl, u->data);
    growbuf g = { 0 };
    curl_easy_setopt(h, CURLOPT_URL, c->url);
    curl_easy_setopt(h, CURLOPT_POST, 1L);
    curl_easy_setopt(h, CURLOPT_POSTFIELDS, s);
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, hl);
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, gb_write);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, &g);
    curl_easy_setopt(h, CURLOPT_TIMEOUT, (long)MCP_TIMEOUT);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
    curl_easy_perform(h);
    curl_slist_free_all(hl);
    curl_easy_cleanup(h);
    free(g.buf);
  }
  free(s);
}

/* ---- version negotiation --------------------------------------------------
 * Legacy: initialize, then notifications/initialized. The version the server
 * answers with is the one in force from then on -- it may be older than the one
 * we asked for -- so it is what later requests (and the HTTP protocol header)
 * must quote. */
static int do_initialize(mcpconn *c, const char **err) {
  c->era = ERA_LEGACY;
  set_str(&c->proto, MCP_PROTO_LEGACY);

  cJSON *params = cJSON_CreateObject();
  cJSON_AddStringToObject(params, "protocolVersion", MCP_PROTO_LEGACY);
  cJSON_AddItemToObject(params, "capabilities", client_caps());
  cJSON_AddItemToObject(params, "clientInfo", client_info());

  cJSON *result = transact_sync(c, "initialize", params, err);
  if (!result) return -1;
  cJSON *pv = cJSON_GetObjectItem(result, "protocolVersion");
  if (cJSON_IsString(pv)) set_str(&c->proto, pv->valuestring);
  capture_server_info(c, result);
  cJSON_Delete(result);
  notify(c, "notifications/initialized");
  return 0;
}

/* The newest revision we and the server both speak, or NULL. */
static const char *pick_modern_version(cJSON *list) {
  if (!cJSON_IsArray(list)) return NULL;
  for (int i = 0; i < N_MODERN_VERSIONS; i++) {
    cJSON *v;
    cJSON_ArrayForEach(v, list) {
      if (cJSON_IsString(v) && strcmp(v->valuestring, MODERN_VERSIONS[i]) == 0)
        return MODERN_VERSIONS[i];
    }
  }
  return NULL;
}

/* Whether the list offers a revision older than the oldest modern one, i.e.
 * one that would be reached through the initialize handshake. Version strings
 * are ISO dates, so the comparison is a strcmp. */
static int has_legacy_version(cJSON *list) {
  if (!cJSON_IsArray(list)) return 0;
  cJSON *v;
  cJSON_ArrayForEach(v, list) {
    if (cJSON_IsString(v) && strcmp(v->valuestring, MODERN_VERSIONS[N_MODERN_VERSIONS - 1]) < 0)
      return 1;
  }
  return 0;
}

enum { PROBE_MODERN, PROBE_LEGACY, PROBE_FAIL };

/* Decide which generation this server speaks, by asking it something only a
 * modern server understands.
 *
 * `server/discover` is the probe because modern servers MUST implement it, it
 * needs no state, and its answer doubles as the version list. Three outcomes,
 * per the spec's backward-compatibility rules:
 *   - a result            -> modern; select a version from supportedVersions;
 *   - an error from the
 *     spec's own -320xx
 *     range              -> still modern (a modern server would not otherwise
 *                            emit one), so do NOT fall back to initialize --
 *                            retry the version it named instead;
 *   - anything else, or
 *     no answer at all   -> legacy; run the handshake.
 * The fallback deliberately is not keyed to one error code: legacy servers
 * answer an unknown pre-initialize method with whatever they feel like
 * (-32601 and -32602 are both common) or with nothing.
 *
 * The probe request itself is sent as a modern one -- era is set to modern
 * first, so start_call attaches _meta -- and unwound if the answer says legacy.
 * The version we announce while probing is our newest; if the server dislikes
 * it, it says so in an UnsupportedProtocolVersionError and we take its list. */
static int probe_discover(mcpconn *c, const char **err) {
  c->era = ERA_MODERN;
  set_str(&c->proto, MODERN_VERSIONS[0]);

  const char *terr = NULL;
  cJSON *resp = transact_raw(c, "server/discover", NULL, MCP_PROBE_TIMEOUT, &terr);
  if (!resp) {
    if (c->io && (c->io->eof || c->io->io_err)) { *err = terr; return PROBE_FAIL; }
    return PROBE_LEGACY; /* silence, or a transport that never answered */
  }

  cJSON *errobj = cJSON_GetObjectItem(resp, "error");
  if (errobj) {
    cJSON *code = cJSON_GetObjectItem(errobj, "code");
    int n = cJSON_IsNumber(code) ? code->valueint : 0;
    if (n == MCP_E_BAD_VERSION) {
      cJSON *data = cJSON_GetObjectItem(errobj, "data");
      cJSON *sup = data ? cJSON_GetObjectItem(data, "supported") : NULL;
      const char *pick = pick_modern_version(sup);
      if (pick) { set_str(&c->proto, pick); cJSON_Delete(resp); return PROBE_MODERN; }
      if (has_legacy_version(sup)) { cJSON_Delete(resp); return PROBE_LEGACY; }
      char list[256];
      join_strings(sup, list, sizeof(list));
      *err = seterr("server speaks no protocol version boggart supports "
                    "(it offers: %s; boggart speaks %s and %s or earlier)",
                    list[0] ? list : "nothing it would name",
                    MCP_PROTO_MODERN, MCP_PROTO_LEGACY);
      cJSON_Delete(resp);
      return PROBE_FAIL;
    }
    /* Other reserved codes still identify a modern server; whatever it is
     * unhappy about will resurface on the real requests, with its own message. */
    int modern = (n == MCP_E_HEADER_MISMATCH || n == MCP_E_MISSING_CAP);
    cJSON_Delete(resp);
    return modern ? PROBE_MODERN : PROBE_LEGACY;
  }

  cJSON *result = cJSON_GetObjectItem(resp, "result");
  cJSON *sup = result ? cJSON_GetObjectItem(result, "supportedVersions") : NULL;
  const char *pick = pick_modern_version(sup);
  if (!pick && cJSON_IsArray(sup)) {
    if (has_legacy_version(sup)) { cJSON_Delete(resp); return PROBE_LEGACY; }
    char list[256];
    join_strings(sup, list, sizeof(list));
    *err = seterr("server speaks no protocol version boggart supports "
                  "(it offers: %s; boggart speaks %s and %s or earlier)",
                  list[0] ? list : "nothing it would name",
                  MCP_PROTO_MODERN, MCP_PROTO_LEGACY);
    cJSON_Delete(resp);
    return PROBE_FAIL;
  }
  /* A result with no supportedVersions is non-conforming; it answered a modern
   * method, so take it at its word and keep the version we announced. */
  if (pick) set_str(&c->proto, pick);
  capture_server_info(c, result);
  cJSON_Delete(resp);
  return PROBE_MODERN;
}

static int negotiate(mcpconn *c, const char **err)
  __attribute__((unused));
static int negotiate(mcpconn *c, const char **err) {
  switch (probe_discover(c, err)) {
    case PROBE_MODERN: return 0;
    case PROBE_FAIL: return -1;
    default: return do_initialize(c, err); /* PROBE_LEGACY */
  }
}

/* Yieldable connect: the same handshake as negotiate(), but each round-trip
 * uses call_wait so a studio core-thread can return to the frame loop. Off a
 * coroutine it still pumps in 50ms slices, matching the old blocking path. */
enum { PH_PROBE = 1, PH_INIT = 2 };
#define HANDLE_IDX 4
static int connect_cont(lua_State *L, int status, lua_KContext phase);
static mcpcall *new_call(lua_State *L, int conn_idx, mcpconn *c, int id, int want_tools);
static void conn_teardown(mcpconn *c);

static int connect_fail(lua_State *L, mcpconn *c, const char *err) {
  c->dead = 1;
  conn_teardown(c);
  lua_pushnil(L);
  lua_pushstring(L, err ? err : "MCP negotiation failed");
  return 2;
}

static cJSON *call_raw_json(mcpcall *h) {
  if (!h->out) return NULL;
  return cJSON_Parse(h->out);
}

static int start_raw_call(lua_State *L, mcpconn *c, const char *method, cJSON *params,
                          int timeout_s, const char **err) {
  int id = start_call(c, method, params, err);
  if (id < 0) return -1;
  lua_settop(L, HANDLE_IDX - 1);
  mcpcall *h = new_call(L, 2, c, id, 0);
  h->want_raw = 1;
  h->deadline = now_ms() + (uint64_t)timeout_s * 1000;
  return 0;
}

static int connect_cont(lua_State *L, int status, lua_KContext phase) {
  (void)status;
  lua_settop(L, HANDLE_IDX);
  mcpcall *h = (mcpcall *)luaL_checkudata(L, HANDLE_IDX, API_TYPE_CALL);
  mcpconn *c = (mcpconn *)luaL_checkudata(L, 2, API_TYPE_MCP);

  if (!h->done) {
    if (lua_isyieldable(L)) {
      call_poll(h, MCP_YIELD_MS);
      if (!h->done) {
        lua_pushliteral(L, "io");
        lua_pushvalue(L, HANDLE_IDX);
        return lua_yieldk(L, 2, phase, connect_cont);
      }
    } else {
      while (!h->done) call_poll(h, MCP_SLICE_MS);
    }
  }

  const char *err = NULL;
  if (phase == PH_PROBE) {
    cJSON *resp = call_raw_json(h);
    int pr;
    if (!resp) {
      const char *terr = h->err;
      if (c->io && (c->io->eof || c->io->io_err)) {
        return connect_fail(L, c, terr ? terr : "no response (server exited)");
      }
      pr = PROBE_LEGACY;
    } else {
      pr = PROBE_LEGACY;
      cJSON *errobj = cJSON_GetObjectItem(resp, "error");
      if (errobj) {
        cJSON *code = cJSON_GetObjectItem(errobj, "code");
        int n = cJSON_IsNumber(code) ? code->valueint : 0;
        if (n == MCP_E_BAD_VERSION) {
          cJSON *data = cJSON_GetObjectItem(errobj, "data");
          cJSON *sup = data ? cJSON_GetObjectItem(data, "supported") : NULL;
          const char *pick = pick_modern_version(sup);
          if (pick) { set_str(&c->proto, pick); pr = PROBE_MODERN; }
          else if (has_legacy_version(sup)) pr = PROBE_LEGACY;
          else {
            char list[256];
            join_strings(sup, list, sizeof(list));
            err = seterr("server speaks no protocol version boggart supports "
                          "(it offers: %s; boggart speaks %s and %s or earlier)",
                          list[0] ? list : "nothing it would name",
                          MCP_PROTO_MODERN, MCP_PROTO_LEGACY);
            pr = PROBE_FAIL;
          }
        } else {
          int modern = (n == MCP_E_HEADER_MISMATCH || n == MCP_E_MISSING_CAP);
          pr = modern ? PROBE_MODERN : PROBE_LEGACY;
        }
      } else {
        cJSON *result = cJSON_GetObjectItem(resp, "result");
        cJSON *sup = result ? cJSON_GetObjectItem(result, "supportedVersions") : NULL;
        const char *pick = pick_modern_version(sup);
        if (!pick && cJSON_IsArray(sup)) {
          if (has_legacy_version(sup)) pr = PROBE_LEGACY;
          else {
            char list[256];
            join_strings(sup, list, sizeof(list));
            err = seterr("server speaks no protocol version boggart supports "
                          "(it offers: %s; boggart speaks %s and %s or earlier)",
                          list[0] ? list : "nothing it would name",
                          MCP_PROTO_MODERN, MCP_PROTO_LEGACY);
            pr = PROBE_FAIL;
          }
        } else {
          if (pick) set_str(&c->proto, pick);
          capture_server_info(c, result);
          pr = PROBE_MODERN;
        }
      }
      cJSON_Delete(resp);
    }
    if (pr == PROBE_FAIL) return connect_fail(L, c, err);
    if (pr == PROBE_MODERN) { lua_settop(L, 2); return 1; }

    c->era = ERA_LEGACY;
    set_str(&c->proto, MCP_PROTO_LEGACY);
    cJSON *params = cJSON_CreateObject();
    cJSON_AddStringToObject(params, "protocolVersion", MCP_PROTO_LEGACY);
    cJSON_AddItemToObject(params, "capabilities", client_caps());
    cJSON_AddItemToObject(params, "clientInfo", client_info());
    if (start_raw_call(L, c, "initialize", params, MCP_TIMEOUT, &err) != 0) {
      return connect_fail(L, c, err);
    }
    return connect_cont(L, 0, PH_INIT);
  }

  cJSON *resp = call_raw_json(h);
  if (!resp) return connect_fail(L, c, h->err ? h->err : "initialize failed");
  cJSON *errobj = cJSON_GetObjectItem(resp, "error");
  if (errobj) {
    err = rpc_error_text(errobj);
    cJSON_Delete(resp);
    return connect_fail(L, c, err);
  }
  cJSON *result = cJSON_GetObjectItem(resp, "result");
  cJSON *pv = result ? cJSON_GetObjectItem(result, "protocolVersion") : NULL;
  if (cJSON_IsString(pv)) set_str(&c->proto, pv->valuestring);
  capture_server_info(c, result);
  cJSON_Delete(resp);
  notify(c, "notifications/initialized");
  lua_settop(L, 2);
  return 1;
}

/* ---- connection setup ----------------------------------------------------- */
static void free_strv(char **v) {
  if (!v) return;
  for (int i = 0; v[i]; i++) free(v[i]);
  free(v);
}

static char *join_env(const char *k, const char *v) {
  size_t kl = strlen(k), vl = strlen(v);
  char *s = malloc(kl + vl + 2);
  if (!s) return NULL;
  memcpy(s, k, kl); s[kl] = '=';
  memcpy(s + kl + 1, v, vl); s[kl + vl + 1] = 0;
  return s;
}

static int env_key_eq(const char *entry, const char *key, size_t klen) {
#ifdef _WIN32
  /* Windows environment names are case-insensitive. */
  for (size_t i = 0; i < klen; i++) {
    char a = entry[i], b = key[i];
    if (a >= 'a' && a <= 'z') a = (char)(a - 32);
    if (b >= 'a' && b <= 'z') b = (char)(b - 32);
    if (a != b || a == 0) return 0;
  }
#else
  if (strncmp(entry, key, klen) != 0) return 0;
#endif
  return entry[klen] == '=';
}

/* spec.env overrides on top of the inherited environment (uv_spawn replaces the
 * whole block, so the inherited part has to be materialised). NULL = inherit. */
static char **build_env(lua_State *L, int spec_idx) {
  lua_getfield(L, spec_idx, "env");
  if (!lua_istable(L, -1)) { lua_pop(L, 1); return NULL; }

  int n_over = 0;
  lua_pushnil(L);
  while (lua_next(L, -2)) {
    if (lua_type(L, -2) == LUA_TSTRING && lua_isstring(L, -1)) n_over++;
    lua_pop(L, 1);
  }
  if (n_over == 0) { lua_pop(L, 1); return NULL; }

  uv_env_item_t *items = NULL;
  int count = 0;
  if (uv_os_environ(&items, &count) != 0) { items = NULL; count = 0; }

  char **env = calloc((size_t)count + (size_t)n_over + 1, sizeof(char *));
  int len = 0;
  if (env) {
    for (int i = 0; i < count; i++) {
      /* Windows exposes per-drive cwd pseudo-variables named "=C:"; they are of
       * no use to a child MCP server and only confuse an env block we rebuild
       * by hand, so drop anything without a real name. */
      if (items[i].name[0] == '\0' || items[i].name[0] == '=') continue;
      char *e = join_env(items[i].name, items[i].value);
      if (e) env[len++] = e;
    }
  }
  if (items) uv_os_free_environ(items, count);
  if (!env) { lua_pop(L, 1); return NULL; }

  lua_pushnil(L);
  while (lua_next(L, -2)) {
    if (lua_type(L, -2) == LUA_TSTRING && lua_isstring(L, -1)) {
      const char *k = lua_tostring(L, -2);
      const char *v = lua_tostring(L, -1);
      char *entry = join_env(k, v);
      if (entry) {
        size_t klen = strlen(k);
        int slot = -1;
        for (int i = 0; i < len; i++) if (env_key_eq(env[i], k, klen)) { slot = i; break; }
        if (slot >= 0) { free(env[slot]); env[slot] = entry; }
        else env[len++] = entry;
      }
    }
    lua_pop(L, 1);
  }
  env[len] = NULL;
  lua_pop(L, 1); /* env table */
  return env;
}

typedef struct { uv_handle_t *want; int found; } walkfind;
static void walk_find(uv_handle_t *h, void *arg) {
  walkfind *w = (walkfind *)arg;
  if (h == w->want) w->found = 1;
}

static int connect_stdio(mcpconn *c, lua_State *L, int spec_idx, const char **err) {
  if (loop_ensure(L) != 0) { *err = "could not obtain the uv loop"; return -1; }

  lua_getfield(L, spec_idx, "command");
  const char *command = luaL_checkstring(L, -1);

  /* argv = command + args[] */
  int nargs = 0;
  lua_getfield(L, spec_idx, "args");
  if (lua_istable(L, -1)) nargs = (int)luaL_len(L, -1);
  char **argv = calloc((size_t)nargs + 2, sizeof(char *));
  if (!argv) { lua_pop(L, 2); *err = "out of memory"; return -1; }
  argv[0] = strdup(command);
  for (int i = 1; i <= nargs; i++) {
    lua_geti(L, -1, i);
    const char *a = lua_tostring(L, -1);
    argv[i] = strdup(a ? a : "");
    lua_pop(L, 1);
  }
  argv[nargs + 1] = NULL;
  lua_pop(L, 1); /* args */
  lua_pop(L, 1); /* command (argv[0] owns a copy) */

  char **envp = build_env(L, spec_idx);

  mcpio *io = c->io;
  if (uv_pipe_init(g_loop, &io->cin, 0) != 0) {
    free_strv(argv); free_strv(envp);
    *err = "uv_pipe_init failed";
    return -1;
  }
  io->cin.data = io; io->have_in = 1; io->refs++;
  if (uv_pipe_init(g_loop, &io->cout, 0) != 0) {
    free_strv(argv); free_strv(envp);
    *err = "uv_pipe_init failed";
    return -1;
  }
  io->cout.data = io; io->have_out = 1; io->refs++;

  uv_stdio_container_t stdio[3];
  stdio[0].flags = (uv_stdio_flags)(UV_CREATE_PIPE | UV_READABLE_PIPE);
  stdio[0].data.stream = (uv_stream_t *)&io->cin;
  stdio[1].flags = (uv_stdio_flags)(UV_CREATE_PIPE | UV_WRITABLE_PIPE);
  stdio[1].data.stream = (uv_stream_t *)&io->cout;
  /* stderr is not ours. A server that abort()s (llm-station does this on a
   * ZMQ bind race) used to dump its backtrace into the studio's terminal
   * and look like the window had crashed. UV_IGNORE: we do not care. */
  stdio[2].flags = UV_IGNORE;

  uv_process_options_t opts;
  memset(&opts, 0, sizeof(opts));
  opts.file = argv[0];
  opts.args = argv; /* libuv does the Windows quoting */
  opts.env = envp;  /* NULL = inherit */
  opts.stdio = stdio;
  opts.stdio_count = 3;
  opts.exit_cb = on_proc_exit;
  /* Detached so a child abort() cannot signal this process group. Hide the
   * console on Windows. The window must outlive any MCP server. */
  opts.flags = UV_PROCESS_WINDOWS_HIDE | UV_PROCESS_DETACHED;

  io->proc.data = io;
  int rc = uv_spawn(g_loop, &io->proc, &opts);
  free_strv(argv);
  free_strv(envp);
  if (rc != 0) {
    /* A failed uv_spawn may still leave the process handle registered with the
     * loop -- always so on Windows, and on unix whenever the failure was the
     * exec itself (libuv deliberately keeps the handle initialized there). The
     * memory is ours to free, so an orphan left in the loop's handle queue is a
     * use-after-free waiting to happen: ask the loop whether it knows the
     * handle, and adopt it for closing if it does. There is no child behind it,
     * so it must never be signalled -- its pid is still 0, and killing pid 0
     * would signal our own process group. */
    walkfind wf = { (uv_handle_t *)&io->proc, 0 };
    uv_walk(g_loop, walk_find, &wf);
    if (wf.found) { io->have_proc = 1; io->refs++; }
    *err = seterr("spawn failed: %s", uv_strerror(rc));
    return -1;
  }
  io->have_proc = 1; io->proc_spawned = 1; io->refs++;

  rc = uv_read_start((uv_stream_t *)&io->cout, io_alloc, io_read);
  if (rc != 0) { *err = seterr("uv_read_start failed: %s", uv_strerror(rc)); return -1; }
  return 0;
}

static int connect_http(mcpconn *c, lua_State *L, int spec_idx, const char **err) {
  (void)err;
  lua_getfield(L, spec_idx, "url");
  const char *url = luaL_checkstring(L, -1);
  c->url = strdup(url);
  lua_pop(L, 1);

  lua_getfield(L, spec_idx, "headers");
  if (lua_istable(L, -1)) {
    int n = (int)luaL_len(L, -1);
    for (int i = 1; i <= n; i++) {
      lua_geti(L, -1, i);
      const char *hs = lua_tostring(L, -1);
      if (hs) c->user_headers = curl_slist_append(c->user_headers, hs);
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  return 0;
}

/* ---- teardown ------------------------------------------------------------- */
/* Close the child down, giving libuv a chance to reap it, then hand the io
 * struct over to the close callbacks (the last one frees it). */
static void io_shutdown(mcpio *io) {
  if (!io) return;
  if (io->have_out && !uv_is_closing((uv_handle_t *)&io->cout)) {
    uv_read_stop((uv_stream_t *)&io->cout);
    uv_close((uv_handle_t *)&io->cout, on_close);
  }
  if (io->have_in && !uv_is_closing((uv_handle_t *)&io->cin))
    uv_close((uv_handle_t *)&io->cin, on_close); /* EOF on stdin: most servers exit */
  if (io->have_proc) {
    if (io->proc_spawned && !io->proc_exited) {
      uv_process_kill(&io->proc, SIGTERM);
      uint64_t deadline = now_ms() + 200;
      while (!io->proc_exited && now_ms() < deadline) mcp_pump(20);
      if (!io->proc_exited) {
        uv_process_kill(&io->proc, SIGKILL);
        deadline = now_ms() + 200;
        while (!io->proc_exited && now_ms() < deadline) mcp_pump(20);
      }
    }
    if (!uv_is_closing((uv_handle_t *)&io->proc)) uv_close((uv_handle_t *)&io->proc, on_close);
  }
  io_release(io); /* drop the owner reference */
  mcp_pump(0);    /* run the close callbacks now rather than at the next call */
  mcp_pump(0);
}

static void conn_teardown(mcpconn *c) {
  io_shutdown(c->io);
  c->io = NULL;
  if (c->user_headers) { curl_slist_free_all(c->user_headers); c->user_headers = NULL; }
  free(c->url); c->url = NULL;
  free(c->session); c->session = NULL;
  free(c->server_info); c->server_info = NULL;
  free(c->proto); c->proto = NULL;
  free(c->caps); c->caps = NULL;
  free(c->instructions); c->instructions = NULL;
}

/* ---- Lua entry points ----------------------------------------------------- */
static int l_connect(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "transport");
  const char *t = luaL_optstring(L, -1, "stdio");
  int transport = (strcmp(t, "http") == 0) ? T_HTTP : T_STDIO;
  lua_pop(L, 1);

  lua_settop(L, 1);
  mcpconn *c = (mcpconn *)lua_newuserdatauv(L, sizeof(mcpconn), 0);
  memset(c, 0, sizeof(*c));
  c->transport = transport;
  c->next_id = 1;
  luaL_setmetatable(L, API_TYPE_MCP);

  c->io = calloc(1, sizeof(mcpio));
  if (!c->io) { lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2; }
  c->io->refs = 1; /* the owner reference */

  const char *err = NULL;
  int rc = (transport == T_STDIO) ? connect_stdio(c, L, 1, &err)
                                  : connect_http(c, L, 1, &err);
  if (rc != 0) {
    const char *msg = seterr("failed to start MCP transport: %s", err ? err : "unknown");
    c->dead = 1;
    conn_teardown(c);
    lua_pushnil(L);
    lua_pushstring(L, msg);
    return 2;
  }

  err = NULL;
  c->era = ERA_MODERN;
  set_str(&c->proto, MODERN_VERSIONS[0]);
  if (start_raw_call(L, c, "server/discover", NULL, MCP_PROBE_TIMEOUT, &err) != 0) {
    return connect_fail(L, c, err);
  }
  return connect_cont(L, 0, PH_PROBE);
}

static mcpconn *check_conn(lua_State *L) {
  return (mcpconn *)luaL_checkudata(L, 1, API_TYPE_MCP);
}

/* Create the call handle at the top of the stack, pinning the connection in its
 * uservalue so the userdata cannot be collected while the call is in flight. */
static mcpcall *new_call(lua_State *L, int conn_idx, mcpconn *c, int id, int want_tools) {
  mcpcall *h = (mcpcall *)lua_newuserdatauv(L, sizeof(mcpcall), 1);
  memset(h, 0, sizeof(*h));
  h->c = c;
  h->id = id;
  h->want_tools = want_tools;
  h->deadline = now_ms() + (uint64_t)MCP_TIMEOUT * 1000;
  luaL_setmetatable(L, API_TYPE_CALL);
  lua_pushvalue(L, conn_idx);
  lua_setiuservalue(L, -2, 1);
  return h;
}

static int call_push(lua_State *L, mcpcall *h) {
  if (h->err) { lua_pushnil(L); lua_pushstring(L, h->err); return 2; }
  lua_pushstring(L, h->out ? h->out : "{}");
  return 1;
}

static int call_wait(lua_State *L);

static int call_cont(lua_State *L, int status, lua_KContext ctx) {
  (void)status; (void)ctx;
  lua_settop(L, HANDLE_IDX);
  return call_wait(L);
}

/* Wait for the response. Under the swarm scheduler this yields ("io", handle)
 * -- the same protocol lua/sched.lua already uses for async HTTP -- so other
 * agents keep running (and http.pump keeps their streams alive) while an MCP
 * call is outstanding. Off a coroutine it pumps the loop in short slices. */
static int call_wait(lua_State *L) {
  mcpcall *h = (mcpcall *)luaL_checkudata(L, HANDLE_IDX, API_TYPE_CALL);
  for (;;) {
    if (h->done) return call_push(L, h);
    if (lua_isyieldable(L)) {
      call_poll(h, MCP_YIELD_MS);
      if (h->done) return call_push(L, h);
      lua_pushliteral(L, "io");
      lua_pushvalue(L, HANDLE_IDX);
      return lua_yieldk(L, 2, 0, call_cont);
    }
    call_poll(h, MCP_SLICE_MS);
  }
}

static int start_and_wait(lua_State *L, mcpconn *c, const char *method, cJSON *params, int want_tools) {
  const char *err = NULL;
  int id = start_call(c, method, params, &err);
  if (id < 0) { lua_pushnil(L); lua_pushstring(L, err ? err : "mcp request failed"); return 2; }
  lua_settop(L, HANDLE_IDX - 1);
  new_call(L, 1, c, id, want_tools);
  return call_wait(L);
}

static int l_tools(lua_State *L) {
  mcpconn *c = check_conn(L);
  return start_and_wait(L, c, "tools/list", NULL, 1);
}

/* tools/list, returning the whole result object rather than just result.tools.
 *
 * conn:tools() unwraps the array, which is convenient and quietly lossy: it
 * discards nextCursor, so a server with more tools than fit in one page had
 * everything past the first page silently ignored. Nobody noticed because the
 * servers tried so far answer in one page -- Chrome DevTools MCP returns all
 * 29 at once -- and a truncated tool list looks exactly like a server that
 * offers fewer tools.
 *
 * The cursor loop belongs in Lua (mcphost.lua), where accumulating pages is a
 * table insert rather than a second pass over cJSON ownership. So this returns
 * the result verbatim and lets the caller drive. */
static int l_list_tools(lua_State *L) {
  mcpconn *c = check_conn(L);
  const char *cursor = luaL_optstring(L, 2, NULL);
  cJSON *params = NULL;
  if (cursor && *cursor) {
    params = cJSON_CreateObject();
    cJSON_AddStringToObject(params, "cursor", cursor);
  }
  return start_and_wait(L, c, "tools/list", params, 0);
}

static cJSON *call_params(lua_State *L) {
  const char *name = luaL_checkstring(L, 2);
  const char *args_json = luaL_optstring(L, 3, "{}");
  cJSON *params = cJSON_CreateObject();
  cJSON_AddStringToObject(params, "name", name);
  cJSON *args = cJSON_Parse(args_json);
  cJSON_AddItemToObject(params, "arguments", args ? args : cJSON_CreateObject());
  return params;
}

static int l_call(lua_State *L) {
  mcpconn *c = check_conn(L);
  return start_and_wait(L, c, "tools/call", call_params(L), 0);
}

/* Async tools/call: returns a handle to poll, in the shape of an http.begin
 * request (take/status/close). */
static int l_begin(lua_State *L) {
  mcpconn *c = check_conn(L);
  cJSON *params = call_params(L);
  const char *err = NULL;
  int id = start_call(c, "tools/call", params, &err);
  lua_settop(L, HANDLE_IDX - 1);
  mcpcall *h = new_call(L, 1, c, id < 0 ? -1 : id, 0);
  if (id < 0) { h->err = strdup(err ? err : "mcp request failed"); h->done = 1; }
  return 1;
}

static mcpcall *check_call(lua_State *L) {
  return (mcpcall *)luaL_checkudata(L, 1, API_TYPE_CALL);
}

static int l_pump(lua_State *L) {
  mcp_pump((int)luaL_optinteger(L, 1, 0));
  return 0;
}

static int l_call_status(lua_State *L) {
  mcpcall *h = check_call(L);
  if (!h->done) call_poll(h, (int)luaL_optinteger(L, 2, 0));
  if (!h->done) { lua_pushstring(L, "running"); return 1; }
  if (h->err) { lua_pushstring(L, "error"); lua_pushstring(L, h->err); return 2; }
  lua_pushstring(L, "done");
  lua_pushstring(L, h->out ? h->out : "{}");
  return 2;
}

static int l_call_take(lua_State *L) {
  mcpcall *h = check_call(L);
  if (!h->done) call_poll(h, 0);
  if (h->done && h->out) {
    lua_pushstring(L, h->out);
    free(h->out); h->out = NULL;
  } else {
    lua_pushliteral(L, "");
  }
  return 1;
}

static int l_call_close(lua_State *L) {
  mcpcall *h = check_call(L);
  /* Only our own memory: the connection may already be finalized. */
  free(h->out); h->out = NULL;
  free(h->err); h->err = NULL;
  h->done = 1;
  return 0;
}

/* What this connection turned out to be: which generation was negotiated, the
 * exact version in force, and whatever the server said about itself. `boggart
 * doctor` and the studio's server list show the era, because "which MCP is this
 * server speaking" is otherwise invisible until something misbehaves. */
static int l_info(lua_State *L) {
  mcpconn *c = check_conn(L);
  cJSON *o = cJSON_CreateObject();
  cJSON_AddStringToObject(o, "era", c->era == ERA_MODERN ? "modern" : "legacy");
  cJSON_AddStringToObject(o, "protocol", c->proto ? c->proto : "");
  cJSON_AddStringToObject(o, "transport", c->transport == T_HTTP ? "http" : "stdio");
  if (c->server_info) {
    cJSON *si = cJSON_Parse(c->server_info);
    if (si) cJSON_AddItemToObject(o, "serverInfo", si);
  }
  if (c->caps) {
    cJSON *caps = cJSON_Parse(c->caps);
    if (caps) cJSON_AddItemToObject(o, "capabilities", caps);
  }
  if (c->instructions) cJSON_AddStringToObject(o, "instructions", c->instructions);
  char *s = cJSON_PrintUnformatted(o);
  cJSON_Delete(o);
  lua_pushstring(L, s ? s : "{}");
  free(s);
  return 1;
}

static int l_close(lua_State *L) {
  mcpconn *c = check_conn(L);
  conn_teardown(c);
  c->dead = 1;
  return 0;
}

static const luaL_Reg conn_methods[] = {
  {"tools", l_tools},
  {"list_tools", l_list_tools},
  {"call", l_call},
  {"begin", l_begin},
  {"info", l_info},
  {"close", l_close},
  {"__gc", l_close},
  {NULL, NULL},
};

static const luaL_Reg call_methods[] = {
  {"take", l_call_take},
  {"status", l_call_status},
  {"close", l_call_close},
  {"__gc", l_call_close},
  {NULL, NULL},
};

static const luaL_Reg mcp_lib[] = {
  {"connect", l_connect},
  {"pump", l_pump},
  {NULL, NULL},
};

int luaopen_boggart_mcp(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_MCP);
  luaL_setfuncs(L, conn_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_CALL);
  luaL_setfuncs(L, call_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, mcp_lib);
  return 1;
}
