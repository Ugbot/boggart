/* lhttp.c -- minimal libcurl binding for boggart.
 *
 * Exposes one function to Lua:
 *
 *   http.request{
 *     url      = "https://...",         -- required
 *     method   = "POST",                 -- default "GET"
 *     headers  = { "content-type: ...", ... }, -- array of header lines
 *     auth     = true,                        -- attach the C-side credential
 *     body     = "…",                    -- request body (optional)
 *     on_chunk = function(s) ... end,    -- optional: called per received chunk (SSE)
 *     timeout  = 600,                     -- seconds, optional
 *   }  ->  status:int, body:string            (on success)
 *      ->  nil, errmsg:string                 (on transport failure)
 *
 * The full response body is always accumulated and returned; on_chunk lets the
 * caller stream Server-Sent Events as they arrive. The C side knows nothing
 * about the Anthropic API -- request shaping and SSE parsing live in Lua.
 */
#include <curl/curl.h>
#include <string.h>
#include <stdlib.h>

#include "uv.h"

/* Credentials live in lauth.c and are attached here, so the key never enters
 * the Lua state: a request asks for auth with `auth = true` and the header is
 * built in C from the C-side store. */
const char *boggart_auth_header(void);

#include "lua.h"
#include "lauxlib.h"

/* luv gives each interpreter state its own uv loop; async HTTP lives on it. */
extern uv_loop_t *luv_loop(lua_State *L);

typedef struct {
  lua_State *L;
  int on_chunk_ref;   /* LUA_NOREF if absent */
  luaL_Buffer body;   /* accumulates the full response */
  int cb_error;       /* set if the callback raised */
} http_ctx;

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  http_ctx *ctx = (http_ctx *)userdata;
  size_t n = size * nmemb;

  luaL_addlstring(&ctx->body, ptr, n);

  if (ctx->on_chunk_ref != LUA_NOREF && !ctx->cb_error) {
    lua_State *L = ctx->L;
    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->on_chunk_ref);
    lua_pushlstring(L, ptr, n);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
      /* Swallow the error string; flag it so we abort the transfer.
       * Returning a short count makes libcurl stop with CURLE_WRITE_ERROR. */
      ctx->cb_error = 1;
      lua_pop(L, 1);
      return 0;
    }
  }
  return n;
}

