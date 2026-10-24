/* bmsgpack.c -- see bmsgpack.h. No libzmq, no libuv: compiled into every
 * build so the codecs are testable headlessly. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include <lua.h>
#include <lauxlib.h>
#include "bmsgpack.h"

/* ---- writer ------------------------------------------------------------- */

void bmp_bytes(bmp_buf *o, const void *p, size_t n) {
  if (o->oom) return;
  if (o->n + n > o->cap) {
    size_t cap = o->cap ? o->cap : 256;
    while (cap < o->n + n) cap *= 2;
    char *np = (char *)realloc(o->p, cap);
    if (!np) { o->oom = 1; return; }
    o->p = np; o->cap = cap;
  }
  memcpy(o->p + o->n, p, n);
  o->n += n;
}

void bmp_u8(bmp_buf *o, unsigned char c) { bmp_bytes(o, &c, 1); }

static void be16(bmp_buf *o, unsigned v) {
  bmp_u8(o, (unsigned char)(v >> 8)); bmp_u8(o, (unsigned char)v);
}
static void be32(bmp_buf *o, uint32_t v) {
  bmp_u8(o, (unsigned char)(v >> 24)); bmp_u8(o, (unsigned char)(v >> 16));
  bmp_u8(o, (unsigned char)(v >> 8));  bmp_u8(o, (unsigned char)v);
}
static void be64(bmp_buf *o, uint64_t v) {
  be32(o, (uint32_t)(v >> 32)); be32(o, (uint32_t)v);
}

void bmp_str(bmp_buf *o, const char *s, size_t n) {
  if (n < 32) bmp_u8(o, (unsigned char)(0xa0 | n));
  else if (n < 256) { bmp_u8(o, 0xd9); bmp_u8(o, (unsigned char)n); }
  else if (n < 65536) { bmp_u8(o, 0xda); be16(o, (unsigned)n); }
  else { bmp_u8(o, 0xdb); be32(o, (uint32_t)n); }
  bmp_bytes(o, s, n);
}

void bmp_bin(bmp_buf *o, const char *s, size_t n) {
  if (n < 256) { bmp_u8(o, 0xc4); bmp_u8(o, (unsigned char)n); }
  else if (n < 65536) { bmp_u8(o, 0xc5); be16(o, (unsigned)n); }
  else { bmp_u8(o, 0xc6); be32(o, (uint32_t)n); }
  bmp_bytes(o, s, n);
}

void bmp_map_header(bmp_buf *o, size_t n) {
  if (n < 16) bmp_u8(o, (unsigned char)(0x80 | n));
  else if (n < 65536) { bmp_u8(o, 0xde); be16(o, (unsigned)n); }
  else { bmp_u8(o, 0xdf); be32(o, (uint32_t)n); }
}

void bmp_array_header(bmp_buf *o, size_t n) {
  if (n < 16) bmp_u8(o, (unsigned char)(0x90 | n));
  else if (n < 65536) { bmp_u8(o, 0xdc); be16(o, (unsigned)n); }
  else { bmp_u8(o, 0xdd); be32(o, (uint32_t)n); }
}

void bmp_int(bmp_buf *o, int64_t v) {
  if (v >= 0) {
    if (v < 0x80) bmp_u8(o, (unsigned char)v);
    else if (v < 0x100) { bmp_u8(o, 0xcc); bmp_u8(o, (unsigned char)v); }
    else if (v < 0x10000) { bmp_u8(o, 0xcd); be16(o, (unsigned)v); }
    else if (v < 0x100000000LL) { bmp_u8(o, 0xce); be32(o, (uint32_t)v); }
    else { bmp_u8(o, 0xcf); be64(o, (uint64_t)v); }
  } else {
    if (v >= -32) bmp_u8(o, (unsigned char)(0x100 + v));
    else if (v >= -0x80) { bmp_u8(o, 0xd0); bmp_u8(o, (unsigned char)(int8_t)v); }
    else if (v >= -0x8000) { bmp_u8(o, 0xd1); be16(o, (unsigned)(uint16_t)(int16_t)v); }
    else if (v >= -0x80000000LL) { bmp_u8(o, 0xd2); be32(o, (uint32_t)(int32_t)v); }
    else { bmp_u8(o, 0xd3); be64(o, (uint64_t)v); }
  }
}

