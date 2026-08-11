/* assets.c -- require() and font loading out of the baked-in studio/data.
 *
 * The studio used to need its Lua tree on disk beside the executable: main.c
 * put <exedir>/data and <exedir>/studio/data on package.path and set DATADIR to
 * whichever existed. That works from a checkout and makes a release archive a
 * directory rather than a file -- and a directory is a thing users unpack
 * wrongly, move the binary out of, and then report as "it does not start".
 *
 * So the tree is baked in, and this is the searcher that reads it. Registered
 * *after* the path searcher, deliberately: an on-disk data/ still wins, so a
 * checkout runs its working copy and `boggart-studio` picks up an edit to
 * core/agentview.lua without a rebuild. Same overlay-first rule src/bogembed.c
 * already uses for lua/, and for the same reason.
 */
#include <string.h>
#include <stdio.h>

#include "lua.h"
#include "lauxlib.h"

#include "assets.h"

/* require("core.doc") asks for "core/doc.lua" and then "core/doc/init.lua",
 * which is the same pair the path searcher tries and the same pair the module
 * layout under studio/data was written against. */
static const void* find_module(const char *name, size_t *len, char *keybuf,
                               size_t keysz) {
  char path[512];
  snprintf(path, sizeof path, "%s", name);
  for (char *p = path; *p; p++) { if (*p == '.') { *p = '/'; } }

  snprintf(keybuf, keysz, "%s.lua", path);
  const void *src = studio_asset_get(keybuf, len);
  if (src) { return src; }

  snprintf(keybuf, keysz, "%s/init.lua", path);
  return studio_asset_get(keybuf, len);
}


static int asset_searcher(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  size_t len = 0;
  char key[600];
  const void *src = find_module(name, &len, key, sizeof key);
  if (!src) {
    lua_pushfstring(L, "\n\tno baked asset '%s'", name);
    return 1;
  }
  /* The chunk name is what shows up in a traceback, so it names the asset
   * rather than the interpreter: a stack trace pointing at "core/init.lua" is
   * findable in the repository, one pointing at "=[C]" is not. */
  char chunk[640];
  snprintf(chunk, sizeof chunk, "@%s/%s", STUDIO_ASSET_PREFIX, key);
  if (luaL_loadbuffer(L, (const char*) src, len, chunk) != LUA_OK) {
    return luaL_error(L, "error loading baked asset '%s': %s",
                      name, lua_tostring(L, -1));
  }
  lua_pushstring(L, key);   /* passed to the loader as its second argument */
  return 2;
}


void studio_assets_open(struct lua_State *Ls) {
  lua_State *L = (lua_State*) Ls;
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "searchers");
  /* Appended, not inserted: the path searcher ahead of it is what lets a
   * checkout override the baked copy. */
  lua_Integer n = (lua_Integer) lua_rawlen(L, -1);
  lua_pushcfunction(L, asset_searcher);
  lua_rawseti(L, -2, n + 1);
  lua_pop(L, 2);
}
