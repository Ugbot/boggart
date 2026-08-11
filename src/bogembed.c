/* bogembed.c -- open boggart's capability libraries into a lua_State.
 *
 * Shared by the CLI (src/boggart.c) and the desktop app (app/src/main.c) so
 * there is one definition of "what boggart exposes" rather than two that drift.
 *
 * The app is the interesting caller: it hands us lite's interpreter, so the
 * editor and the agent end up in the *same* lua_State. That is deliberate. It
 * is what lets the agent reach the editor's own Lua -- add a command, bind a
 * key, write a syntax mode for the file it is looking at -- which is the thing
 * a subprocess-based agent panel structurally cannot do.
 */
#include <stdio.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include "embedded.h"

int luaopen_boggart_http(lua_State *L);
int luaopen_boggart_sys(lua_State *L);
int luaopen_boggart_db(lua_State *L);
int luaopen_boggart_swarm(lua_State *L);
int luaopen_boggart_mcp(lua_State *L);
int luaopen_boggart_auth(lua_State *L);
int luaopen_luv(lua_State *L);

/* boggart.embedded(name) -> source | nil */
static int l_embedded(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  size_t len = 0;
  const char *src = boggart_embedded_get(name, &len);
  if (!src) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, src, len);
  return 1;
}

static int l_embedded_names(lua_State *L) {
  size_t n = boggart_embedded_count();
  lua_createtable(L, (int)n, 0);
  for (size_t i = 0; i < n; i++) {
    lua_pushstring(L, boggart_embedded_name(i));
    lua_rawseti(L, -2, (int)i + 1);
  }
  return 1;
}

/* The fallback searcher for baked-in modules: require("tools") finds
 * lua/tools.lua as it was at build time. An overlay under ~/.boggart/lua is
 * still consulted first, because boot.lua prepends it to package.path and the
 * path searcher runs ahead of this one. */
static int embedded_searcher(lua_State *S) {
  const char *name = luaL_checkstring(S, 1);
  char path[512];
  snprintf(path, sizeof(path), "%s", name);
  for (char *p = path; *p; p++) if (*p == '.') *p = '/';
  size_t len = 0;
  const char *src = boggart_embedded_get(path, &len);
  if (!src) {
    lua_pushfstring(S, "\n\tno embedded module '%s'", name);
    return 1;
  }
  char chunkname[576];
  snprintf(chunkname, sizeof(chunkname), "@embedded:%s", name);
  if (luaL_loadbuffer(S, src, len, chunkname) != LUA_OK) return lua_error(S);
  return 1;
}

/* Open the capability globals. Same set the CLI gets: the agent's vocabulary
 * should not depend on which shell it is running inside. */
void boggart_open_libs(lua_State *L) {
  luaL_requiref(L, "http", luaopen_boggart_http, 0);   lua_setglobal(L, "http");
  luaL_requiref(L, "sys", luaopen_boggart_sys, 0);     lua_setglobal(L, "sys");
  luaL_requiref(L, "db", luaopen_boggart_db, 0);       lua_setglobal(L, "db");
  luaL_requiref(L, "swarm", luaopen_boggart_swarm, 0); lua_setglobal(L, "swarm");
  luaL_requiref(L, "mcp", luaopen_boggart_mcp, 0);     lua_setglobal(L, "mcp");
  luaL_requiref(L, "auth", luaopen_boggart_auth, 0);   lua_setglobal(L, "auth");

  /* luv lazily: opening it creates a uv_loop_t, and the app only needs one
   * once an agent actually runs. */
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, luaopen_luv);
  lua_setfield(L, -2, "uv");
  lua_pop(L, 2);
}

/* The `boggart` table plus the embedded-module searcher, then run boot.
 *
 * `mode` selects what boot does at the end: the CLI passes "repl"/"oneshot"/…
 * and boot dispatches; the app passes "embedded", where boot wires the harness,
 * opens the store and returns, leaving `bog` on the globals for the UI to
 * drive. Returns 0 on success. */
int boggart_boot(lua_State *L, const char *mode, const char *version) {
  /* The fallback searcher for baked-in modules, installed before anything
   * requires them. Registered after lite's package.path setup in the app, so
   * an overlay under ~/.boggart/lua still wins. */
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "searchers");
  int n = (int)luaL_len(L, -1);
  lua_pushcfunction(L, embedded_searcher);
  lua_rawseti(L, -2, n + 1);
  lua_pop(L, 2);

  lua_newtable(L);
  lua_pushstring(L, version);             lua_setfield(L, -2, "version");
  lua_pushcfunction(L, l_embedded);       lua_setfield(L, -2, "embedded");
  lua_pushcfunction(L, l_embedded_names); lua_setfield(L, -2, "embedded_names");
  lua_pushstring(L, mode);                lua_setfield(L, -2, "mode");
  lua_newtable(L);                        lua_setfield(L, -2, "args");
  lua_pushboolean(L, 0);                  lua_setfield(L, -2, "resume");
  lua_pushboolean(L, 0);                  lua_setfield(L, -2, "tui");
  lua_setglobal(L, "boggart");

  size_t len = 0;
  const char *boot = boggart_embedded_get("boot", &len);
  if (!boot) return -1;
  if (luaL_loadbuffer(L, boot, len, "@boot") != LUA_OK) return -1;
  if (lua_pcall(L, 0, 1, 0) != LUA_OK) return -1;
  lua_pop(L, 1);
  return 0;
}
