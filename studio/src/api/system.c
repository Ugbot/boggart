#include <SDL2/SDL.h>
#include <stdbool.h>
#include <ctype.h>
/* Not <dirent.h>/<unistd.h>: MSVC has neither, so this file could not compile
 * on Windows at all -- which nobody noticed, because the studio had never been
 * built there. Upstream lite got away with it by using MinGW. libuv is already
 * linked into this binary and covers both portably, which is the same idiom
 * src/lsys.c uses for exactly this reason. */
#include <uv.h>

/* MSVC's <sys/stat.h> defines S_IFDIR/S_IFREG but not the S_IS* predicates,
 * so test the format bits directly -- the same shim as src/lsys.c. */
#ifndef S_ISREG
  #define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#endif
#ifndef S_ISDIR
  #define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#endif
#include <errno.h>
#include <sys/stat.h>
#include "api.h"
#include "dirmonitor.h"
#include "rencache.h"
#ifdef _WIN32
  #include <windows.h>
#endif

extern SDL_Window *window;


/* Points -> pixels for pointer input.
 *
 * lite renders into SDL_GetWindowSurface(), which with SDL_WINDOW_ALLOW_HIGHDPI
 * is the pixel-sized backing store, while SDL delivers mouse coordinates in
 * points. Upstream passes them straight through, so on a Retina display the
 * pointer lands at half the position everything was drawn at -- and the error
 * grows the further right and down you click, which is what makes selecting
 * text feel broken rather than merely offset.
 *
 * Converting here is the whole fix: the Lua side already works in the same
 * pixel space it draws into and needs no changes at all.
 *
 * Cached, because this is consulted on every motion event, and invalidated on a
 * window/display change -- dragging a window from a Retina display to an
 * external monitor changes the ratio.
 */
extern double studio_get_scale(void);

static double g_input_scale = 0.0;

static double input_scale(void) {
  if (g_input_scale <= 0.0) g_input_scale = studio_get_scale();
  return g_input_scale;
}

/* Round rather than truncate: at 2x, truncating biases every coordinate half a
 * pixel up and left, which is visible when clicking between two glyphs. */
static int px(int points) { return (int)((double)points * input_scale() + 0.5); }

static const char* button_name(int button) {
  switch (button) {
    case 1  : return "left";
    case 2  : return "middle";
    case 3  : return "right";
    default : return "?";
  }
}


static char* key_name(char *dst, int sym) {
  strcpy(dst, SDL_GetKeyName(sym));
  char *p = dst;
  while (*p) {
    *p = tolower(*p);
    p++;
  }
  return dst;
}