static int l_http_request(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);

  /* Read EVERY request field (and build the header slist) BEFORE curl_easy_init
   * so that no Lua-API call that could raise (metamethods, OOM) happens while we
   * own C resources that would leak. url/method/body are left on the Lua stack
   * for the whole call so their C string pointers stay pinned against GC --
   * CURLOPT_URL/POSTFIELDS do not copy. */
  lua_getfield(L, 1, "url");
  const char *url = luaL_checkstring(L, -1);   /* pinned at this stack slot */

  lua_getfield(L, 1, "method");
  if (!lua_isstring(L, -1)) { lua_pop(L, 1); lua_pushliteral(L, "GET"); }
  const char *method = lua_tostring(L, -1);    /* pinned */

  lua_getfield(L, 1, "body");
  size_t body_len = 0;
  const char *body = lua_isstring(L, -1) ? lua_tolstring(L, -1, &body_len) : NULL; /* pinned */

  lua_getfield(L, 1, "timeout");
  long timeout = (long)luaL_optinteger(L, -1, 600);
  lua_pop(L, 1); /* timeout is a scalar; safe to drop */

  struct curl_slist *hdrs = NULL;
  lua_getfield(L, 1, "headers");
  if (lua_istable(L, -1)) {
    lua_Integer n = luaL_len(L, -1);
    for (lua_Integer i = 1; i <= n; i++) {
      lua_geti(L, -1, i);
      const char *h = lua_tostring(L, -1);
      if (h) hdrs = curl_slist_append(hdrs, h);
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1); /* headers table */

  /* auth = true: attach the credential in C. Lua never holds the value. */
  lua_getfield(L, 1, "auth");
  if (lua_toboolean(L, -1)) {
    const char *ah = boggart_auth_header();
    if (ah) hdrs = curl_slist_append(hdrs, ah);
  }
  lua_pop(L, 1);

  http_ctx ctx;
  ctx.L = L;
  ctx.on_chunk_ref = LUA_NOREF;
  ctx.cb_error = 0;
  luaL_buffinit(L, &ctx.body);

  lua_getfield(L, 1, "on_chunk");
  if (lua_isfunction(L, -1)) {
    ctx.on_chunk_ref = luaL_ref(L, LUA_REGISTRYINDEX);
  } else {
    lua_pop(L, 1);
  }

  CURL *curl = curl_easy_init();
  if (!curl) {
    if (hdrs) curl_slist_free_all(hdrs);
    if (ctx.on_chunk_ref != LUA_NOREF)
      luaL_unref(L, LUA_REGISTRYINDEX, ctx.on_chunk_ref);
    lua_pushnil(L);
    lua_pushstring(L, "curl_easy_init failed");
    return 2;
  }

  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
  if (hdrs) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
  if (body) {
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_len);
  }
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, ""); /* allow gzip */

  CURLcode rc = curl_easy_perform(curl);

  long status = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);

  if (hdrs) curl_slist_free_all(hdrs);
  if (ctx.on_chunk_ref != LUA_NOREF)
    luaL_unref(L, LUA_REGISTRYINDEX, ctx.on_chunk_ref);
  curl_easy_cleanup(curl);

  if (ctx.cb_error) {
    /* the callback raised; surface it as a normal Lua error */
    luaL_pushresult(&ctx.body); /* discard */
    lua_pop(L, 1);
    return luaL_error(L, "http.request: on_chunk callback error");
  }

  if (rc != CURLE_OK) {
    luaL_pushresult(&ctx.body);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, curl_easy_strerror(rc));
    return 2;
  }

  /* Finalize the buffer first (its box must be on the stack top for
   * pushresult), then order the two return values as (status, body). */
  luaL_pushresult(&ctx.body); /* [body] */
  lua_pushinteger(L, status); /* [body][status] */
  lua_insert(L, -2);          /* [status][body] */
  return 2;
}

/* ------------------------------------------------------------------------
 * Async API (curl_multi) -- lets the swarm scheduler keep many streaming
 * requests in flight at once and interleave them cooperatively.
 *
 *   req = http.begin{url,method,headers,body,timeout}
 *   http.pump(timeout_ms)   -> running_handles     (advance all transfers once)
 *   req:take()              -> new bytes since last take ("" if none)
 *   req:status()            -> "running" | "done", status_code | "error", msg
 *   req:close()             (idempotent; also runs on __gc)
 *
 * Unlike the blocking path, the write callback touches no Lua state (the
 * scheduler, not curl, drives Lua), and the body is copied into curl
 * (COPYPOSTFIELDS) so nothing needs pinning across scheduler iterations.
 * ---------------------------------------------------------------------- */
#define API_TYPE_REQ "boggart.httpreq"

/* Async HTTP is on the uv loop, not a second reactor. Each interpreter's loop
 * owns a curl_multi; curl's socket/timer callbacks register uv_poll / uv_timer
 * handles, so running the loop (uv_run) advances transfers and delivers
 * completions. http.pump is now a BOUNDED uv_run -- the same call that drives
 * subprocesses and MCP -- so one loop-run waits on every kind of IO at once and
 * a frame owner can wait bounded on all of it. There is no curl_multi_wait. */
typedef struct hctx hctx;

typedef struct {
  CURL *easy;
  struct curl_slist *hdrs;
  char *buf;          /* received bytes not yet taken by Lua */
  size_t len, cap;
  int added;          /* currently in a multi */
  int completed;      /* transfer finished */
  int oom;            /* buffer realloc failed */
  CURLcode result;
  long status;
  hctx *ctx;          /* the loop-owned multi this handle belongs to */
} httpreq;

typedef struct sockctx sockctx;

