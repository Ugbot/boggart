/* bmsgpack.h -- the msgpack codec shared by the ZMQ clients.
 *
 * Two layers. The primitives (a growable byte buffer that never touches the
 * Lua stack, header writers, a bounds-checked read cursor) are what
 * src/lstation.c's flat {msg_type, tool, payload} envelope is built from. The
 * generic Lua <-> msgpack value codec on top of them is what src/lzmq.c
 * exposes as zmq.pack / zmq.unpack for any protocol carried over ZMQ.
 *
 * The buffer is deliberately not a luaL_Buffer: encoders walk tables with
 * lua_next while appending, and a luaL_Buffer that outgrows its inline space
 * keeps its storage in a box on the stack (the 2026-09-28 studio crash).
 */
#ifndef BOGGART_BMSGPACK_H
#define BOGGART_BMSGPACK_H

#include <stddef.h>
#include <stdint.h>
#include <lua.h>

typedef struct { char *p; size_t n, cap; int oom; } bmp_buf;

void bmp_bytes(bmp_buf *o, const void *p, size_t n);
void bmp_u8(bmp_buf *o, unsigned char c);
void bmp_str(bmp_buf *o, const char *s, size_t n);
void bmp_bin(bmp_buf *o, const char *s, size_t n);
void bmp_map_header(bmp_buf *o, size_t n);
void bmp_array_header(bmp_buf *o, size_t n);
void bmp_int(bmp_buf *o, int64_t v);
void bmp_double(bmp_buf *o, double v);
void bmp_nil(bmp_buf *o);
void bmp_bool(bmp_buf *o, int v);
void bmp_free(bmp_buf *o);

typedef struct { const unsigned char *p, *end; } bmp_cur;

int bmp_rd_need(bmp_cur *c, size_t n);
int bmp_rd_str(bmp_cur *c, const char **s, size_t *n);
int bmp_rd_map_header(bmp_cur *c, size_t *n);
/* Skip one well-formed value (str, map, array, ints, floats, nil/bool, bin8/16).
 * Depth-capped at 8: the station envelope is flat, deep nesting is garbage. */
int bmp_rd_skip(bmp_cur *c, int depth);

/* ---- the generic value codec ---------------------------------------------
 * Strings encode as str, integers in their smallest format, floats as float64,
 * booleans, and a table as an array when its keys are exactly 1..n, otherwise
 * as a map with its keys sorted bytewise (so an encoding is canonical and can
 * be byte-compared against fixtures). Map keys must be strings or integers.
 *
 * null_idx / array_idx are stack slots holding the JSON sentinels (json.null,
 * json.array) or 0 for none: json.null encodes as nil and json.array as an
 * empty array; decoding yields json.null for a nil inside a map or an array
 * (so the key survives) and json.array for an empty array. */
int bmp_pack(lua_State *L, int idx, bmp_buf *o, int null_idx, int array_idx,
             const char **err);
/* Pushes the decoded value and returns 1, or pushes nothing and returns 0
 * with *err set. Strict: truncation and trailing bytes fail. */
int bmp_unpack(lua_State *L, const unsigned char *p, size_t n, int null_idx,
               int array_idx, const char **err);

#endif
