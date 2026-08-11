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

/* Credentials live in lauth.c and are attached here, so the key never enters
 * the Lua state: a request asks for auth with `auth = true` and the header is
 * built in C from the C-side store. */
const char *boggart_auth_header(void);

#include "lua.h"
#include "lauxlib.h"

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

static CURLM *g_multi = NULL;

typedef struct {
  CURL *easy;
  struct curl_slist *hdrs;
  char *buf;          /* received bytes not yet taken by Lua */
  size_t len, cap;
  int added;          /* currently in g_multi */
  int completed;      /* transfer finished */
  int oom;            /* buffer realloc failed */
  CURLcode result;
  long status;
} httpreq;

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
  if (!g_multi) {
    g_multi = curl_multi_init();
    if (!g_multi) return luaL_error(L, "curl_multi_init failed");
  }

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

  curl_multi_add_handle(g_multi, r->easy);
  r->added = 1;

  lua_settop(L, ridx); /* leave the request userdata on top */
  return 1;
}

static int l_http_pump(lua_State *L) {
  long ms = (long)luaL_optinteger(L, 1, 50);
  if (!g_multi) { lua_pushinteger(L, 0); return 1; }
  int running = 0;
  curl_multi_wait(g_multi, NULL, 0, (int)ms, NULL);
  curl_multi_perform(g_multi, &running);
  CURLMsg *m;
  int q;
  while ((m = curl_multi_info_read(g_multi, &q))) {
    if (m->msg == CURLMSG_DONE) {
      httpreq *r = NULL;
      curl_easy_getinfo(m->easy_handle, CURLINFO_PRIVATE, (char **)&r);
      if (r) {
        r->completed = 1;
        r->result = m->data.result;
        curl_easy_getinfo(m->easy_handle, CURLINFO_RESPONSE_CODE, &r->status);
        if (r->added) { curl_multi_remove_handle(g_multi, m->easy_handle); r->added = 0; }
      }
    }
  }
  lua_pushinteger(L, running);
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
  if (r->added && g_multi) { curl_multi_remove_handle(g_multi, r->easy); r->added = 0; }
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

static const luaL_Reg http_lib[] = {
  {"request", l_http_request},
  {"begin", l_http_begin},
  {"pump", l_http_pump},
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