struct hctx {
  CURLM *multi;
  uv_loop_t *loop;
  uv_timer_t timer;       /* curl's requested timeout */
  uv_timer_t pump_timer;  /* bounds a pump()'s uv_run */
  int running;            /* running_handles, for pump()'s return */
  sockctx *socks;         /* live socket polls, so shutdown can close them all */
};

struct sockctx {
  uv_poll_t poll;
  curl_socket_t sockfd;
  hctx *ctx;
  sockctx *next, *prev;   /* intrusive list off hctx.socks */
};

/* Drain finished transfers into their httpreq, so status()/take() observe the
 * completion the frame it happens. Called after every socket/timer action. */
static void check_completions(hctx *ctx) {
  CURLMsg *m;
  int q;
  while ((m = curl_multi_info_read(ctx->multi, &q))) {
    if (m->msg != CURLMSG_DONE) continue;
    httpreq *r = NULL;
    curl_easy_getinfo(m->easy_handle, CURLINFO_PRIVATE, (char **)&r);
    if (r) {
      r->completed = 1;
      r->result = m->data.result;
      curl_easy_getinfo(m->easy_handle, CURLINFO_RESPONSE_CODE, &r->status);
      if (r->added) { curl_multi_remove_handle(ctx->multi, m->easy_handle); r->added = 0; }
    }
  }
}

/* A curl socket became readable/writable: hand the event to curl. */
static void on_uv_poll(uv_poll_t *p, int status, int events) {
  sockctx *sc = (sockctx *)p->data;
  int flags = 0;
  if (events & UV_READABLE) flags |= CURL_CSELECT_IN;
  if (events & UV_WRITABLE) flags |= CURL_CSELECT_OUT;
  if (status < 0) flags |= CURL_CSELECT_ERR;
  curl_multi_socket_action(sc->ctx->multi, sc->sockfd, flags, &sc->ctx->running);
  check_completions(sc->ctx);
}

static void on_poll_close(uv_handle_t *h) { free(h->data); }

/* curl tells us which sockets to watch; we mirror each as a uv_poll handle. */
static int socket_cb(CURL *easy, curl_socket_t s, int what, void *userp, void *socketp) {
  (void) easy;
  hctx *ctx = (hctx *)userp;
  sockctx *sc = (sockctx *)socketp;
  if (what == CURL_POLL_REMOVE) {
    if (sc) {
      /* unlink from hctx.socks so shutdown does not touch a freed handle */
      if (sc->prev) sc->prev->next = sc->next; else ctx->socks = sc->next;
      if (sc->next) sc->next->prev = sc->prev;
      uv_poll_stop(&sc->poll);
      curl_multi_assign(ctx->multi, s, NULL);
      uv_close((uv_handle_t *)&sc->poll, on_poll_close); /* frees sc */
    }
    return 0;
  }
  if (!sc) {
    sc = (sockctx *)calloc(1, sizeof(*sc));
    if (!sc) return -1;
    sc->ctx = ctx;
    sc->sockfd = s;
    uv_poll_init_socket(ctx->loop, &sc->poll, s);
    sc->poll.data = sc;
    curl_multi_assign(ctx->multi, s, sc);
    sc->prev = NULL;                       /* link into the live-poll list */
    sc->next = ctx->socks;
    if (ctx->socks) ctx->socks->prev = sc;
    ctx->socks = sc;
  }
  int events = 0;
  if (what == CURL_POLL_IN) events = UV_READABLE;
  else if (what == CURL_POLL_OUT) events = UV_WRITABLE;
  else if (what == CURL_POLL_INOUT) events = UV_READABLE | UV_WRITABLE;
  uv_poll_start(&sc->poll, events, on_uv_poll);
  return 0;
}

/* curl's timeout fired: let it drive whatever is due. */
static void on_curl_timeout(uv_timer_t *t) {
  hctx *ctx = (hctx *)t->data;
  curl_multi_socket_action(ctx->multi, CURL_SOCKET_TIMEOUT, 0, &ctx->running);
  check_completions(ctx);
}