void bmp_double(bmp_buf *o, double v) {
  uint64_t bits;
  memcpy(&bits, &v, sizeof bits);
  bmp_u8(o, 0xcb);
  be64(o, bits);
}

void bmp_nil(bmp_buf *o) { bmp_u8(o, 0xc0); }
void bmp_bool(bmp_buf *o, int v) { bmp_u8(o, v ? 0xc3 : 0xc2); }
void bmp_free(bmp_buf *o) { free(o->p); o->p = NULL; o->n = o->cap = 0; }

/* ---- reader ------------------------------------------------------------- */

int bmp_rd_need(bmp_cur *c, size_t n) { return (size_t)(c->end - c->p) >= n; }

static uint32_t rd_be(const unsigned char *p, int n) {
  uint32_t v = 0;
  for (int i = 0; i < n; i++) v = (v << 8) | p[i];
  return v;
}

int bmp_rd_str(bmp_cur *c, const char **s, size_t *n) {
  if (!bmp_rd_need(c, 1)) return 0;
  unsigned char t = *c->p;
  size_t len;
  if ((t & 0xe0) == 0xa0) { len = t & 0x1f; c->p += 1; }
  else if (t == 0xd9) { if (!bmp_rd_need(c, 2)) return 0; len = c->p[1]; c->p += 2; }
  else if (t == 0xda) { if (!bmp_rd_need(c, 3)) return 0; len = rd_be(c->p + 1, 2); c->p += 3; }
  else if (t == 0xdb) { if (!bmp_rd_need(c, 5)) return 0; len = rd_be(c->p + 1, 4); c->p += 5; }
  else return 0;
  if (!bmp_rd_need(c, len)) return 0;
  *s = (const char *)c->p; *n = len; c->p += len;
  return 1;
}

int bmp_rd_map_header(bmp_cur *c, size_t *n) {
  if (!bmp_rd_need(c, 1)) return 0;
  unsigned char t = *c->p;
  if ((t & 0xf0) == 0x80) { *n = t & 0x0f; c->p += 1; return 1; }
  if (t == 0xde) { if (!bmp_rd_need(c, 3)) return 0; *n = rd_be(c->p + 1, 2); c->p += 3; return 1; }
  if (t == 0xdf) { if (!bmp_rd_need(c, 5)) return 0; *n = rd_be(c->p + 1, 4); c->p += 5; return 1; }
  return 0;
}

int bmp_rd_skip(bmp_cur *c, int depth) {
  if (depth > 8 || !bmp_rd_need(c, 1)) return 0;
  unsigned char t = *c->p;
  const char *s; size_t n;
  if ((t & 0xe0) == 0xa0 || t == 0xd9 || t == 0xda || t == 0xdb)
    return bmp_rd_str(c, &s, &n);
  if ((t & 0xf0) == 0x80 || t == 0xde || t == 0xdf) {
    if (!bmp_rd_map_header(c, &n)) return 0;
    for (size_t i = 0; i < n * 2; i++)
      if (!bmp_rd_skip(c, depth + 1)) return 0;
    return 1;
  }
  if ((t & 0xf0) == 0x90 || t == 0xdc || t == 0xdd) { /* arrays */
    size_t cnt;
    if ((t & 0xf0) == 0x90) { cnt = t & 0x0f; c->p += 1; }
    else if (t == 0xdc) { if (!bmp_rd_need(c, 3)) return 0; cnt = rd_be(c->p + 1, 2); c->p += 3; }
    else { if (!bmp_rd_need(c, 5)) return 0; cnt = rd_be(c->p + 1, 4); c->p += 5; }
    for (size_t i = 0; i < cnt; i++)
      if (!bmp_rd_skip(c, depth + 1)) return 0;
    return 1;
  }
  if (t <= 0x7f || t >= 0xe0) { c->p += 1; return 1; }           /* fixint */
  if (t == 0xc0 || t == 0xc2 || t == 0xc3) { c->p += 1; return 1; } /* nil/bool */
  switch (t) { /* sized scalars and bins */
    case 0xcc: case 0xd0: n = 2; break;
    case 0xcd: case 0xd1: n = 3; break;
    case 0xce: case 0xd2: case 0xca: n = 5; break;
    case 0xcf: case 0xd3: case 0xcb: n = 9; break;
    case 0xc4: if (!bmp_rd_need(c, 2)) return 0; n = 2 + c->p[1]; break;
    case 0xc5: if (!bmp_rd_need(c, 3)) return 0; n = 3 + rd_be(c->p + 1, 2); break;
    default: return 0;
  }
  if (!bmp_rd_need(c, n)) return 0;
  c->p += n;
  return 1;
}

