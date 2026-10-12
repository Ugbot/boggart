/* ljson.c -- JSON encode/decode and UTF-8 repair in C (BOG-12).
 *
 * lua/json.lua (pure Lua) measured 41 ms to encode and 126 ms to decode a
 * 2.4 MB transcript, and boggart does both on every turn and every model
 * round -- so a long session paid it quadratically. This is a drop-in for the
 * same functions with the SAME output, byte for byte, because the encoder's
 * output is a cache key (prompt caching) and the canonical JSONL mirrors are
 * committed to git:
 *
 *   * objects: keys sorted by tostring(key) (memcmp order -- the C locale);
 *     a table is an array iff its keys are exactly 1..n (n > 0); json.array
 *     encodes [], json.null and nil encode null;
 *   * numbers: integers as %lld, floats as %.14g, non-finite is an error;
 *   * strings: escape ", \, \b \f \n \r \t, other bytes < 0x20 as \u00xx;
 *     bytes >= 0x80 pass through (to_valid_utf8 is the separate scrub);
 *   * decode: the same number grammar (-?\d+\.?\d*[eE]?[+-]?\d* then
 *     lua_stringtonumber, so "1" is an integer and "1.0" a float, exactly as
 *     tonumber), the same escapes, lone surrogates -> U+FFFD, null ->
 *     json.null, raw control bytes inside strings accepted, the same error
 *     messages ("json decode error at <pos>: <what>").
 *
 * Why not the vendored cJSON: it holds every number as a double (no Lua
 * integer/float distinction, big integers rounded) and builds a tree that would
 * then be copied into Lua tables; this writes Lua values directly.
 *
 * Buffers are owned by a userdata with __gc, so an error raised mid-way (a
 * cycle, a function value, a metamethod that throws) frees them rather than
 * leaking -- and nothing here holds a luaL_Buffer across Lua calls (the
 * 2026-09-28 crash class).
 *
 * Lua API (module json_c, wired in by lua/json.lua):
 *   json_c.setup(null, array)      the sentinel tables
 *   json_c.encode(v) -> string
 *   json_c.decode(s) -> value
 *   json_c.to_valid_utf8(s) -> s   (same rules as util.to_valid_utf8)
 *   json_c.utf8_safe_len(s) -> n   bytes of s that end on a complete character
 */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include "lua.h"
#include "lauxlib.h"

#define MAX_DEPTH 1000

/* ---- the owned buffer -------------------------------------------------------------- */
typedef struct { char *p; size_t n, cap; } jbuf;

static int jbuf_gc(lua_State *L) {
  jbuf *b = (jbuf *)luaL_checkudata(L, 1, "boggart.jbuf");
  free(b->p); b->p = NULL; b->n = b->cap = 0;
  return 0;
}

static jbuf *jbuf_new(lua_State *L) {
  jbuf *b = (jbuf *)lua_newuserdatauv(L, sizeof(jbuf), 0);
  b->p = NULL; b->n = b->cap = 0;
  luaL_setmetatable(L, "boggart.jbuf");
  return b;
}

static void jbuf_grow(lua_State *L, jbuf *b, size_t need) {
  if (b->n + need <= b->cap) return;
  size_t cap = b->cap ? b->cap : 4096;
  while (cap < b->n + need) cap *= 2;
  char *np = (char *)realloc(b->p, cap);
  if (!np) luaL_error(L, "json: out of memory");
  b->p = np; b->cap = cap;
}
static void jbuf_add(lua_State *L, jbuf *b, const char *s, size_t n) {
  jbuf_grow(L, b, n);
  memcpy(b->p + b->n, s, n);
  b->n += n;
}
static void jbuf_ch(lua_State *L, jbuf *b, char c) { jbuf_grow(L, b, 1); b->p[b->n++] = c; }

/* ---- sentinels -------------------------------------------------------------------------- */
static const char *K_NULL = "boggart.json.null";
static const char *K_ARRAY = "boggart.json.array";

static int l_setup(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_pushvalue(L, 1); lua_setfield(L, LUA_REGISTRYINDEX, K_NULL);
  lua_pushvalue(L, 2); lua_setfield(L, LUA_REGISTRYINDEX, K_ARRAY);
  return 0;
}