static int f_poll_event(lua_State *L) {
  char buf[16];
  int mx, my, wx, wy;
  SDL_Event e;

top:
  if ( !SDL_PollEvent(&e) ) {
    return 0;
  }

  switch (e.type) {
    case SDL_QUIT:
      lua_pushstring(L, "quit");
      return 1;

    case SDL_WINDOWEVENT:
      /* Re-measure the backing scale: a window dragged between a Retina
       * display and an external monitor changes the points-to-pixels ratio,
       * and a stale value puts the pointer back in the wrong place. */
      g_input_scale = 0.0;
      if (e.window.event == SDL_WINDOWEVENT_RESIZED) {
        lua_pushstring(L, "resized");
        /* data1/data2 are points; lite's layout is in pixels. */
        lua_pushnumber(L, px(e.window.data1));
        lua_pushnumber(L, px(e.window.data2));
        return 3;
      } else if (e.window.event == SDL_WINDOWEVENT_EXPOSED) {
        rencache_invalidate();
        lua_pushstring(L, "exposed");
        return 1;
      }
      /* on some systems, when alt-tabbing to the window SDL will queue up
      ** several KEYDOWN events for the `tab` key; we flush all keydown
      ** events on focus so these are discarded */
      if (e.window.event == SDL_WINDOWEVENT_FOCUS_GAINED) {
        SDL_FlushEvent(SDL_KEYDOWN);
      }
      goto top;

    case SDL_DROPFILE:
      SDL_GetGlobalMouseState(&mx, &my);
      SDL_GetWindowPosition(window, &wx, &wy);
      lua_pushstring(L, "filedropped");
      lua_pushstring(L, e.drop.file);
      lua_pushnumber(L, mx - wx);
      lua_pushnumber(L, my - wy);
      SDL_free(e.drop.file);
      return 4;

    case SDL_KEYDOWN:
      lua_pushstring(L, "keypressed");
      lua_pushstring(L, key_name(buf, e.key.keysym.sym));
      return 2;

    case SDL_KEYUP:
      lua_pushstring(L, "keyreleased");
      lua_pushstring(L, key_name(buf, e.key.keysym.sym));
      return 2;

    case SDL_TEXTINPUT:
      lua_pushstring(L, "textinput");
      lua_pushstring(L, e.text.text);
      return 2;

    case SDL_MOUSEBUTTONDOWN:
      if (e.button.button == 1) { SDL_CaptureMouse(1); }
      lua_pushstring(L, "mousepressed");
      lua_pushstring(L, button_name(e.button.button));
      lua_pushnumber(L, px(e.button.x));
      lua_pushnumber(L, px(e.button.y));
      lua_pushnumber(L, e.button.clicks);
      return 5;

    case SDL_MOUSEBUTTONUP:
      if (e.button.button == 1) { SDL_CaptureMouse(0); }
      lua_pushstring(L, "mousereleased");
      lua_pushstring(L, button_name(e.button.button));
      lua_pushnumber(L, px(e.button.x));
      lua_pushnumber(L, px(e.button.y));
      return 4;

    case SDL_MOUSEMOTION:
      lua_pushstring(L, "mousemoved");
      lua_pushnumber(L, px(e.motion.x));
      lua_pushnumber(L, px(e.motion.y));
      lua_pushnumber(L, px(e.motion.xrel));
      lua_pushnumber(L, px(e.motion.yrel));
      return 5;

    case SDL_MOUSEWHEEL:
      lua_pushstring(L, "mousewheel");
      lua_pushnumber(L, e.wheel.y);
      return 2;

    default:
      goto top;
  }

  return 0;
}


static int f_wait_event(lua_State *L) {
  double n = luaL_checknumber(L, 1);
  lua_pushboolean(L, SDL_WaitEventTimeout(NULL, n * 1000));
  return 1;
}


static SDL_Cursor* cursor_cache[SDL_SYSTEM_CURSOR_HAND + 1];

static const char *cursor_opts[] = {
  "arrow",
  "ibeam",
  "sizeh",
  "sizev",
  "hand",
  NULL
};

static const int cursor_enums[] = {
  SDL_SYSTEM_CURSOR_ARROW,
  SDL_SYSTEM_CURSOR_IBEAM,
  SDL_SYSTEM_CURSOR_SIZEWE,
  SDL_SYSTEM_CURSOR_SIZENS,
  SDL_SYSTEM_CURSOR_HAND
};

static int f_set_cursor(lua_State *L) {
  int opt = luaL_checkoption(L, 1, "arrow", cursor_opts);
  int n = cursor_enums[opt];
  SDL_Cursor *cursor = cursor_cache[n];
  if (!cursor) {
    cursor = SDL_CreateSystemCursor(n);
    cursor_cache[n] = cursor;
  }
  SDL_SetCursor(cursor);
  return 0;
}


/* system.save_screenshot(path) -> true | nil, err
 *
 * Writes the window's current framebuffer to a BMP. This exists so the GUI can
 * be checked without a human at the keyboard: an automated run can seed the
 * panel, render a frame, and produce an image to look at. Reaching for the
 * platform's screen-capture tool instead would mean screen-recording
 * permission, a focused window, and whatever else happens to be on the desktop
 * in the shot -- none of which a test should depend on.
 *
 * BMP because SDL2 can write it with no extra dependency, which is the whole
 * bar for a diagnostic. */