/* ---- generic encode ----------------------------------------------------- */

#define BMP_MAX_DEPTH 64

typedef struct { const char *s; size_t n; lua_Integer i; int is_int; } mkey;

static int mkey_cmp(const void *a, const void *b) {
  const mkey *x = (const mkey *)a, *y = (const mkey *)b;
  size_t m = x->n < y->n ? x->n : y->n;
  int c = memcmp(x->s, y->s, m);
  if (c) return c;
  return (x->n > y->n) - (x->n < y->n);
}

static int same_slot(lua_State *L, int idx, int sentinel) {
  return sentinel && lua_rawequal(L, idx, sentinel);
}

static int pack_value(lua_State *L, int idx, bmp_buf *o, int null_idx,
                      int array_idx, int depth, const char **err);

static int pack_table(lua_State *L, int t, bmp_buf *o, int null_idx,
                      int array_idx, int depth, const char **err) {
  if (same_slot(L, t, array_idx)) { bmp_array_header(o, 0); return 1; }
  /* count keys and check for a 1..n sequence */
  size_t count = 0;
  int seq = 1;
  lua_pushnil(L);
  while (lua_next(L, t)) {
    count++;
    if (!lua_isinteger(L, -2)) seq = 0;
    lua_pop(L, 1);
  }
  if (count > 0 && seq) {
    for (size_t i = 1; i <= count; i++) {
      if (lua_rawgeti(L, t, (lua_Integer)i) == LUA_TNIL) seq = 0;
      lua_pop(L, 1);
      if (!seq) break;
    }
  }
  if (count > 0 && seq) {
    bmp_array_header(o, count);
    for (size_t i = 1; i <= count; i++) {
      lua_rawgeti(L, t, (lua_Integer)i);
      int ok = pack_value(L, lua_gettop(L), o, null_idx, array_idx, depth + 1, err);
      lua_pop(L, 1);
      if (!ok) return 0;
    }
    return 1;
  }
  /* a map: collect keys (as text for sorting), sort, emit */
  mkey *keys = count ? (mkey *)malloc(count * sizeof(mkey)) : NULL;
  char (*nums)[32] = count ? malloc(count * 32) : NULL;
  if (count && (!keys || !nums)) { free(keys); free(nums); *err = "out of memory"; return 0; }
  size_t k = 0;
  lua_pushnil(L);
  while (lua_next(L, t)) {
    lua_pop(L, 1);
    if (k >= count) continue; /* cannot happen: the table is not mutated here */
    if (lua_type(L, -1) == LUA_TSTRING) {
      keys[k].s = lua_tolstring(L, -1, &keys[k].n); /* anchored by the table */
      keys[k].is_int = 0;
    } else if (lua_isinteger(L, -1)) {
      lua_Integer iv = lua_tointeger(L, -1);
      snprintf(nums[k], 32, "%lld", (long long)iv);
      keys[k].s = nums[k]; keys[k].n = strlen(nums[k]);
      keys[k].i = iv; keys[k].is_int = 1;
    } else {
      lua_pop(L, 1);
      free(keys); free(nums);
      *err = "map keys must be strings or integers";
      return 0;
    }
    k++;
  }
  qsort(keys, k, sizeof(mkey), mkey_cmp);
  bmp_map_header(o, k);
  int ok = 1;
  for (size_t i = 0; i < k && ok; i++) {
    bmp_str(o, keys[i].s, keys[i].n);
    if (keys[i].is_int) lua_pushinteger(L, keys[i].i);
    else lua_pushlstring(L, keys[i].s, keys[i].n);
    lua_rawget(L, t);
    ok = pack_value(L, lua_gettop(L), o, null_idx, array_idx, depth + 1, err);
    lua_pop(L, 1);
  }
  free(keys); free(nums);
  return ok;
}