static int is_sentinel(lua_State *L, int idx, const char *key) {
  idx = lua_absindex(L, idx);
  lua_getfield(L, LUA_REGISTRYINDEX, key);
  int eq = lua_rawequal(L, idx, -1);
  lua_pop(L, 1);
  return eq;
}

/* ---- encode ------------------------------------------------------------------------------ */
static void enc_string(lua_State *L, jbuf *b, const char *s, size_t n) {
  static const char *hex = "0123456789abcdef";
  jbuf_ch(L, b, '"');
  size_t run = 0;
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c >= 0x20 && c != '"' && c != '\\') { run++; continue; }
    if (run) { jbuf_add(L, b, s + i - run, run); run = 0; }
    char e[6];
    switch (c) {
      case '"':  jbuf_add(L, b, "\\\"", 2); break;
      case '\\': jbuf_add(L, b, "\\\\", 2); break;
      case '\b': jbuf_add(L, b, "\\b", 2); break;
      case '\f': jbuf_add(L, b, "\\f", 2); break;
      case '\n': jbuf_add(L, b, "\\n", 2); break;
      case '\r': jbuf_add(L, b, "\\r", 2); break;
      case '\t': jbuf_add(L, b, "\\t", 2); break;
      default:
        e[0] = '\\'; e[1] = 'u'; e[2] = '0'; e[3] = '0'; e[4] = hex[c >> 4]; e[5] = hex[c & 15];
        jbuf_add(L, b, e, 6);
    }
  }
  if (run) jbuf_add(L, b, s + n - run, run);
  jbuf_ch(L, b, '"');
}

/* tostring(k) of a key, pushed; -> its bytes */
static const char *key_text(lua_State *L, int kidx, size_t *len) {
  return luaL_tolstring(L, kidx, len);   /* pushes */
}

typedef struct { const char *s; size_t n; int slot; } keyent;
static int keycmp(const void *a, const void *b) {
  const keyent *x = (const keyent *)a, *y = (const keyent *)b;
  size_t m = x->n < y->n ? x->n : y->n;
  int c = memcmp(x->s, y->s, m);
  if (c) return c;
  return (x->n > y->n) - (x->n < y->n);
}

static void encode(lua_State *L, jbuf *b, int idx, int depth);

static void enc_table(lua_State *L, jbuf *b, int idx, int depth) {
  if (is_sentinel(L, idx, K_ARRAY)) { jbuf_add(L, b, "[]", 2); return; }
  luaL_checkstack(L, 8, "json: nesting");
  /* is_array: n = count of keys, and t[1..n] all present */
  lua_Integer n = 0;
  lua_pushnil(L);
  while (lua_next(L, idx)) { n++; lua_pop(L, 1); }
  int arr = n > 0;
  for (lua_Integer i = 1; arr && i <= n; i++) {
    if (lua_geti(L, idx, i) == LUA_TNIL) arr = 0;
    lua_pop(L, 1);
  }
  if (arr) {
    lua_Integer len = luaL_len(L, idx);
    jbuf_ch(L, b, '[');
    for (lua_Integer i = 1; i <= len; i++) {
      if (i > 1) jbuf_ch(L, b, ',');
      lua_geti(L, idx, i);
      encode(L, b, lua_gettop(L), depth + 1);
      lua_pop(L, 1);
    }
    jbuf_ch(L, b, ']');
    return;
  }
  /* object: keys sorted by their tostring text. The texts (and the keys) are
   * kept alive in a scratch table on the stack while we sort pointers to them. */
  lua_createtable(L, (int)n * 2, 0);           /* scratch: [2i-1]=key, [2i]=text */
  int scratch = lua_gettop(L);
  keyent *ks = (keyent *)lua_newuserdatauv(L, sizeof(keyent) * (size_t)(n ? n : 1), 0);
  lua_Integer k = 0;
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    lua_pop(L, 1);                             /* value */
    k++;
    lua_pushvalue(L, -1); lua_rawseti(L, scratch, 2 * k - 1);
    size_t tl;
    const char *t = key_text(L, -1, &tl);       /* pushes text */
    lua_rawseti(L, scratch, 2 * k);             /* keep it alive */
    lua_rawgeti(L, scratch, 2 * k);
    ks[k - 1].s = lua_tolstring(L, -1, &ks[k - 1].n);
    (void)t; (void)tl;
    lua_pop(L, 1);
    ks[k - 1].slot = (int)k;
  }
  qsort(ks, (size_t)k, sizeof(keyent), keycmp);
  jbuf_ch(L, b, '{');
  for (lua_Integer i = 0; i < k; i++) {
    if (i) jbuf_ch(L, b, ',');
    enc_string(L, b, ks[i].s, ks[i].n);
    jbuf_ch(L, b, ':');
    lua_rawgeti(L, scratch, 2 * ks[i].slot - 1);   /* the key */
    lua_gettable(L, idx);                           /* v[k] */
    encode(L, b, lua_gettop(L), depth + 1);
    lua_pop(L, 1);
  }
  jbuf_ch(L, b, '}');
  lua_pop(L, 2);   /* keyent userdata, scratch */
}