static int f_save_screenshot(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  SDL_Surface *surf = SDL_GetWindowSurface(window);
  if (!surf) {
    lua_pushnil(L);
    lua_pushstring(L, "no window surface");
    return 2;
  }
  if (SDL_SaveBMP(surf, path) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, SDL_GetError());
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* system.set_window_size(w, h) or set_window_size(x, y, w, h) -- points, as SDL
 * sizes and places windows.
 *
 * Only the automated checks use this: a layout bug that only appears in a very
 * narrow or very wide window is otherwise unreachable without a person dragging
 * the frame, and the developer's display size would silently decide which
 * layouts `ninja ui-check` exercised. There is no matching event to raise --
 * the frame loop reads renderer.get_size() from the window surface every
 * iteration, so the next frame already has the new size.
 *
 * Both arities are accepted because both callers exist: a size is all a layout
 * check needs, and a position matters when a probe must not land under another
 * window. Refusing one of them would only mean two functions that do the same
 * SDL calls. */
static int f_set_window_size(lua_State *L) {
  int n = lua_gettop(L);
  int x = 0, y = 0, w, h;
  if (n >= 4) {
    x = (int) luaL_checknumber(L, 1);
    y = (int) luaL_checknumber(L, 2);
    w = (int) luaL_checknumber(L, 3);
    h = (int) luaL_checknumber(L, 4);
  } else {
    w = (int) luaL_checknumber(L, 1);
    h = (int) luaL_checknumber(L, 2);
  }
  if (w < 1 || h < 1) { return luaL_error(L, "window size must be positive"); }
  SDL_RestoreWindow(window);
  if (n >= 4) { SDL_SetWindowPosition(window, x, y); }
  SDL_SetWindowSize(window, w, h);
  return 0;
}


static int f_set_window_title(lua_State *L) {
  const char *title = luaL_checkstring(L, 1);
  SDL_SetWindowTitle(window, title);
  return 0;
}


static const char *window_opts[] = { "normal", "maximized", "fullscreen", 0 };
enum { WIN_NORMAL, WIN_MAXIMIZED, WIN_FULLSCREEN };

static int f_set_window_mode(lua_State *L) {
  int n = luaL_checkoption(L, 1, "normal", window_opts);
  SDL_SetWindowFullscreen(window,
    n == WIN_FULLSCREEN ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
  if (n == WIN_NORMAL) { SDL_RestoreWindow(window); }
  if (n == WIN_MAXIMIZED) { SDL_MaximizeWindow(window); }
  return 0;
}


static int f_window_has_focus(lua_State *L) {
  unsigned flags = SDL_GetWindowFlags(window);
  lua_pushboolean(L, flags & SDL_WINDOW_INPUT_FOCUS);
  return 1;
}


static int f_show_confirm_dialog(lua_State *L) {
  const char *title = luaL_checkstring(L, 1);
  const char *msg = luaL_checkstring(L, 2);

#if _WIN32
  int id = MessageBox(0, msg, title, MB_YESNO | MB_ICONWARNING);
  lua_pushboolean(L, id == IDYES);

#else
  SDL_MessageBoxButtonData buttons[] = {
    { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 1, "Yes" },
    { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 0, "No" },
  };
  SDL_MessageBoxData data = {
    .title = title,
    .message = msg,
    .numbuttons = 2,
    .buttons = buttons,
  };
  int buttonid;
  SDL_ShowMessageBox(&data, &buttonid);
  lua_pushboolean(L, buttonid == 1);
#endif
  return 1;
}


static int f_chdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int err = uv_chdir(path);
  if (err) { luaL_error(L, "chdir() failed: %s", uv_strerror(err)); }
  return 0;
}


static int f_list_dir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

  uv_fs_t req;
  int n = uv_fs_scandir(NULL, &req, path, 0, NULL);
  if (n < 0) {
    uv_fs_req_cleanup(&req);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(n));
    return 2;
  }

  lua_newtable(L);
  int i = 1;
  uv_dirent_t entry;
  /* uv_fs_scandir_next already filters "." and ".." on every platform. */
  while (uv_fs_scandir_next(&req, &entry) != UV_EOF) {
    lua_pushstring(L, entry.name);
    lua_rawseti(L, -2, i);
    i++;
  }

  uv_fs_req_cleanup(&req);
  return 1;
}


