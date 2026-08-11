/* lmem.c -- a counting Lua allocator, and sys.membytes().
 *
 * Why this exists: lua/tools.lua bounds a generated tool's memory so a runaway
 * one cannot take the process down. That check used collectgarbage("count"),
 * which was fine through Lua 5.4 and is not fine on 5.5 -- 5.5 no longer
 * accounts for string memory there. Measured on the upgrade: 2,000 retained
 * 100 KB strings (~200 MB) reported a 62 KB delta, while 200,000 small tables
 * reported a correct 14 MB. Which is to say the limit had gone blind to
 * precisely the most likely way a tool blows memory -- building an enormous
 * string.
 *
 * Counting bytes in the allocator is immune to that. It sees every allocation
 * Lua makes whatever its type, it cannot drift when the GC's accounting
 * changes again, and it puts the policy in C next to the other capability
 * limits rather than trusting a number the VM happens to expose.
 */
#include <stdlib.h>

#include "lua.h"
#include "lauxlib.h"

static size_t g_live = 0;  /* bytes currently allocated through this allocator */
static size_t g_peak = 0;

/* Signature per lua_Alloc: osize is the old size (or a type tag when ptr is
 * NULL), nsize the requested one. Freeing is nsize == 0. */
static void *counting_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud;
  if (nsize == 0) {
    if (ptr) g_live -= osize;
    free(ptr);
    return NULL;
  }
  void *np = realloc(ptr, nsize);
  if (!np) return NULL; /* leave the counter alone: nothing changed */
  if (ptr) g_live -= osize;
  g_live += nsize;
  if (g_live > g_peak) g_peak = g_live;
  return np;
}

size_t boggart_mem_live(void) { return g_live; }

/* Create a Lua state whose allocations are counted.
 *
 * Note the third argument: Lua 5.5 added a hashing seed to lua_newstate.
 * luaL_makeseed is the library's own choice of seed, so this differs from
 * luaL_newstate only in the allocator. */
lua_State *boggart_newstate(void) {
  return lua_newstate(counting_alloc, NULL, luaL_makeseed(NULL));
}

/* sys.membytes() -> live, peak
 * Real bytes, not the GC's view of them. */
static int l_membytes(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)g_live);
  lua_pushinteger(L, (lua_Integer)g_peak);
  return 2;
}

void boggart_open_mem(lua_State *L) {
  lua_getglobal(L, "sys");
  if (lua_istable(L, -1)) {
    lua_pushcfunction(L, l_membytes);
    lua_setfield(L, -2, "membytes");
  }
  lua_pop(L, 1);
}