static void encode(lua_State *L, jbuf *b, int idx, int depth) {
  if (depth > MAX_DEPTH) luaL_error(L, "json: cannot encode: nesting deeper than %d (a cycle?)", MAX_DEPTH);
  switch (lua_type(L, idx)) {
    case LUA_TNIL: jbuf_add(L, b, "null", 4); return;
    case LUA_TBOOLEAN: if (lua_toboolean(L, idx)) jbuf_add(L, b, "true", 4); else jbuf_add(L, b, "false", 5); return;
    case LUA_TNUMBER: {
      char num[64];
      int len;
      if (lua_isinteger(L, idx)) {
        len = snprintf(num, sizeof(num), LUA_INTEGER_FMT, (LUAI_UACINT)lua_tointeger(L, idx));
      } else {
        lua_Number d = lua_tonumber(L, idx);
        if (d != d || d == HUGE_VAL || d == -HUGE_VAL) luaL_error(L, "json: cannot encode non-finite number");
        len = snprintf(num, sizeof(num), "%.14g", (double)d);
      }
      jbuf_add(L, b, num, (size_t)len);
      return;
    }
    case LUA_TSTRING: {
      size_t n;
      const char *s = lua_tolstring(L, idx, &n);
      enc_string(L, b, s, n);
      return;
    }
    case LUA_TTABLE:
      if (is_sentinel(L, idx, K_NULL)) { jbuf_add(L, b, "null", 4); return; }
      enc_table(L, b, lua_absindex(L, idx), depth);
      return;
    default:
      luaL_error(L, "json: cannot encode %s", luaL_typename(L, idx));
  }
}

static int l_encode(lua_State *L) {
  lua_settop(L, 1);
  jbuf *b = jbuf_new(L);                 /* index 2: freed by __gc on any error */
  encode(L, b, 1, 0);
  lua_pushlstring(L, b->p ? b->p : "", b->n);
  free(b->p); b->p = NULL; b->n = b->cap = 0;
  return 1;
}

/* ---- decode ------------------------------------------------------------------------------ */
typedef struct { const char *s; size_t n, i; lua_State *L; jbuf *scratch; } dec;

static int dec_err(dec *d, const char *what) {
  return luaL_error(d->L, "json decode error at %d: %s", (int)(d->i + 1), what);
}

static void skip_ws(dec *d) {
  while (d->i < d->n) {
    char c = d->s[d->i];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') d->i++; else break;
  }
}

static int hex4(const char *p, unsigned *out) {
  unsigned v = 0;
  for (int k = 0; k < 4; k++) {
    char c = p[k];
    v <<= 4;
    if (c >= '0' && c <= '9') v |= (unsigned)(c - '0');
    else if (c >= 'a' && c <= 'f') v |= (unsigned)(c - 'a' + 10);
    else if (c >= 'A' && c <= 'F') v |= (unsigned)(c - 'A' + 10);
    else return 0;
  }
  *out = v;
  return 1;
}