#ifdef _WIN32
  #include <windows.h>
  #define realpath(x, y) _fullpath(y, x, MAX_PATH)
#endif

static int f_absolute_path(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  char *res = realpath(path, NULL);
  if (!res) { return 0; }
  lua_pushstring(L, res);
  free(res);
  return 1;
}


static int f_get_file_info(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

  struct stat s;
  int err = stat(path, &s);
  if (err < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

  lua_newtable(L);
  lua_pushnumber(L, s.st_mtime);
  lua_setfield(L, -2, "modified");

  lua_pushnumber(L, s.st_size);
  lua_setfield(L, -2, "size");

  if (S_ISREG(s.st_mode)) {
    lua_pushstring(L, "file");
  } else if (S_ISDIR(s.st_mode)) {
    lua_pushstring(L, "dir");
  } else {
    lua_pushnil(L);
  }
  lua_setfield(L, -2, "type");

  return 1;
}


static int f_get_clipboard(lua_State *L) {
  char *text = SDL_GetClipboardText();
  if (!text) { return 0; }
  lua_pushstring(L, text);
  SDL_free(text);
  return 1;
}


static int f_set_clipboard(lua_State *L) {
  const char *text = luaL_checkstring(L, 1);
  SDL_SetClipboardText(text);
  return 0;
}


static int f_get_time(lua_State *L) {
  double n = SDL_GetPerformanceCounter() / (double) SDL_GetPerformanceFrequency();
  lua_pushnumber(L, n);
  return 1;
}


static int f_sleep(lua_State *L) {
  double n = luaL_checknumber(L, 1);
  SDL_Delay(n * 1000);
  return 0;
}


static int f_exec(lua_State *L) {
  size_t len;
  const char *cmd = luaL_checklstring(L, 1, &len);
  char *buf = malloc(len + 32);
  if (!buf) { luaL_error(L, "buffer allocation failed"); }
#if _WIN32
  sprintf(buf, "cmd /c \"%s\"", cmd);
  WinExec(buf, SW_HIDE);
#else
  sprintf(buf, "%s &", cmd);
  int res = system(buf);
  (void) res;
#endif
  free(buf);
  return 0;
}


static int f_fuzzy_match(lua_State *L) {
  const char *str = luaL_checkstring(L, 1);
  const char *ptn = luaL_checkstring(L, 2);
  int score = 0;
  int run = 0;

  while (*str && *ptn) {
    while (*str == ' ') { str++; }
    while (*ptn == ' ') { ptn++; }
    if (tolower(*str) == tolower(*ptn)) {
      score += run * 10 - (*str != *ptn);
      run++;
      ptn++;
    } else {
      score -= 10;
      run = 0;
    }
    str++;
  }
  if (*ptn) { return 0; }

  lua_pushnumber(L, score - (int) strlen(str));
  return 1;
}


static const luaL_Reg lib[] = {
  { "save_screenshot",     f_save_screenshot     },
  { "poll_event",          f_poll_event          },
  { "wait_event",          f_wait_event          },
  { "set_cursor",          f_set_cursor          },
  { "set_window_title",    f_set_window_title    },
  { "set_window_size",     f_set_window_size     },
  { "set_window_mode",     f_set_window_mode     },
  { "window_has_focus",    f_window_has_focus    },
  { "show_confirm_dialog", f_show_confirm_dialog },
  { "chdir",               f_chdir               },
  { "list_dir",            f_list_dir            },
  { "absolute_path",       f_absolute_path       },
  { "get_file_info",       f_get_file_info       },
  { "get_clipboard",       f_get_clipboard       },
  { "set_clipboard",       f_set_clipboard       },
  { "get_time",            f_get_time            },
  { "sleep",               f_sleep               },
  { "exec",                f_exec                },
  { "fuzzy_match",         f_fuzzy_match         },
  { NULL, NULL }
};


int luaopen_system(lua_State *L) {
  luaL_newlib(L, lib);
  /* The watcher arrives with the rest of the platform surface rather than as a
   * separate module: the project scanner is the only caller, and it already
   * reaches for system.list_dir and system.get_file_info beside it. */
  dirmonitor_open(L);
  return 1;
}
