#include "api.h"
#include "renderer.h"
#include "rencache.h"


static RenColor checkcolor(lua_State *L, int idx, int def) {
  RenColor color;
  if (lua_isnoneornil(L, idx)) {
    return (RenColor) { def, def, def, 255 };
  }
  lua_rawgeti(L, idx, 1);
  lua_rawgeti(L, idx, 2);
  lua_rawgeti(L, idx, 3);
  lua_rawgeti(L, idx, 4);
  color.r = luaL_checknumber(L, -4);
  color.g = luaL_checknumber(L, -3);
  color.b = luaL_checknumber(L, -2);
  color.a = luaL_optnumber(L, -1, 255);
  lua_pop(L, 4);
  return color;
}


static int f_show_debug(lua_State *L) {
  luaL_checkany(L, 1);
  rencache_show_debug(lua_toboolean(L, 1));
  return 0;
}


static int f_get_size(lua_State *L) {
  int w, h;
  ren_get_size(&w, &h);
  lua_pushnumber(L, w);
  lua_pushnumber(L, h);
  return 2;
}


static int f_begin_frame(lua_State *L) {
  rencache_begin_frame();
  return 0;
}


static int f_end_frame(lua_State *L) {
  rencache_end_frame();
  return 0;
}


static int f_set_clip_rect(lua_State *L) {
  RenRect rect;
  rect.x = luaL_checknumber(L, 1);
  rect.y = luaL_checknumber(L, 2);
  rect.width = luaL_checknumber(L, 3);
  rect.height = luaL_checknumber(L, 4);
  rencache_set_clip_rect(rect);
  return 0;
}


static int f_draw_rect(lua_State *L) {
  RenRect rect;
  rect.x = luaL_checknumber(L, 1);
  rect.y = luaL_checknumber(L, 2);
  rect.width = luaL_checknumber(L, 3);
  rect.height = luaL_checknumber(L, 4);
  RenColor color = checkcolor(L, 5, 255);
  rencache_draw_rect(rect, color);
  return 0;
}


static int f_draw_line(lua_State *L) {
  float x0 = luaL_checknumber(L, 1);
  float y0 = luaL_checknumber(L, 2);
  float x1 = luaL_checknumber(L, 3);
  float y1 = luaL_checknumber(L, 4);
  RenColor color = checkcolor(L, 5, 255);
  float thickness = luaL_optnumber(L, 6, 1.0);
  rencache_draw_line(x0, y0, x1, y1, thickness, color);
  return 0;
}


static int f_draw_text(lua_State *L) {
  RenFont **font = luaL_checkudata(L, 1, API_TYPE_FONT);
  const char *text = luaL_checkstring(L, 2);
  int x = luaL_checknumber(L, 3);
  int y = luaL_checknumber(L, 4);
  RenColor color = checkcolor(L, 5, 255);
  x = rencache_draw_text(*font, text, x, y, color);
  lua_pushnumber(L, x);
  return 1;
}


/* ---- images ---------------------------------------------------------------
 * renderer.image_from_rgba(bytes, w, h) -> Image, renderer.draw_image(img, ...).
 * The pixels come from Lua (a decoded PNG/JPG, or a rasterised PDF page later)
 * as a tightly-packed RGBA byte string; RenColor is BGRA, so channels are
 * reordered on upload. The Image is a GC userdata that frees its RenImage; the
 * VIEW must keep a reference for as long as it draws it (rencache commands are
 * pushed and consumed within one frame, so the pixels only need to outlive the
 * draw() that referenced them). */
static int f_image_from_rgba(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  int w = luaL_checkinteger(L, 2);
  int h = luaL_checkinteger(L, 3);
  if (w <= 0 || h <= 0) { return luaL_error(L, "image dimensions must be positive"); }
  if (len < (size_t) w * (size_t) h * 4) {
    return luaL_error(L, "rgba buffer too small: need %d bytes, got %d", w * h * 4, (int) len);
  }
  RenImage **ud = lua_newuserdata(L, sizeof(RenImage *));
  *ud = NULL;
  luaL_setmetatable(L, API_TYPE_IMAGE);
  RenImage *img = ren_new_image(w, h);
  const unsigned char *p = (const unsigned char *) data;
  int n = w * h;
  for (int i = 0; i < n; i++) {
    img->pixels[i].r = p[i * 4 + 0];
    img->pixels[i].g = p[i * 4 + 1];
    img->pixels[i].b = p[i * 4 + 2];
    img->pixels[i].a = p[i * 4 + 3];
  }
  *ud = img;
  return 1;
}

static int f_image_gc(lua_State *L) {
  RenImage **ud = luaL_checkudata(L, 1, API_TYPE_IMAGE);
  if (*ud) { ren_free_image(*ud); *ud = NULL; }
  return 0;
}

static int f_image_size(lua_State *L) {
  RenImage **ud = luaL_checkudata(L, 1, API_TYPE_IMAGE);
  if (!*ud) { return 0; }
  lua_pushinteger(L, (*ud)->width);
  lua_pushinteger(L, (*ud)->height);
  return 2;
}

/* renderer.draw_image(image, x, y [, w, h [, color]]) -- scaled to w x h. */
static int f_draw_image(lua_State *L) {
  RenImage **ud = luaL_checkudata(L, 1, API_TYPE_IMAGE);
  RenImage *img = *ud;
  if (!img) { return 0; }
  RenRect dst;
  dst.x = luaL_checknumber(L, 2);
  dst.y = luaL_checknumber(L, 3);
  dst.width  = luaL_optnumber(L, 4, img->width);
  dst.height = luaL_optnumber(L, 5, img->height);
  RenColor color = checkcolor(L, 6, 255);
  RenRect sub = { 0, 0, img->width, img->height };
  rencache_draw_image(img, sub, dst, color);
  return 0;
}


static const luaL_Reg lib[] = {
  { "show_debug",      f_show_debug      },
  { "get_size",        f_get_size        },
  { "begin_frame",     f_begin_frame     },
  { "end_frame",       f_end_frame       },
  { "set_clip_rect",   f_set_clip_rect   },
  { "draw_rect",       f_draw_rect       },
  { "draw_line",       f_draw_line       },
  { "draw_text",       f_draw_text       },
  { "image_from_rgba", f_image_from_rgba },
  { "draw_image",      f_draw_image      },
  { NULL,              NULL              }
};


int luaopen_renderer_font(lua_State *L);

int luaopen_renderer(lua_State *L) {
  luaL_newlib(L, lib);

  /* the Image userdata metatype: frees its RenImage on GC, and answers :size(). */
  luaL_newmetatable(L, API_TYPE_IMAGE);
  lua_pushcfunction(L, f_image_gc);
  lua_setfield(L, -2, "__gc");
  lua_newtable(L);
  lua_pushcfunction(L, f_image_size);
  lua_setfield(L, -2, "size");
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaopen_renderer_font(L);
  lua_setfield(L, -2, "font");
  return 1;
}