static void put_utf8(lua_State *L, jbuf *b, unsigned n) {
  char u[4];
  if (n < 0x80) { u[0] = (char)n; jbuf_add(L, b, u, 1); }
  else if (n < 0x800) { u[0] = (char)(0xC0 | (n >> 6)); u[1] = (char)(0x80 | (n & 0x3F)); jbuf_add(L, b, u, 2); }
  else if (n < 0x10000) { u[0] = (char)(0xE0 | (n >> 12)); u[1] = (char)(0x80 | ((n >> 6) & 0x3F)); u[2] = (char)(0x80 | (n & 0x3F)); jbuf_add(L, b, u, 3); }
  else { u[0] = (char)(0xF0 | (n >> 18)); u[1] = (char)(0x80 | ((n >> 12) & 0x3F)); u[2] = (char)(0x80 | ((n >> 6) & 0x3F)); u[3] = (char)(0x80 | (n & 0x3F)); jbuf_add(L, b, u, 4); }
}

/* at the opening quote; pushes the string */
static void dec_string(dec *d) {
  size_t start = ++d->i;
  /* fast path: no escapes -> push the slice directly */
  size_t j = start;
  while (j < d->n && d->s[j] != '"' && d->s[j] != '\\') j++;
  if (j < d->n && d->s[j] == '"') {
    lua_pushlstring(d->L, d->s + start, j - start);
    d->i = j + 1;
    return;
  }
  jbuf *b = d->scratch;
  b->n = 0;
  jbuf_add(d->L, b, d->s + start, j - start);
  d->i = j;
  for (;;) {
    if (d->i >= d->n) { d->i = d->n; dec_err(d, "unterminated string"); }
    char c = d->s[d->i];
    if (c == '"') { d->i++; break; }
    if (c != '\\') {
      size_t k = d->i;
      while (k < d->n && d->s[k] != '"' && d->s[k] != '\\') k++;
      jbuf_add(d->L, b, d->s + d->i, k - d->i);
      d->i = k;
      continue;
    }
    if (d->i + 1 >= d->n) { dec_err(d, "bad escape \\"); }
    char e = d->s[d->i + 1];
    switch (e) {
      case '"': jbuf_ch(d->L, b, '"'); d->i += 2; break;
      case '\\': jbuf_ch(d->L, b, '\\'); d->i += 2; break;
      case '/': jbuf_ch(d->L, b, '/'); d->i += 2; break;
      case 'b': jbuf_ch(d->L, b, '\b'); d->i += 2; break;
      case 'f': jbuf_ch(d->L, b, '\f'); d->i += 2; break;
      case 'n': jbuf_ch(d->L, b, '\n'); d->i += 2; break;
      case 'r': jbuf_ch(d->L, b, '\r'); d->i += 2; break;
      case 't': jbuf_ch(d->L, b, '\t'); d->i += 2; break;
      case 'u': {
        unsigned n;
        if (d->i + 6 > d->n || !hex4(d->s + d->i + 2, &n)) dec_err(d, "bad \\u escape");
        if (n >= 0xD800 && n <= 0xDBFF) {
          unsigned n2;
          if (d->i + 12 <= d->n && d->s[d->i + 6] == '\\' && d->s[d->i + 7] == 'u'
              && hex4(d->s + d->i + 8, &n2) && n2 >= 0xDC00 && n2 <= 0xDFFF) {
            n = 0x10000 + (n - 0xD800) * 0x400 + (n2 - 0xDC00);
            d->i += 6;
          } else {
            n = 0xFFFD;   /* lone high surrogate */
          }
        } else if (n >= 0xDC00 && n <= 0xDFFF) {
          n = 0xFFFD;     /* lone low surrogate */
        }
        put_utf8(d->L, b, n);
        d->i += 6;
        break;
      }
      default: {
        char msg[32];
        snprintf(msg, sizeof(msg), "bad escape \\%c", e);
        dec_err(d, msg);
      }
    }
  }
  lua_pushlstring(d->L, b->p ? b->p : "", b->n);
}