static int pack_value(lua_State *L, int idx, bmp_buf *o, int null_idx,
                      int array_idx, int depth, const char **err) {
  if (depth > BMP_MAX_DEPTH) { *err = "nesting too deep"; return 0; }
  if (!lua_checkstack(L, 8)) { *err = "stack overflow"; return 0; }
  switch (lua_type(L, idx)) {
    case LUA_TNIL: case LUA_TNONE: bmp_nil(o); return 1;
    case LUA_TBOOLEAN: bmp_bool(o, lua_toboolean(L, idx)); return 1;
    case LUA_TNUMBER:
      if (lua_isinteger(L, idx)) bmp_int(o, (int64_t)lua_tointeger(L, idx));
      else bmp_double(o, (double)lua_tonumber(L, idx));
      return 1;
    case LUA_TSTRING: {
      size_t n; const char *s = lua_tolstring(L, idx, &n);
      bmp_str(o, s, n);
      return 1;
    }
    case LUA_TTABLE:
      if (same_slot(L, idx, null_idx)) { bmp_nil(o); return 1; }
      return pack_table(L, idx, o, null_idx, array_idx, depth, err);
    default:
      *err = "cannot encode a value of this type";
      return 0;
  }
}

int bmp_pack(lua_State *L, int idx, bmp_buf *o, int null_idx, int array_idx,
             const char **err) {
  idx = lua_absindex(L, idx);
  if (null_idx) null_idx = lua_absindex(L, null_idx);
  if (array_idx) array_idx = lua_absindex(L, array_idx);
  int top = lua_gettop(L);
  *err = NULL;
  int ok = pack_value(L, idx, o, null_idx, array_idx, 0, err);
  lua_settop(L, top);
  if (ok && o->oom) { *err = "out of memory"; ok = 0; }
  return ok;
}

/* ---- generic decode ----------------------------------------------------- */

static int unpack_value(lua_State *L, bmp_cur *c, int null_idx, int array_idx,
                        int depth, const char **err);

static void push_null(lua_State *L, int null_idx) {
  if (null_idx) lua_pushvalue(L, null_idx); else lua_pushnil(L);
}

static int unpack_array(lua_State *L, bmp_cur *c, size_t n, int null_idx,
                        int array_idx, int depth, const char **err) {
  if (n == 0 && array_idx) { lua_pushvalue(L, array_idx); return 1; }
  if (n > (size_t)(c->end - c->p)) { *err = "truncated"; return 0; } /* >=1 byte per item */
  lua_createtable(L, n > 1024 ? 1024 : (int)n, 0);
  for (size_t i = 1; i <= n; i++) {
    if (!unpack_value(L, c, null_idx, array_idx, depth + 1, err)) return 0;
    if (lua_isnil(L, -1)) { lua_pop(L, 1); push_null(L, null_idx); }
    lua_rawseti(L, -2, (lua_Integer)i);
  }
  return 1;
}

static int unpack_map(lua_State *L, bmp_cur *c, size_t n, int null_idx,
                      int array_idx, int depth, const char **err) {
  if (n > (size_t)(c->end - c->p) / 2) { *err = "truncated"; return 0; }
  lua_createtable(L, 0, n > 1024 ? 1024 : (int)n);
  for (size_t i = 0; i < n; i++) {
    if (!unpack_value(L, c, null_idx, array_idx, depth + 1, err)) return 0;
    if (lua_type(L, -1) != LUA_TSTRING && !lua_isinteger(L, -1)) {
      *err = "map keys must be strings or integers";
      return 0;
    }
    if (!unpack_value(L, c, null_idx, array_idx, depth + 1, err)) return 0;
    if (lua_isnil(L, -1)) { lua_pop(L, 1); push_null(L, null_idx); }
    lua_rawset(L, -3);
  }
  return 1;
}