static int timer_cb(CURLM *multi, long ms, void *userp) {
  (void) multi;
  hctx *ctx = (hctx *)userp;
  if (ms < 0) uv_timer_stop(&ctx->timer);
  else uv_timer_start(&ctx->timer, on_curl_timeout, (uint64_t)ms, 0);
  return 0;
}

static void pump_stop_cb(uv_timer_t *t) { uv_stop((uv_loop_t *)t->data); }

/* One hctx per interpreter/loop, kept in that state's registry. Created lazily,
 * lives for the state -- as the old global multi did for the process. */
static char g_hctx_key;

static hctx *get_ctx(lua_State *L, int create) {
  lua_rawgetp(L, LUA_REGISTRYINDEX, &g_hctx_key);
  hctx *ctx = (hctx *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (ctx || !create) return ctx;
  ctx = (hctx *)calloc(1, sizeof(*ctx));
  if (!ctx) { luaL_error(L, "http: out of memory"); return NULL; }
  ctx->loop = luv_loop(L);
  ctx->multi = curl_multi_init();
  if (!ctx->multi) { free(ctx); luaL_error(L, "curl_multi_init failed"); return NULL; }
  uv_timer_init(ctx->loop, &ctx->timer);
  ctx->timer.data = ctx;
  uv_timer_init(ctx->loop, &ctx->pump_timer);
  ctx->pump_timer.data = ctx->loop;
  curl_multi_setopt(ctx->multi, CURLMOPT_SOCKETFUNCTION, socket_cb);
  curl_multi_setopt(ctx->multi, CURLMOPT_SOCKETDATA, ctx);
  curl_multi_setopt(ctx->multi, CURLMOPT_TIMERFUNCTION, timer_cb);
  curl_multi_setopt(ctx->multi, CURLMOPT_TIMERDATA, ctx);
  lua_pushlightuserdata(L, ctx);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &g_hctx_key);
  return ctx;
}

/* Neutralise the raw curl-on-libuv handles this module leaves on luv's shared
 * loop, to be called from C right before lua_close(). lua_close() runs luv's
 * loop_gc, which uv_walks the loop and uv_closes every open handle through
 * luv_close_cb -- and that cb casts handle->data to a luv_handle_t*. Our two
 * ctx timers carry non-luv data (the ctx and the loop pointer, set in get_ctx),
 * so that cast is a type confusion and lua_rawgeti() on the garbage ref faults:
 * a use-after-free at process exit (SIGSEGV / exit 139). We can't hand luv our
 * timers to free (they're embedded in the calloc'd ctx, not luv_handle_t), but
 * luv_close_cb early-returns on a NULL data -- so we stop the timers and NULL
 * their data, and loop_gc then closes them as harmless no-ops. We deliberately
 * do NOT free the ctx (loop_gc still touches &ctx->timer while closing) nor
 * curl_multi_cleanup (its poll sockets reference the multi); leaking both at
 * exit is fine. Idempotent, and a no-op when no HTTP was ever done.
 *
 * Known gap: a poll socket still open for an in-flight request at exit carries
 * non-luv data too (sockctx*) and would fault the same way; a normal exit has
 * none (completed transfers already closed their polls). Tracking live polls to
 * neutralise them as well is the follow-up if that edge case ever bites. */
