/* ltypesafe.c -- the TypeSafe wire: System One (the "Jev" model) as a typed
 * judge rather than a chat endpoint.
 *
 * TypeSafe answers QUESTIONS about STATE, not prompts. One POST carries a
 * state (string, object or array) and a map of typed questions -- noul
 * (yes/no as a probability), choice (one option from a labelled set, with a
 * distribution), score (a rubric level, with a distribution) -- and the
 * answer comes back as numbers code can branch on. No text to parse, no
 * tool-call dance. That makes it a different kind of thing from the chat
 * wires in lua/api.lua: it never streams, never holds a transcript, and has
 * nothing to do with the model picker. It gets its own module.
 *
 * What lives here, and why in C:
 *   - the request codec. Validation is the contract the API enforces with a
 *     422 (choice: 1..255 options in a map; score: 2..10 ordered levels;
 *     every question typed and instructed), so it is checked here, once,
 *     before a byte leaves. Instructions and descriptions are EntryType --
 *     string | object | array | null -- and pass through verbatim, so a
 *     rubric that already exists as JSON (a taxonomy, a schema, a DB row) is
 *     sent as JSON, not flattened into prose.
 *   - the response codec. Answers come back typed: probabilities keyed by
 *     integer level for scores (the wire says "0","1"), a `ranked` list per
 *     distribution so the common "top-k" read is one index, usage and the
 *     resolved model id as meta. Error bodies (401/422/429/529) become one
 *     structured error {status, kind, message} with a __tostring, so a caller
 *     can `tostring(err)` for a log line or `err.kind` for policy.
 *   - the credential question. `has_key` asks lauth about the "typesafe"
 *     slot (TYPESAFE_API_KEY, or a stored key); the value never enters Lua.
 *     The header itself is attached in lhttp.c when a request names the slot
 *     and the providers table registers it for api.typesafe.ai (lauth's
 *     host/slot registry) -- the same path every other vendor takes.
 *
 * Transport is NOT here: lua/typesafe.lua drives the existing async curl
 * path (http.begin + yield("io", req)) and owns the retry policy. C moves
 * bytes and enforces shape; Lua composes. Always compiled, no build flag:
 * this needs only cJSON and the plumbing every build already has.
 *
 * Limits, from docs.typesafe.ai/models (2026-09): 64k tokens per request,
 * 32k for state plus the longest question; 250k tokens/s, 1200 req/min;
 * text only. Exposed as typesafe.limits() so a caller can size state.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include <lua.h>
#include <lauxlib.h>
#include "cJSON.h"

#define TS_DEFAULT_BASE  "https://api.typesafe.ai"
#define TS_SLOT          "typesafe"
#define TS_DEFAULT_MODEL "jev-latest"
#define TS_CHOICE_MAX    255
#define TS_SCORE_MIN     2
#define TS_SCORE_MAX     10
#define TS_MAX_DEPTH     64

#define TS_ERR_META "boggart.typesafe.error"

/* ---- errors ----------------------------------------------------------------
 * One shape everywhere: { kind, message, status? } with a __tostring that
 * yields the message, so `nil, err` reads as a string in a log and as data in
 * a policy branch. `kind` is the vocabulary a caller switches on:
 *   auth | validation | rate_limit | overloaded | http | parse | transport
 */
static int err_tostring(lua_State *L) {
  lua_getfield(L, 1, "message");
  if (lua_isstring(L, -1)) return 1;
  lua_pop(L, 1);
  lua_pushliteral(L, "typesafe error");
  return 1;
}

static void push_error(lua_State *L, const char *kind, const char *message, long status) {
  lua_createtable(L, 0, 3);
  lua_pushstring(L, kind);    lua_setfield(L, -2, "kind");
  lua_pushstring(L, message); lua_setfield(L, -2, "message");
  if (status > 0) { lua_pushinteger(L, status); lua_setfield(L, -2, "status"); }
  luaL_setmetatable(L, TS_ERR_META);
}

/* nil, err -- the uniform failure return. */
static int fail(lua_State *L, const char *kind, const char *message, long status) {
  lua_pushnil(L);
  push_error(L, kind, message, status);
  return 2;
}

/* typesafe.error(kind, message [, status]) -> err. For lua/typesafe.lua, so
 * transport failures it detects carry the same shape as the ones made here. */
static int l_error(lua_State *L) {
  const char *kind = luaL_checkstring(L, 1);
  const char *msg = luaL_checkstring(L, 2);
  long status = (long)luaL_optinteger(L, 3, 0);
  push_error(L, kind, msg, status);
  return 1;
}

