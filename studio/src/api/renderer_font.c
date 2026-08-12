#include "api.h"
#include "renderer.h"
#include "rencache.h"
#include "assets.h"
#include <string.h>


/* An optional third argument to renderer.font.load, naming what the renderer
 * has always had to guess:
 *
 *   { antialiasing = "none" | "grayscale" | "subpixel",
 *     hinting      = "none" | "slight" | "full",
 *     bold = true, italic = true, underline = true, strikethrough = true }
 *
 * Strings rather than numbers because these end up in a settings file that a
 * person reads, and "slight" survives a renumbering that 1 does not. Anything
 * absent keeps the default, so an old call site is unaffected; anything
 * misspelt is an error rather than a silent fallback, because a font that
 * quietly ignores `hinting = "slght"` is a bug you find months later by
 * squinting. */
static int enum_field(lua_State *L, int idx, const char *key,
                      const char *const *names, int def) {
  if (lua_isnoneornil(L, idx)) { return def; }
  lua_getfield(L, idx, key);
  if (lua_isnoneornil(L, -1)) { lua_pop(L, 1); return def; }
  const char *s = luaL_checkstring(L, -1);
  for (int i = 0; names[i]; i++) {
    if (!strcmp(s, names[i])) { lua_pop(L, 1); return i; }
  }
  return luaL_error(L, "bad %s '%s' for a font", key, s);
}


static unsigned style_flags(lua_State *L, int idx) {
  static const struct { const char *key; unsigned bit; } bits[] = {
    { "bold",          REN_STYLE_BOLD          },
    { "italic",        REN_STYLE_ITALIC        },
    { "underline",     REN_STYLE_UNDERLINE     },
    { "strikethrough", REN_STYLE_STRIKETHROUGH },
  };
  unsigned style = 0;
  if (lua_isnoneornil(L, idx)) { return 0; }
  for (size_t i = 0; i < sizeof bits / sizeof *bits; i++) {
    lua_getfield(L, idx, bits[i].key);
    if (lua_toboolean(L, -1)) { style |= bits[i].bit; }
    lua_pop(L, 1);
  }
  return style;
}


/* A path under the baked-in assets, or a real file.
 *
 * style.lua asks for DATADIR .. "/fonts/font.ttf" and does not care which it
 * gets. When there is no data/ directory on disk the bootstrap sets DATADIR to
 * "@assets", so the prefix -- rather than a guess at which trailing path
 * components look like an asset key -- is what decides. A checkout with a real
 * data/ directory still reads the file, so editing a font needs no rebuild. */
static int f_load(lua_State *L) {
  static const char *const AA[] = { "none", "grayscale", "subpixel", NULL };
  static const char *const HINT[] = { "none", "slight", "full", NULL };

  const char *filename  = luaL_checkstring(L, 1);
  float size = luaL_checknumber(L, 2);
  if (!lua_isnoneornil(L, 3)) { luaL_checktype(L, 3, LUA_TTABLE); }
  RenFontOptions opt = {
    .antialiasing = enum_field(L, 3, "antialiasing", AA, REN_AA_GRAYSCALE),
    .hinting      = enum_field(L, 3, "hinting", HINT, REN_HINT_SLIGHT),
    .style        = style_flags(L, 3),
  };

  RenFont **self = lua_newuserdata(L, sizeof(*self));
  luaL_setmetatable(L, API_TYPE_FONT);

  static const char pfx[] = STUDIO_ASSET_PREFIX "/";
  if (!strncmp(filename, pfx, sizeof pfx - 1)) {
    size_t len = 0;
    const void *data = studio_asset_get(filename + sizeof pfx - 1, &len);
    if (!data) { luaL_error(L, "no baked font '%s'", filename); }
    *self = ren_load_font_mem(data, len, size, &opt);
  } else {
    *self = ren_load_font(filename, size, &opt);
  }
  if (!*self) { luaL_error(L, "failed to load font '%s'", filename); }
  return 1;
}


static int f_set_tab_width(lua_State *L) {
  RenFont **self = luaL_checkudata(L, 1, API_TYPE_FONT);
  int n = luaL_checknumber(L, 2);
  ren_set_font_tab_width(*self, n);
  return 0;
}


static int f_gc(lua_State *L) {
  RenFont **self = luaL_checkudata(L, 1, API_TYPE_FONT);
  if (*self) { rencache_free_font(*self); }
  return 0;
}


static int f_get_width(lua_State *L) {
  RenFont **self = luaL_checkudata(L, 1, API_TYPE_FONT);
  const char *text = luaL_checkstring(L, 2);
  lua_pushnumber(L, ren_get_font_width(*self, text) );
  return 1;
}


static int f_get_height(lua_State *L) {
  RenFont **self = luaL_checkudata(L, 1, API_TYPE_FONT);
  lua_pushnumber(L, ren_get_font_height(*self) );
  return 1;
}


/* renderer.font.fallbacks() -> { { path = ..., loaded = bool }, ... }
 *
 * A capability, answered by C, in the shape sys.caps() established: Lua asks
 * what this machine can draw rather than inferring it from the platform name.
 * An empty table is a real answer -- it means nothing outside the bundled
 * fonts will render -- and not an error. */
static int f_fallbacks(lua_State *L) {
  int n = ren_fallback_count();
  lua_createtable(L, n, 0);
  for (int i = 0; i < n; i++) {
    int loaded = 0;
    const char *path = ren_fallback_path(i, &loaded);
    if (!path) { break; }
    lua_createtable(L, 0, 2);
    lua_pushstring(L, path);      lua_setfield(L, -2, "path");
    lua_pushboolean(L, loaded);   lua_setfield(L, -2, "loaded");
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}


static const luaL_Reg lib[] = {
  { "__gc",          f_gc            },
  { "load",          f_load          },
  { "set_tab_width", f_set_tab_width },
  { "get_width",     f_get_width     },
  { "get_height",    f_get_height    },
  { "fallbacks",     f_fallbacks     },
  { NULL, NULL }
};

int luaopen_renderer_font(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_FONT);
  luaL_setfuncs(L, lib, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  return 1;
}
