#ifndef API_H
#define API_H

/* The editor core came from rxi's lite, which bundled its own Lua 5.2. The
 * shares ONE interpreter with boggart -- that is the entire basis of the
 * integration, since it is what lets the agent reach the editor's own Lua --
 * and boggart's is the vendored 5.4. So we point at that instead.
 *
 * The port cost turned out to be a single call site: lua_newuserdata, which
 * 5.4 still provides as a macro over lua_newuserdatauv. Everything else in
 * lite's C already uses 5.2+ API that 5.4 kept (luaL_setfuncs, luaL_newlib).
 * studio shares boggart's interpreter instead; that copy is gone. */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#define API_TYPE_FONT "Font"

void api_load_libs(lua_State *L);

#endif