void boggart_http_shutdown(lua_State *L) {
  hctx *ctx = get_ctx(L, 0);
  if (!ctx) return;
  uv_timer_stop(&ctx->timer);
  uv_timer_stop(&ctx->pump_timer);
  ctx->timer.data = NULL;
  ctx->pump_timer.data = NULL;
  /* Close every live socket poll. A completed transfer whose connection curl
   * kept alive leaves its poll OPEN and referenced -- which is what lets the
   * main scheduler sleep on the socket, but also what pins a worker's loop open
   * so its teardown uv_run() never returns. Closing them here lets the loop
   * drain. Tracked in an explicit list (not uv_walk) so we only ever touch polls
   * this module created. */
  sockctx *sc = ctx->socks;
  ctx->socks = NULL;
  while (sc) {
    sockctx *next = sc->next;
    curl_multi_assign(ctx->multi, sc->sockfd, NULL);
    uv_poll_stop(&sc->poll);
    if (!uv_is_closing((uv_handle_t *)&sc->poll))
      uv_close((uv_handle_t *)&sc->poll, on_poll_close); /* frees sc later */
    sc = next;
  }
  /* Flush the deferred close callbacks so the handles are gone before the
   * caller's next step (a worker's run-out uv_run, or lua_close's loop_gc).
   * Bounded: a handful of iterations clears any pending close. */
  for (int i = 0; i < 16 && uv_loop_alive(ctx->loop); i++)
    uv_run(ctx->loop, UV_RUN_NOWAIT);
  lua_pushnil(L);
  lua_rawsetp(L, LUA_REGISTRYINDEX, &g_hctx_key);
}

static size_t write_async(char *ptr, size_t size, size_t nmemb, void *ud) {
  httpreq *r = (httpreq *)ud;
  size_t n = size * nmemb;
  if (r->len + n > r->cap) {
    size_t ncap = r->cap ? r->cap * 2 : 8192;
    while (ncap < r->len + n) ncap *= 2;
    char *nb = realloc(r->buf, ncap);
    if (!nb) { r->oom = 1; return 0; } /* abort the transfer */
    r->buf = nb;
    r->cap = ncap;
  }
  memcpy(r->buf + r->len, ptr, n);
  r->len += n;
  return n;
}