static void dec_number(dec *d) {
  /* -?\d+\.?\d*[eE]?[+-]?\d*  -- json.lua's grammar, then tonumber */
  size_t i = d->i, st = i;
  if (i < d->n && d->s[i] == '-') i++;
  size_t dig = i;
  while (i < d->n && d->s[i] >= '0' && d->s[i] <= '9') i++;
  if (i == dig) dec_err(d, "bad number");
  if (i < d->n && d->s[i] == '.') i++;
  while (i < d->n && d->s[i] >= '0' && d->s[i] <= '9') i++;
  if (i < d->n && (d->s[i] == 'e' || d->s[i] == 'E')) i++;
  if (i < d->n && (d->s[i] == '+' || d->s[i] == '-')) i++;
  while (i < d->n && d->s[i] >= '0' && d->s[i] <= '9') i++;
  char tmp[128];
  size_t len = i - st;
  if (len >= sizeof(tmp)) {
    /* very long numerals: fall back to a heap copy */
    char *h = (char *)malloc(len + 1);
    if (!h) luaL_error(d->L, "json: out of memory");
    memcpy(h, d->s + st, len); h[len] = '\0';
    size_t ok = lua_stringtonumber(d->L, h);
    free(h);
    if (!ok) dec_err(d, "bad number");
  } else {
    memcpy(tmp, d->s + st, len); tmp[len] = '\0';
    if (!lua_stringtonumber(d->L, tmp)) {
      char msg[160];
      snprintf(msg, sizeof(msg), "bad number %s", tmp);
      dec_err(d, msg);
    }
  }
  d->i = i;
}

static void dec_value(dec *d, int depth) {
  if (depth > MAX_DEPTH) dec_err(d, "nesting too deep");
  skip_ws(d);
  if (d->i >= d->n) { dec_number(d); return; }   /* json.lua: falls to "bad number" at end */
  char c = d->s[d->i];
  lua_State *L = d->L;
  if (c == '{') {
    luaL_checkstack(L, 4, "json: nesting");
    lua_newtable(L);
    d->i++;
    skip_ws(d);
    if (d->i < d->n && d->s[d->i] == '}') { d->i++; return; }
    for (;;) {
      skip_ws(d);
      if (d->i >= d->n || d->s[d->i] != '"') dec_err(d, "expected key string");
      dec_string(d);
      skip_ws(d);
      if (d->i >= d->n || d->s[d->i] != ':') dec_err(d, "expected ':'");
      d->i++;
      dec_value(d, depth + 1);
      lua_rawset(L, -3);
      skip_ws(d);
      if (d->i < d->n && d->s[d->i] == ',') { d->i++; continue; }
      if (d->i < d->n && d->s[d->i] == '}') { d->i++; return; }
      dec_err(d, "expected ',' or '}'");
    }
  } else if (c == '[') {
    luaL_checkstack(L, 4, "json: nesting");
    lua_newtable(L);
    d->i++;
    skip_ws(d);
    if (d->i < d->n && d->s[d->i] == ']') { d->i++; return; }
    lua_Integer n = 0;
    for (;;) {
      dec_value(d, depth + 1);
      lua_rawseti(L, -2, ++n);
      skip_ws(d);
      if (d->i < d->n && d->s[d->i] == ',') { d->i++; continue; }
      if (d->i < d->n && d->s[d->i] == ']') { d->i++; return; }
      dec_err(d, "expected ',' or ']'");
    }
  } else if (c == '"') {
    dec_string(d);
  } else if (c == 't') {
    if (d->i + 4 <= d->n && memcmp(d->s + d->i, "true", 4) == 0) { lua_pushboolean(L, 1); d->i += 4; return; }
    dec_err(d, "invalid literal");
  } else if (c == 'f') {
    if (d->i + 5 <= d->n && memcmp(d->s + d->i, "false", 5) == 0) { lua_pushboolean(L, 0); d->i += 5; return; }
    dec_err(d, "invalid literal");
  } else if (c == 'n') {
    if (d->i + 4 <= d->n && memcmp(d->s + d->i, "null", 4) == 0) {
      lua_getfield(L, LUA_REGISTRYINDEX, K_NULL);
      d->i += 4;
      return;
    }
    dec_err(d, "invalid literal");
  } else {
    dec_number(d);
  }
}

static int l_decode(lua_State *L) {
  size_t n;
  const char *s = luaL_checklstring(L, 1, &n);
  lua_settop(L, 1);
  dec d = { s, n, 0, L, jbuf_new(L) };       /* scratch at index 2, __gc frees it */
  dec_value(&d, 0);
  skip_ws(&d);
  if (d.i < d.n) dec_err(&d, "trailing garbage");
  free(d.scratch->p); d.scratch->p = NULL; d.scratch->n = d.scratch->cap = 0;
  return 1;
}