/* ---- endpoint --------------------------------------------------------------
 * TYPESAFE_BASE_URL overrides the host (a proxy, a mock in a test); the
 * paths are the API's. Trailing slashes are stripped so "…/" and "…" agree. */
static void base_url(char *out, size_t n) {
  const char *env = getenv("TYPESAFE_BASE_URL");
  const char *src = (env && *env) ? env : TS_DEFAULT_BASE;
  snprintf(out, n, "%s", src);
  size_t len = strlen(out);
  while (len > 0 && out[len - 1] == '/') out[--len] = '\0';
}

static int l_endpoint(lua_State *L) {
  char base[1024];
  base_url(base, sizeof(base));
  lua_pushfstring(L, "%s/v1/systemone", base);
  return 1;
}

static int l_models_url(lua_State *L) {
  char base[1024];
  base_url(base, sizeof(base));
  lua_pushfstring(L, "%s/v1/models", base);
  return 1;
}

/* typesafe.has_key() -> bool. Delegates to auth.has_key("typesafe"): the env
 * variable TYPESAFE_API_KEY or a stored key for the slot. The key stays in
 * lauth.c; this only learns whether one exists. */
static int l_has_key(lua_State *L) {
  lua_getglobal(L, "auth");
  if (lua_istable(L, -1)) {
    lua_getfield(L, -1, "has_key");
    if (lua_isfunction(L, -1)) {
      lua_pushliteral(L, TS_SLOT);
      if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
        int has = lua_toboolean(L, -1);
        lua_pop(L, 2);
        lua_pushboolean(L, has);
        return 1;
      }
      lua_pop(L, 1); /* the error */
    } else {
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  lua_pushboolean(L, 0);
  return 1;
}

static int l_limits(lua_State *L) {
  lua_createtable(L, 0, 8);
  lua_pushinteger(L, 64000);         lua_setfield(L, -2, "request_tokens");
  lua_pushinteger(L, 32000);         lua_setfield(L, -2, "state_tokens");
  lua_pushinteger(L, TS_CHOICE_MAX); lua_setfield(L, -2, "choice_max");
  lua_pushinteger(L, TS_SCORE_MIN);  lua_setfield(L, -2, "score_min");
  lua_pushinteger(L, TS_SCORE_MAX);  lua_setfield(L, -2, "score_max");
  lua_pushinteger(L, 250000);        lua_setfield(L, -2, "tokens_per_second");
  lua_pushinteger(L, 1200);          lua_setfield(L, -2, "requests_per_minute");
  lua_pushliteral(L, TS_DEFAULT_MODEL); lua_setfield(L, -2, "default_model");
  return 1;
}

/* ---- Lua -> cJSON ----------------------------------------------------------
 * The array rule is lua/json.lua's, exactly: a table is an array when it is
 * non-empty and t[1..n] are all present for n = the number of pairs. An empty
 * table is an object -- which is what a caller means far more often than an
 * empty list, and what json.lua sends too, so the two codecs agree. */
static int lua_is_array(lua_State *L, int idx) {
  idx = lua_absindex(L, idx);
  lua_Integer n = 0;
  lua_pushnil(L);
  while (lua_next(L, idx)) { n++; lua_pop(L, 1); }
  if (n == 0) return 0;
  for (lua_Integer i = 1; i <= n; i++) {
    lua_rawgeti(L, idx, i);
    int nil = lua_isnil(L, -1);
    lua_pop(L, 1);
    if (nil) return 0;
  }
  return 1;
}

/* lua/json.lua's null sentinel (`json.null`, a table with a metatable) means
 * JSON null, which the wire allows as an EntryType. Only a table WITH a
 * metatable is checked, so the lookup never runs for ordinary data. */
static int is_json_null(lua_State *L, int idx) {
  if (!lua_getmetatable(L, idx)) return 0;
  lua_pop(L, 1);
  int r = 0;
  lua_getglobal(L, "package");
  if (lua_istable(L, -1)) {
    lua_getfield(L, -1, "loaded");
    if (lua_istable(L, -1)) {
      lua_getfield(L, -1, "json");
      if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "null");
        r = lua_rawequal(L, -1, idx);
        lua_pop(L, 1);
      }
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  return r;
}

/* Returns a new cJSON item, or NULL with *err set to a static message. */
static cJSON *to_cjson(lua_State *L, int idx, int depth, const char **err) {
  idx = lua_absindex(L, idx);
  if (depth > TS_MAX_DEPTH) { *err = "nesting too deep"; return NULL; }
  switch (lua_type(L, idx)) {
    case LUA_TNIL:     return cJSON_CreateNull();
    case LUA_TBOOLEAN: return cJSON_CreateBool(lua_toboolean(L, idx));
    case LUA_TNUMBER: {
      double d = lua_tonumber(L, idx);
      if (isnan(d) || isinf(d)) { *err = "cannot encode a non-finite number"; return NULL; }
      return cJSON_CreateNumber(d);
    }
    case LUA_TSTRING: {
      size_t n;
      const char *s = lua_tolstring(L, idx, &n);
      if (strlen(s) != n) { *err = "strings may not contain NUL"; return NULL; }
      return cJSON_CreateString(s);
    }
    case LUA_TTABLE: {
      if (is_json_null(L, idx)) return cJSON_CreateNull();
      if (lua_is_array(L, idx)) {
        cJSON *arr = cJSON_CreateArray();
        lua_Integer n = luaL_len(L, idx);
        for (lua_Integer i = 1; i <= n; i++) {
          lua_rawgeti(L, idx, i);
          cJSON *item = to_cjson(L, -1, depth + 1, err);
          lua_pop(L, 1);
          if (!item) { cJSON_Delete(arr); return NULL; }
          cJSON_AddItemToArray(arr, item);
        }
        return arr;
      }
      cJSON *obj = cJSON_CreateObject();
      lua_pushnil(L);
      while (lua_next(L, idx)) {
        char kbuf[64];
        const char *key = NULL;
        int kt = lua_type(L, -2);
        if (kt == LUA_TSTRING) {
          key = lua_tostring(L, -2);
        } else if (kt == LUA_TNUMBER) {
          if (lua_isinteger(L, -2)) snprintf(kbuf, sizeof(kbuf), "%lld", (long long)lua_tointeger(L, -2));
          else snprintf(kbuf, sizeof(kbuf), "%.14g", lua_tonumber(L, -2));
          key = kbuf;
        } else if (kt == LUA_TBOOLEAN) {
          key = lua_toboolean(L, -2) ? "true" : "false";
        } else {
          lua_pop(L, 2);
          cJSON_Delete(obj);
          *err = "object keys must be strings";
          return NULL;
        }
        cJSON *item = to_cjson(L, -1, depth + 1, err);
        if (!item) { lua_pop(L, 2); cJSON_Delete(obj); return NULL; }
        cJSON_AddItemToObject(obj, key, item);
        lua_pop(L, 1);
      }
      return obj;
    }
    default:
      *err = "cannot encode this Lua type (function/userdata/thread)";
      return NULL;
  }
}

/* ---- cJSON -> Lua ----------------------------------------------------------
 * Whole numbers become Lua integers (token counts, level indices); anything
 * else stays a float. JSON null becomes nil, which in a table means absent --
 * the API never sends a null a caller needs to distinguish from missing. */
static void push_cjson(lua_State *L, const cJSON *item) {
  if (!item) { lua_pushnil(L); return; }
  if (cJSON_IsNull(item))   { lua_pushnil(L); return; }
  if (cJSON_IsBool(item))   { lua_pushboolean(L, cJSON_IsTrue(item)); return; }
  if (cJSON_IsNumber(item)) {
    double d = item->valuedouble;
    if (floor(d) == d && fabs(d) < 9007199254740992.0) lua_pushinteger(L, (lua_Integer)d);
    else lua_pushnumber(L, d);
    return;
  }
  if (cJSON_IsString(item)) { lua_pushstring(L, item->valuestring ? item->valuestring : ""); return; }
  if (cJSON_IsArray(item)) {
    lua_createtable(L, cJSON_GetArraySize(item), 0);
    lua_Integer i = 1;
    const cJSON *c;
    cJSON_ArrayForEach(c, item) { push_cjson(L, c); lua_rawseti(L, -2, i++); }
    return;
  }
  if (cJSON_IsObject(item)) {
    lua_newtable(L);
    const cJSON *c;
    cJSON_ArrayForEach(c, item) {
      if (!c->string) continue;
      push_cjson(L, c);
      lua_setfield(L, -2, c->string);
    }
    return;
  }
  lua_pushnil(L);
}

/* ---- request encoding ------------------------------------------------------
 * typesafe.encode{ state= | state_json=, model=?, questions= } -> json | nil, err
 *
 * `state` is any Lua value the wire allows (string, table); `state_json` is a
 * pre-encoded JSON text for callers that already hold one (a DB row, a tool
 * result) and should not pay a decode/encode round trip. Exactly one of the
 * two. Questions are validated to the API's own rules so the failure is a
 * local, named error rather than a 422 after a network round trip. */

/* Copy a question's `instructions` (any EntryType, but present). */
static int add_entry_field(lua_State *L, cJSON *q, int qidx, const char *field, const char **err) {
  lua_getfield(L, qidx, field);
  if (lua_isnil(L, -1)) { lua_pop(L, 1); return 0; }
  cJSON *v = to_cjson(L, -1, 1, err);
  lua_pop(L, 1);
  if (!v) return -1;
  cJSON_AddItemToObject(q, field, v);
  return 1;
}

/* Builds the question object or returns NULL with a message in errbuf. */
static cJSON *encode_question(lua_State *L, int qidx, const char *key, char *errbuf, size_t errn) {
  const char *err = NULL;
  qidx = lua_absindex(L, qidx);
  if (!lua_istable(L, qidx)) {
    snprintf(errbuf, errn, "question '%s' must be a table", key);
    return NULL;
  }
  lua_getfield(L, qidx, "type");
  const char *type = lua_tostring(L, -1);
  int is_noul = type && strcmp(type, "noul") == 0;
  int is_choice = type && strcmp(type, "choice") == 0;
  int is_score = type && strcmp(type, "score") == 0;
  lua_pop(L, 1);
  if (!is_noul && !is_choice && !is_score) {
    snprintf(errbuf, errn, "question '%s': type must be noul, choice or score (got %s)",
             key, type ? type : "nil");
    return NULL;
  }

  cJSON *q = cJSON_CreateObject();
  cJSON_AddStringToObject(q, "type", type);

  int r = add_entry_field(L, q, qidx, "instructions", &err);
  if (r < 0) { snprintf(errbuf, errn, "question '%s': instructions: %s", key, err); cJSON_Delete(q); return NULL; }
  if (r == 0) { snprintf(errbuf, errn, "question '%s': instructions are required", key); cJSON_Delete(q); return NULL; }

  lua_getfield(L, qidx, "criteria");
  int has_criteria = !lua_isnil(L, -1);
  if (is_noul) {
    /* optional { true = ..., false = ... }; boolean keys accepted too */
    if (has_criteria) {
      if (!lua_istable(L, -1)) {
        snprintf(errbuf, errn, "question '%s': noul criteria must be a table with true/false", key);
        goto bad;
      }
      cJSON *c = cJSON_CreateObject();
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        const char *ck = NULL;
        if (lua_type(L, -2) == LUA_TBOOLEAN) ck = lua_toboolean(L, -2) ? "true" : "false";
        else if (lua_type(L, -2) == LUA_TSTRING) ck = lua_tostring(L, -2);
        if (!ck || (strcmp(ck, "true") != 0 && strcmp(ck, "false") != 0)) {
          lua_pop(L, 2);
          cJSON_Delete(c);
          snprintf(errbuf, errn, "question '%s': noul criteria keys must be true/false", key);
          goto bad;
        }
        cJSON *v = to_cjson(L, -1, 2, &err);
        if (!v) { lua_pop(L, 2); cJSON_Delete(c); snprintf(errbuf, errn, "question '%s': criteria: %s", key, err); goto bad; }
        cJSON_AddItemToObject(c, ck, v);
        lua_pop(L, 1);
      }
      cJSON_AddItemToObject(q, "criteria", c);
    }
  } else if (is_choice) {
    if (!has_criteria || !lua_istable(L, -1) || lua_is_array(L, -1)) {
      snprintf(errbuf, errn, "question '%s': choice criteria must be a map of option -> description", key);
      goto bad;
    }
    cJSON *c = cJSON_CreateObject();
    int n = 0;
    lua_pushnil(L);
    while (lua_next(L, -2)) {
      if (lua_type(L, -2) != LUA_TSTRING) {
        lua_pop(L, 2);
        cJSON_Delete(c);
        snprintf(errbuf, errn, "question '%s': choice option names must be strings", key);
        goto bad;
      }
      if (++n > TS_CHOICE_MAX) {
        lua_pop(L, 2);
        cJSON_Delete(c);
        snprintf(errbuf, errn, "question '%s': at most %d choice options", key, TS_CHOICE_MAX);
        goto bad;
      }
      cJSON *v = to_cjson(L, -1, 2, &err);
      if (!v) { lua_pop(L, 2); cJSON_Delete(c); snprintf(errbuf, errn, "question '%s': criteria: %s", key, err); goto bad; }
      cJSON_AddItemToObject(c, lua_tostring(L, -2), v);
      lua_pop(L, 1);
    }
    if (n == 0) {
      cJSON_Delete(c);
      snprintf(errbuf, errn, "question '%s': choice needs at least one option", key);
      goto bad;
    }
    cJSON_AddItemToObject(q, "criteria", c);
  } else { /* score */
    if (!has_criteria || !lua_istable(L, -1) || !lua_is_array(L, -1)) {
      snprintf(errbuf, errn, "question '%s': score criteria must be an ordered array of level descriptions", key);
      goto bad;
    }
    lua_Integer n = luaL_len(L, -1);
    if (n < TS_SCORE_MIN || n > TS_SCORE_MAX) {
      snprintf(errbuf, errn, "question '%s': score needs %d..%d levels (got %lld)",
               key, TS_SCORE_MIN, TS_SCORE_MAX, (long long)n);
      goto bad;
    }
    cJSON *c = to_cjson(L, -1, 1, &err);
    if (!c) { snprintf(errbuf, errn, "question '%s': criteria: %s", key, err); goto bad; }
    cJSON_AddItemToObject(q, "criteria", c);
  }
  lua_pop(L, 1); /* criteria */

  /* Anything else on the question passes through verbatim: forward
   * compatible with fields the API grows that this file has not learned. */
  lua_pushnil(L);
  while (lua_next(L, qidx)) {
    const char *fk = lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : NULL;
    if (fk && strcmp(fk, "type") != 0 && strcmp(fk, "instructions") != 0
        && strcmp(fk, "criteria") != 0) {
      cJSON *v = to_cjson(L, -1, 1, &err);
      if (!v) { lua_pop(L, 2); snprintf(errbuf, errn, "question '%s': %s: %s", key, fk, err); cJSON_Delete(q); return NULL; }
      cJSON_AddItemToObject(q, fk, v);
    }
    lua_pop(L, 1);
  }
  return q;

bad:
  lua_pop(L, 1); /* criteria */
  cJSON_Delete(q);
  return NULL;
}

