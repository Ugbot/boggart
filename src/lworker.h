/* lworker.h -- real OS worker threads, each with its own uv_loop_t and its own
 * boggart-shaped lua_State. See lworker.c for the design and the threading
 * argument; this header is deliberately small because everything interesting
 * is owned by the .c file and reached from Lua, not from C.
 */
#ifndef BOGGART_LWORKER_H
#define BOGGART_LWORKER_H

#include "lua.h"

/* Registers the `worker` library. In the main state this is spawn/post/recv/
 * stop/join/status; inside a worker state the worker thread overwrites those
 * with the worker-side half (post/recv/onmessage/stopped) and deniers. */
int luaopen_boggart_worker(lua_State *L);

#endif /* BOGGART_LWORKER_H */