static int unpack_value(lua_State *L, bmp_cur *c, int null_idx, int array_idx,
                        int depth, const char **err) {
  if (depth > BMP_MAX_DEPTH) { *err = "nesting too deep"; return 0; }
  if (!lua_checkstack(L, 8)) { *err = "stack overflow"; return 0; }
  if (!bmp_rd_need(c, 1)) { *err = "truncated"; return 0; }
  unsigned char t = *c->p++;
  const unsigned char *p = c->p;
  size_t len;
#define NEED(k) do { if (!bmp_rd_need(c, (k))) { *err = "truncated"; return 0; } } while (0)
  if (t <= 0x7f) { lua_pushinteger(L, t); return 1; }
  if (t >= 0xe0) { lua_pushinteger(L, (lua_Integer)(int8_t)t); return 1; }
  if ((t & 0xe0) == 0xa0) { len = t & 0x1f; goto str; }
  if ((t & 0xf0) == 0x90) return unpack_array(L, c, t & 0x0f, null_idx, array_idx, depth, err);
  if ((t & 0xf0) == 0x80) return unpack_map(L, c, t & 0x0f, null_idx, array_idx, depth, err);
  switch (t) {
    case 0xc0: lua_pushnil(L); return 1;
    case 0xc2: lua_pushboolean(L, 0); return 1;
    case 0xc3: lua_pushboolean(L, 1); return 1;
    case 0xc4: case 0xd9: NEED(1); len = p[0]; c->p += 1; goto str;
    case 0xc5: case 0xda: NEED(2); len = rd_be(p, 2); c->p += 2; goto str;
    case 0xc6: case 0xdb: NEED(4); len = rd_be(p, 4); c->p += 4; goto str;
    case 0xca: { NEED(4); uint32_t b = rd_be(p, 4); float f; memcpy(&f, &b, 4);
                 c->p += 4; lua_pushnumber(L, (lua_Number)f); return 1; }
    case 0xcb: { NEED(8); uint64_t b = ((uint64_t)rd_be(p, 4) << 32) | rd_be(p + 4, 4);
                 double d; memcpy(&d, &b, 8); c->p += 8; lua_pushnumber(L, (lua_Number)d); return 1; }
    case 0xcc: NEED(1); c->p += 1; lua_pushinteger(L, p[0]); return 1;
    case 0xcd: NEED(2); c->p += 2; lua_pushinteger(L, (lua_Integer)rd_be(p, 2)); return 1;
    case 0xce: NEED(4); c->p += 4; lua_pushinteger(L, (lua_Integer)rd_be(p, 4)); return 1;
    case 0xcf: { NEED(8); uint64_t v = ((uint64_t)rd_be(p, 4) << 32) | rd_be(p + 4, 4); c->p += 8;
                 if (v > (uint64_t)INT64_MAX) lua_pushnumber(L, (lua_Number)v);
                 else lua_pushinteger(L, (lua_Integer)v);
                 return 1; }
    case 0xd0: NEED(1); c->p += 1; lua_pushinteger(L, (int8_t)p[0]); return 1;
    case 0xd1: NEED(2); c->p += 2; lua_pushinteger(L, (int16_t)rd_be(p, 2)); return 1;
    case 0xd2: NEED(4); c->p += 4; lua_pushinteger(L, (int32_t)rd_be(p, 4)); return 1;
    case 0xd3: { NEED(8); uint64_t v = ((uint64_t)rd_be(p, 4) << 32) | rd_be(p + 4, 4); c->p += 8;
                 lua_pushinteger(L, (lua_Integer)(int64_t)v); return 1; }
    case 0xdc: NEED(2); c->p += 2; return unpack_array(L, c, rd_be(p, 2), null_idx, array_idx, depth, err);
    case 0xdd: NEED(4); c->p += 4; return unpack_array(L, c, rd_be(p, 4), null_idx, array_idx, depth, err);
    case 0xde: NEED(2); c->p += 2; return unpack_map(L, c, rd_be(p, 2), null_idx, array_idx, depth, err);
    case 0xdf: NEED(4); c->p += 4; return unpack_map(L, c, rd_be(p, 4), null_idx, array_idx, depth, err);
    default: *err = "unsupported msgpack type (ext)"; return 0;
  }
str:
  NEED(len);
  lua_pushlstring(L, (const char *)c->p, len);
  c->p += len;
  return 1;
#undef NEED
}

int bmp_unpack(lua_State *L, const unsigned char *p, size_t n, int null_idx,
               int array_idx, const char **err) {
  if (null_idx) null_idx = lua_absindex(L, null_idx);
  if (array_idx) array_idx = lua_absindex(L, array_idx);
  int top = lua_gettop(L);
  bmp_cur c = { p, p + n };
  *err = NULL;
  if (!unpack_value(L, &c, null_idx, array_idx, 0, err)) { lua_settop(L, top); return 0; }
  if (c.p != c.end) { lua_settop(L, top); *err = "trailing bytes"; return 0; }
  return 1;
}