static int l_encode(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  const char *err = NULL;
  char errbuf[512];
  cJSON *root = cJSON_CreateObject();

  /* state | state_json */
  lua_getfield(L, 1, "state_json");
  lua_getfield(L, 1, "state");
  int has_state = !lua_isnil(L, -1), has_json = !lua_isnil(L, -2);
  if (has_state && has_json) { lua_pop(L, 2); cJSON_Delete(root); return fail(L, "validation", "give state or state_json, not both", 0); }
  if (!has_state && !has_json) { lua_pop(L, 2); cJSON_Delete(root); return fail(L, "validation", "state is required", 0); }
  if (has_json) {
    size_t n;
    const char *txt = lua_tolstring(L, -2, &n);
    cJSON *st = txt ? cJSON_ParseWithLength(txt, n) : NULL;
    if (!st) { lua_pop(L, 2); cJSON_Delete(root); return fail(L, "validation", "state_json is not valid JSON", 0); }
    cJSON_AddItemToObject(root, "state", st);
  } else {
    int t = lua_type(L, -1);
    if (t != LUA_TSTRING && t != LUA_TTABLE) {
      lua_pop(L, 2); cJSON_Delete(root);
      return fail(L, "validation", "state must be a string, object or array", 0);
    }
    cJSON *st = to_cjson(L, -1, 1, &err);
    if (!st) { lua_pop(L, 2); cJSON_Delete(root); snprintf(errbuf, sizeof(errbuf), "state: %s", err); return fail(L, "validation", errbuf, 0); }
    cJSON_AddItemToObject(root, "state", st);
  }
  lua_pop(L, 2);

  lua_getfield(L, 1, "model");
  cJSON_AddStringToObject(root, "model", luaL_optstring(L, -1, TS_DEFAULT_MODEL));
  lua_pop(L, 1);

  lua_getfield(L, 1, "questions");
  if (!lua_istable(L, -1)) { lua_pop(L, 1); cJSON_Delete(root); return fail(L, "validation", "questions must be a table keyed by question id", 0); }
  cJSON *qs = cJSON_CreateObject();
  int nq = 0;
  lua_pushnil(L);
  while (lua_next(L, -2)) {
    if (lua_type(L, -2) != LUA_TSTRING) {
      lua_pop(L, 2); lua_pop(L, 1);
      cJSON_Delete(qs); cJSON_Delete(root);
      return fail(L, "validation", "question ids must be strings", 0);
    }
    const char *key = lua_tostring(L, -2);
    cJSON *q = encode_question(L, -1, key, errbuf, sizeof(errbuf));
    if (!q) {
      lua_pop(L, 2); lua_pop(L, 1);
      cJSON_Delete(qs); cJSON_Delete(root);
      return fail(L, "validation", errbuf, 0);
    }
    cJSON_AddItemToObject(qs, key, q);
    nq++;
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  if (nq == 0) { cJSON_Delete(qs); cJSON_Delete(root); return fail(L, "validation", "at least one question is required", 0); }
  cJSON_AddItemToObject(root, "questions", qs);

  char *out = cJSON_PrintUnformatted(root);
  cJSON_Delete(root);
  if (!out) return fail(L, "validation", "out of memory encoding request", 0);
  lua_pushstring(L, out);
  free(out);
  return 1;
}

/* ---- response decoding -----------------------------------------------------
 * typesafe.decode(body [, status]) -> answers, meta | nil, err
 *
 * answers[id] = { type="noul",   noul=p }
 *             | { type="choice", choice=opt, confidence=c,
 *                 probabilities={opt=p}, ranked={ {option=,p=}, ... } }
 *             | { type="score",  score=s, confidence=c, legend={[lvl]=desc},
 *                 probabilities={[lvl]=p}, ranked={ {level=,p=}, ... } }
 * meta = { model=, usage={input_tokens=,output_tokens=} }
 *
 * With a non-2xx status, or a body that is an error envelope, the return is
 * nil + { status, kind, message }. */

static const char *kind_for_status(long status) {
  if (status == 401 || status == 403) return "auth";
  if (status == 422 || status == 400) return "validation";
  if (status == 429) return "rate_limit";
  if (status == 529 || status == 503) return "overloaded";
  return "http";
}

/* Best-effort human message from an error body. Vendors disagree on the
 * envelope ({error:"..."}, {error:{message}}, {detail:"..."}, FastAPI's
 * {detail:[{msg,loc}]}), so try each and fall back to the raw text. */
static void error_message(const cJSON *root, const char *raw, size_t rawn, char *out, size_t n) {
  const cJSON *e = root ? cJSON_GetObjectItemCaseSensitive(root, "error") : NULL;
  if (e && cJSON_IsString(e)) { snprintf(out, n, "%s", e->valuestring); return; }
  if (e && cJSON_IsObject(e)) {
    const cJSON *m = cJSON_GetObjectItemCaseSensitive(e, "message");
    if (m && cJSON_IsString(m)) { snprintf(out, n, "%s", m->valuestring); return; }
  }
  const cJSON *d = root ? cJSON_GetObjectItemCaseSensitive(root, "detail") : NULL;
  if (d && cJSON_IsString(d)) { snprintf(out, n, "%s", d->valuestring); return; }
  /* The live envelope (observed 2026-09): {"detail":{"error_type":"...","message":"..."}}. */
  if (d && cJSON_IsObject(d)) {
    const cJSON *m = cJSON_GetObjectItemCaseSensitive(d, "message");
    const cJSON *t = cJSON_GetObjectItemCaseSensitive(d, "error_type");
    if (m && cJSON_IsString(m)) {
      if (t && cJSON_IsString(t)) snprintf(out, n, "%s: %s", t->valuestring, m->valuestring);
      else snprintf(out, n, "%s", m->valuestring);
      return;
    }
  }
  if (d && cJSON_IsArray(d)) {
    size_t used = 0;
    const cJSON *it;
    cJSON_ArrayForEach(it, d) {
      const cJSON *m = cJSON_IsObject(it) ? cJSON_GetObjectItemCaseSensitive(it, "msg") : NULL;
      const char *s = (m && cJSON_IsString(m)) ? m->valuestring : (cJSON_IsString(it) ? it->valuestring : NULL);
      if (!s) continue;
      int w = snprintf(out + used, n > used ? n - used : 0, "%s%s", used ? "; " : "", s);
      if (w < 0) break;
      used += (size_t)w;
      if (used >= n) break;
    }
    if (used) return;
  }
  const cJSON *m = root ? cJSON_GetObjectItemCaseSensitive(root, "message") : NULL;
  if (m && cJSON_IsString(m)) { snprintf(out, n, "%s", m->valuestring); return; }
  if (raw && rawn) {
    size_t k = rawn < 200 ? rawn : 200;
    snprintf(out, n, "%.*s%s", (int)k, raw, rawn > 200 ? "..." : "");
    return;
  }
  snprintf(out, n, "empty response");
}

/* A distribution keyed by option name -> probabilities map + ranked list. */
typedef struct { const char *key; double p; } ranked_ent;

static int cmp_ranked(const void *a, const void *b) {
  const ranked_ent *x = (const ranked_ent *)a, *y = (const ranked_ent *)b;
  if (x->p > y->p) return -1;
  if (x->p < y->p) return 1;
  return strcmp(x->key, y->key); /* ties: stable by name, so tests are deterministic */
}

/* Pushes `probabilities` and `ranked` onto the answer table at -1. When
 * `as_level` the keys are parsed as integer levels (score); otherwise they
 * are option names (choice). */
static void add_distribution(lua_State *L, const cJSON *probs, int as_level) {
  int n = probs ? cJSON_GetArraySize(probs) : 0;
  ranked_ent *ents = n ? (ranked_ent *)calloc((size_t)n, sizeof(ranked_ent)) : NULL;
  int k = 0;
  lua_newtable(L); /* probabilities */
  if (probs) {
    const cJSON *c;
    cJSON_ArrayForEach(c, probs) {
      if (!c->string || !cJSON_IsNumber(c)) continue;
      if (as_level) {
        char *end = NULL;
        long lvl = strtol(c->string, &end, 10);
        if (end && *end == '\0') lua_pushinteger(L, lvl); else lua_pushstring(L, c->string);
      } else {
        lua_pushstring(L, c->string);
      }
      lua_pushnumber(L, c->valuedouble);
      lua_settable(L, -3);
      if (ents) { ents[k].key = c->string; ents[k].p = c->valuedouble; k++; }
    }
  }
  lua_setfield(L, -2, "probabilities");

  if (ents) qsort(ents, (size_t)k, sizeof(ranked_ent), cmp_ranked);
  lua_createtable(L, k, 0); /* ranked */
  for (int i = 0; i < k; i++) {
    lua_createtable(L, 0, 2);
    if (as_level) {
      char *end = NULL;
      long lvl = strtol(ents[i].key, &end, 10);
      if (end && *end == '\0') lua_pushinteger(L, lvl); else lua_pushstring(L, ents[i].key);
      lua_setfield(L, -2, "level");
    } else {
      lua_pushstring(L, ents[i].key);
      lua_setfield(L, -2, "option");
    }
    lua_pushnumber(L, ents[i].p);
    lua_setfield(L, -2, "p");
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "ranked");
  free(ents);
}

static void push_answer(lua_State *L, const cJSON *a) {
  lua_newtable(L);
  const cJSON *t = cJSON_GetObjectItemCaseSensitive(a, "type");
  const char *type = (t && cJSON_IsString(t)) ? t->valuestring : "";
  lua_pushstring(L, type);
  lua_setfield(L, -2, "type");

  if (strcmp(type, "noul") == 0) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(a, "noul");
    lua_pushnumber(L, (v && cJSON_IsNumber(v)) ? v->valuedouble : 0.0);
    lua_setfield(L, -2, "noul");
    return;
  }
  const cJSON *conf = cJSON_GetObjectItemCaseSensitive(a, "confidence");
  if (conf && cJSON_IsNumber(conf)) { lua_pushnumber(L, conf->valuedouble); lua_setfield(L, -2, "confidence"); }

  if (strcmp(type, "choice") == 0) {
    const cJSON *c = cJSON_GetObjectItemCaseSensitive(a, "choice");
    if (c && cJSON_IsString(c)) { lua_pushstring(L, c->valuestring); lua_setfield(L, -2, "choice"); }
    add_distribution(L, cJSON_GetObjectItemCaseSensitive(a, "probabilities"), 0);
    return;
  }
  if (strcmp(type, "score") == 0) {
    const cJSON *s = cJSON_GetObjectItemCaseSensitive(a, "score");
    if (s && cJSON_IsNumber(s)) { lua_pushnumber(L, s->valuedouble); lua_setfield(L, -2, "score"); }
    const cJSON *legend = cJSON_GetObjectItemCaseSensitive(a, "legend");
    lua_newtable(L);
    if (legend && cJSON_IsObject(legend)) {
      const cJSON *c;
      cJSON_ArrayForEach(c, legend) {
        if (!c->string) continue;
        char *end = NULL;
        long lvl = strtol(c->string, &end, 10);
        if (end && *end == '\0') lua_pushinteger(L, lvl); else lua_pushstring(L, c->string);
        push_cjson(L, c);
        lua_settable(L, -3);
      }
    }
    lua_setfield(L, -2, "legend");
    add_distribution(L, cJSON_GetObjectItemCaseSensitive(a, "probabilities"), 1);
    return;
  }
  /* An answer type this file does not know: hand the raw object over rather
   * than drop it, so a new primitive is visible before it is understood. */
  const cJSON *c;
  cJSON_ArrayForEach(c, a) {
    if (!c->string || strcmp(c->string, "type") == 0) continue;
    push_cjson(L, c);
    lua_setfield(L, -2, c->string);
  }
}