static int l_http_begin(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  hctx *ctx = get_ctx(L, 1); /* this loop's curl_multi, created on first use */

  /* Create the handle userdata FIRST so any later raise cleans up via __gc. */
  httpreq *r = (httpreq *)lua_newuserdatauv(L, sizeof(httpreq), 0);
  memset(r, 0, sizeof(*r));
  luaL_setmetatable(L, API_TYPE_REQ);
  int ridx = lua_gettop(L);

  r->easy = curl_easy_init();
  if (!r->easy) return luaL_error(L, "curl_easy_init failed");

  lua_getfield(L, 1, "url");
  curl_easy_setopt(r->easy, CURLOPT_URL, luaL_checkstring(L, -1)); /* curl copies */
  lua_pop(L, 1);

  lua_getfield(L, 1, "method");
  curl_easy_setopt(r->easy, CURLOPT_CUSTOMREQUEST, luaL_optstring(L, -1, "GET"));
  lua_pop(L, 1);

  lua_getfield(L, 1, "body");
  if (lua_isstring(L, -1)) {
    size_t blen;
    const char *b = lua_tolstring(L, -1, &blen);
    curl_easy_setopt(r->easy, CURLOPT_POSTFIELDSIZE, (long)blen);
    curl_easy_setopt(r->easy, CURLOPT_COPYPOSTFIELDS, b); /* curl copies the body */
  }
  lua_pop(L, 1);

  lua_getfield(L, 1, "headers");
  if (lua_istable(L, -1)) {
    lua_Integer n = luaL_len(L, -1);
    for (lua_Integer i = 1; i <= n; i++) {
      lua_geti(L, -1, i);
      const char *h = lua_tostring(L, -1);
      if (h) r->hdrs = curl_slist_append(r->hdrs, h);
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  lua_getfield(L, 1, "auth");
  if (lua_toboolean(L, -1)) {
    const char *ah = boggart_auth_header();
    if (ah) r->hdrs = curl_slist_append(r->hdrs, ah);
  }
  lua_pop(L, 1);
  if (r->hdrs) curl_easy_setopt(r->easy, CURLOPT_HTTPHEADER, r->hdrs);

  lua_getfield(L, 1, "timeout");
  curl_easy_setopt(r->easy, CURLOPT_TIMEOUT, (long)luaL_optinteger(L, -1, 600));
  lua_pop(L, 1);

  curl_easy_setopt(r->easy, CURLOPT_WRITEFUNCTION, write_async);
  curl_easy_setopt(r->easy, CURLOPT_WRITEDATA, r);
  curl_easy_setopt(r->easy, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(r->easy, CURLOPT_ACCEPT_ENCODING, "");
  curl_easy_setopt(r->easy, CURLOPT_PRIVATE, r);

  curl_multi_add_handle(ctx->multi, r->easy);
  r->added = 1;
  r->ctx = ctx;

  lua_settop(L, ridx); /* leave the request userdata on top */
  return 1;
}

/* Advance transfers by running the loop for up to `ms`. Since curl now lives on
 * the loop, this waits on curl sockets AND subprocesses AND timers together and
 * returns the instant any of them moves -- the single bounded wait the whole
 * design turns on. ms<=0 polls without blocking (a frame owner that has its own
 * clock). Returns the running-handle count, unchanged from before. */
static int l_http_pump(lua_State *L) {
  long ms = (long)luaL_optinteger(L, 1, 50);
  hctx *ctx = get_ctx(L, 0);
  if (!ctx) { lua_pushinteger(L, 0); return 1; }
  if (ms <= 0) {
    uv_run(ctx->loop, UV_RUN_NOWAIT);
  } else {
    uv_timer_start(&ctx->pump_timer, pump_stop_cb, (uint64_t)ms, 0);
    uv_run(ctx->loop, UV_RUN_ONCE);
    uv_timer_stop(&ctx->pump_timer);
  }
  check_completions(ctx);
  lua_pushinteger(L, ctx->running);
  return 1;
}

static int l_req_take(lua_State *L) {
  httpreq *r = (httpreq *)luaL_checkudata(L, 1, API_TYPE_REQ);
  lua_pushlstring(L, r->buf ? r->buf : "", r->len);
  r->len = 0;
  return 1;
}

static int l_req_status(lua_State *L) {
  httpreq *r = (httpreq *)luaL_checkudata(L, 1, API_TYPE_REQ);
  if (r->oom) { lua_pushstring(L, "error"); lua_pushstring(L, "response buffer OOM"); return 2; }
  if (!r->completed) { lua_pushstring(L, "running"); return 1; }
  if (r->result != CURLE_OK) {
    lua_pushstring(L, "error");
    lua_pushstring(L, curl_easy_strerror(r->result));
    return 2;
  }
  lua_pushstring(L, "done");
  lua_pushinteger(L, r->status);
  return 2;
}

static int l_req_close(lua_State *L) {
  httpreq *r = (httpreq *)luaL_checkudata(L, 1, API_TYPE_REQ);
  if (r->added && r->ctx) { curl_multi_remove_handle(r->ctx->multi, r->easy); r->added = 0; }
  if (r->easy) { curl_easy_cleanup(r->easy); r->easy = NULL; }
  if (r->hdrs) { curl_slist_free_all(r->hdrs); r->hdrs = NULL; }
  if (r->buf) { free(r->buf); r->buf = NULL; r->len = r->cap = 0; }
  return 0;
}

static const luaL_Reg req_methods[] = {
  {"take", l_req_take},
  {"status", l_req_status},
  {"close", l_req_close},
  {"__gc", l_req_close},
  {NULL, NULL},
};

/* http.shutdown() -- tear down this loop's curl_multi and its socket polls, so a
 * loop with idle keep-alive connections can drain (a worker before it exits).
 * A no-op if no HTTP was done; the pool is recreated lazily on the next call. */
static int l_http_shutdown(lua_State *L) {
  boggart_http_shutdown(L);
  return 0;
}

static const luaL_Reg http_lib[] = {
  {"request", l_http_request},
  {"begin", l_http_begin},
  {"pump", l_http_pump},
  {"shutdown", l_http_shutdown},
  {NULL, NULL},
};

int luaopen_boggart_http(lua_State *L) {
  curl_global_init(CURL_GLOBAL_DEFAULT);

  luaL_newmetatable(L, API_TYPE_REQ);
  luaL_setfuncs(L, req_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, http_lib);
  return 1;
}
