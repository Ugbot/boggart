#ifndef API_H
#define API_H

/* boggart: lite bundles its own Lua 5.2 under src/lib/lua52. The studio app
 * shares ONE interpreter with boggart -- that is the entire basis of the
 * integration, since it is what lets the agent reach the editor's own Lua --
 * and boggart's is the vendored 5.4. So we point at that instead.
 *
 * The port cost turned out to be a single call site: lua_newuserdata, which
 * 5.4 still provides as a macro over lua_newuserdatauv. Everything else in
 * lite's C already uses 5.2+ API that 5.4 kept (luaL_setfuncs, luaL_newlib).
 * src/lib/lua52 is left in the tree unbuilt, as upstream reference. */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#define API_TYPE_FONT "Font"

void api_load_libs(lua_State *L);

#endif