/* ---- UTF-8 ----------------------------------------------------------------------------- */
/* Length of a well-formed sequence at p (Unicode Table 3-7), or 0 if ill-formed
 * or incomplete within avail. *incomplete is set when it is a valid PREFIX cut
 * short by the end of the buffer. */
static size_t utf8_seq(const unsigned char *p, size_t avail, int *incomplete) {
  unsigned c = p[0];
  *incomplete = 0;
  if (c < 0x80) return 1;
  size_t len; unsigned lo = 0x80, hi = 0xBF;
  if (c >= 0xC2 && c <= 0xDF) len = 2;
  else if (c == 0xE0) { len = 3; lo = 0xA0; }
  else if ((c >= 0xE1 && c <= 0xEC) || c == 0xEE || c == 0xEF) len = 3;
  else if (c == 0xED) { len = 3; hi = 0x9F; }
  else if (c == 0xF0) { len = 4; lo = 0x90; }
  else if (c >= 0xF1 && c <= 0xF3) len = 4;
  else if (c == 0xF4) { len = 4; hi = 0x8F; }
  else return 0;
  for (size_t k = 1; k < len; k++) {
    if (k >= avail) { *incomplete = 1; return 0; }
    unsigned b = p[k];
    unsigned l = (k == 1) ? lo : 0x80, h = (k == 1) ? hi : 0xBF;
    if (b < l || b > h) return 0;
  }
  return len;
}

static int l_to_valid_utf8(lua_State *L) {
  if (lua_type(L, 1) != LUA_TSTRING) { lua_settop(L, 1); return 1; }
  size_t n;
  const unsigned char *s = (const unsigned char *)lua_tolstring(L, 1, &n);
  /* fast scan: valid input is returned as the very same string */
  size_t i = 0;
  int inc;
  while (i < n) {
    if (s[i] < 0x80) { i++; continue; }
    size_t l = utf8_seq(s + i, n - i, &inc);
    if (!l) break;
    i += l;
  }
  if (i == n) { lua_settop(L, 1); return 1; }
  lua_settop(L, 1);
  jbuf *b = jbuf_new(L);
  jbuf_add(L, b, (const char *)s, i);
  while (i < n) {
    if (s[i] < 0x80) { jbuf_ch(L, b, (char)s[i]); i++; continue; }
    size_t l = utf8_seq(s + i, n - i, &inc);
    if (l) { jbuf_add(L, b, (const char *)s + i, l); i += l; }
    else { jbuf_add(L, b, "\xEF\xBF\xBD", 3); i++; }   /* one bad byte -> one U+FFFD */
  }
  lua_pushlstring(L, b->p, b->n);
  free(b->p); b->p = NULL; b->n = b->cap = 0;
  return 1;
}

/* How many leading bytes end on a complete character: a stream chunk that
 * stops mid-character keeps its tail for the next chunk instead of having it
 * scrubbed to U+FFFD (after ds4's utf8_stream_safe_len). Ill-formed bytes are
 * NOT held back -- only a valid prefix cut short by the end. */
static int l_utf8_safe_len(lua_State *L) {
  size_t n;
  const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
  size_t start = n > 3 ? n - 3 : 0;
  for (size_t i = n; i > start; i--) {
    size_t p = i - 1;
    if ((s[p] & 0xC0) == 0x80) continue;          /* continuation: keep looking for the lead */
    if (s[p] < 0x80) break;                       /* ASCII: everything is complete */
    int inc;
    size_t l = utf8_seq(s + p, n - p, &inc);
    if (!l && inc) { lua_pushinteger(L, (lua_Integer)p); return 1; }
    break;
  }
  lua_pushinteger(L, (lua_Integer)n);
  return 1;
}

static const luaL_Reg json_c[] = {
  { "setup", l_setup }, { "encode", l_encode }, { "decode", l_decode },
  { "to_valid_utf8", l_to_valid_utf8 }, { "utf8_safe_len", l_utf8_safe_len },
  { NULL, NULL },
};

int luaopen_boggart_json(lua_State *L) {
  if (luaL_newmetatable(L, "boggart.jbuf")) {
    lua_pushcfunction(L, jbuf_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
  luaL_newlib(L, json_c);
  return 1;
}