static int l_decode(lua_State *L) {
  size_t rawn;
  const char *raw = luaL_checklstring(L, 1, &rawn);
  long status = (long)luaL_optinteger(L, 2, 0);
  char msg[512];

  cJSON *root = cJSON_ParseWithLength(raw, rawn);
  if (status && (status < 200 || status >= 300)) {
    error_message(root, raw, rawn, msg, sizeof(msg));
    cJSON_Delete(root);
    return fail(L, kind_for_status(status), msg, status);
  }
  if (!root) return fail(L, "parse", "response is not valid JSON", status);

  const cJSON *answers = cJSON_GetObjectItemCaseSensitive(root, "answers");
  if (!answers || !cJSON_IsObject(answers)) {
    /* No answers: an error envelope that arrived with a 2xx, or a shape we
     * do not know. Report it as an error either way. */
    error_message(root, raw, rawn, msg, sizeof(msg));
    const char *kind = (cJSON_GetObjectItemCaseSensitive(root, "error")
                        || cJSON_GetObjectItemCaseSensitive(root, "detail")) ? "http" : "parse";
    if (strcmp(kind, "parse") == 0) snprintf(msg, sizeof(msg), "response has no answers");
    cJSON_Delete(root);
    return fail(L, kind, msg, status);
  }

  lua_newtable(L); /* answers */
  const cJSON *a;
  cJSON_ArrayForEach(a, answers) {
    if (!a->string || !cJSON_IsObject(a)) continue;
    push_answer(L, a);
    lua_setfield(L, -2, a->string);
  }

  lua_createtable(L, 0, 2); /* meta */
  const cJSON *model = cJSON_GetObjectItemCaseSensitive(root, "model");
  if (model && cJSON_IsString(model)) { lua_pushstring(L, model->valuestring); lua_setfield(L, -2, "model"); }
  const cJSON *usage = cJSON_GetObjectItemCaseSensitive(root, "usage");
  lua_createtable(L, 0, 2);
  if (usage && cJSON_IsObject(usage)) {
    const cJSON *in = cJSON_GetObjectItemCaseSensitive(usage, "input_tokens");
    const cJSON *out = cJSON_GetObjectItemCaseSensitive(usage, "output_tokens");
    lua_pushinteger(L, (in && cJSON_IsNumber(in)) ? (lua_Integer)in->valuedouble : 0);
    lua_setfield(L, -2, "input_tokens");
    lua_pushinteger(L, (out && cJSON_IsNumber(out)) ? (lua_Integer)out->valuedouble : 0);
    lua_setfield(L, -2, "output_tokens");
  }
  lua_setfield(L, -2, "usage");
  if (status) { lua_pushinteger(L, status); lua_setfield(L, -2, "status"); }

  cJSON_Delete(root);
  return 2;
}

/* ---- module ----------------------------------------------------------------- */
static const luaL_Reg typesafe_lib[] = {
  {"encode", l_encode},
  {"decode", l_decode},
  {"endpoint", l_endpoint},
  {"models_url", l_models_url},
  {"has_key", l_has_key},
  {"limits", l_limits},
  {"error", l_error},
  {NULL, NULL},
};

int luaopen_boggart_typesafe(lua_State *L) {
  if (luaL_newmetatable(L, TS_ERR_META)) {
    lua_pushcfunction(L, err_tostring);
    lua_setfield(L, -2, "__tostring");
  }
  lua_pop(L, 1);
  luaL_newlib(L, typesafe_lib);
  lua_pushliteral(L, TS_SLOT);          lua_setfield(L, -2, "SLOT");
  lua_pushliteral(L, TS_DEFAULT_MODEL); lua_setfield(L, -2, "DEFAULT_MODEL");
  return 1;
}
