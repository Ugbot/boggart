#include <SDL3/SDL.h>
#include <stdbool.h>
#include <ctype.h>
#include <stdlib.h>
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
 * lite renders into the pixel-sized backing store, while SDL delivers mouse
 * coordinates in window points. With SDL_WINDOW_HIGH_PIXEL_DENSITY that ratio
 * is not 1. Passing points straight through on a Retina display lands the
 * pointer at half the position everything was drawn at.
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
static int px(float points) {
  /* Round to nearest for BOTH signs: `+ 0.5` then truncate-toward-zero biases
   * negative coordinates (xrel/yrel on drag) up to a pixel the wrong way. */
  double v = (double)points * input_scale();
  return (int)(v + (v < 0 ? -0.5 : 0.5));
}

static const char* button_name(int button) {
  switch (button) {
    case 1  : return "left";
    case 2  : return "middle";
    case 3  : return "right";
    default : return "?";
  }
}


static char* key_name(char *dst, size_t cap, SDL_Keycode sym) {
  /* SDL3 key names can be long ("Keypad MemMultiply", "MediaTrackPrevious") --
   * well over the old 16-byte buffer, so strcpy here smashed f_poll_event's
   * stack on one exotic keypress. Bound it. */
  const char *name = SDL_GetKeyName(sym);
  snprintf(dst, cap, "%s", name ? name : "");
  for (char *p = dst; *p; p++) { *p = tolower((unsigned char)*p); }
  return dst;
}


static int f_poll_event(lua_State *L) {
  char buf[64];
  float mx, my;
  int wx, wy;
  SDL_Event e;

top:
  if ( !SDL_PollEvent(&e) ) {
    return 0;
  }

  switch (e.type) {
    case SDL_EVENT_QUIT:
      lua_pushstring(L, "quit");
      return 1;

    case SDL_EVENT_WINDOW_RESIZED:
      /* Re-measure the backing scale: a window dragged between a Retina
       * display and an external monitor changes the points-to-pixels ratio,
       * and a stale value puts the pointer back in the wrong place. */
      g_input_scale = 0.0;
      lua_pushstring(L, "resized");
      /* data1/data2 are points; lite's layout is in pixels. */
      lua_pushnumber(L, px((float)e.window.data1));
      lua_pushnumber(L, px((float)e.window.data2));
      return 3;

    case SDL_EVENT_WINDOW_EXPOSED:
      g_input_scale = 0.0;
      rencache_invalidate();
      lua_pushstring(L, "exposed");
      return 1;

    case SDL_EVENT_WINDOW_FOCUS_GAINED:
      g_input_scale = 0.0;
      /* on some systems, when alt-tabbing to the window SDL will queue up
      ** several KEYDOWN events for the `tab` key; we flush all keydown
      ** events on focus so these are discarded */
      SDL_FlushEvent(SDL_EVENT_KEY_DOWN);
      goto top;

    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
    case SDL_EVENT_WINDOW_DISPLAY_CHANGED:
      g_input_scale = 0.0;
      goto top;

    case SDL_EVENT_DROP_FILE:
      SDL_GetGlobalMouseState(&mx, &my);
      SDL_GetWindowPosition(window, &wx, &wy);
      lua_pushstring(L, "filedropped");
      lua_pushstring(L, e.drop.data ? e.drop.data : "");
      lua_pushnumber(L, px(mx - (float)wx));
      lua_pushnumber(L, px(my - (float)wy));
      return 4;

    case SDL_EVENT_KEY_DOWN:
      lua_pushstring(L, "keypressed");
      lua_pushstring(L, key_name(buf, sizeof(buf), e.key.key));
      return 2;

    case SDL_EVENT_KEY_UP:
      lua_pushstring(L, "keyreleased");
      lua_pushstring(L, key_name(buf, sizeof(buf), e.key.key));
      return 2;

    case SDL_EVENT_TEXT_INPUT:
      lua_pushstring(L, "textinput");
      lua_pushstring(L, e.text.text);
      return 2;

    case SDL_EVENT_MOUSE_BUTTON_DOWN:
      if (e.button.button == 1) { SDL_CaptureMouse(true); }
      lua_pushstring(L, "mousepressed");
      lua_pushstring(L, button_name(e.button.button));
      lua_pushnumber(L, px(e.button.x));
      lua_pushnumber(L, px(e.button.y));
      lua_pushnumber(L, e.button.clicks);
      return 5;

    case SDL_EVENT_MOUSE_BUTTON_UP:
      if (e.button.button == 1) { SDL_CaptureMouse(false); }
      lua_pushstring(L, "mousereleased");
      lua_pushstring(L, button_name(e.button.button));
      lua_pushnumber(L, px(e.button.x));
      lua_pushnumber(L, px(e.button.y));
      return 4;

    case SDL_EVENT_MOUSE_MOTION:
      lua_pushstring(L, "mousemoved");
      lua_pushnumber(L, px(e.motion.x));
      lua_pushnumber(L, px(e.motion.y));
      lua_pushnumber(L, px(e.motion.xrel));
      lua_pushnumber(L, px(e.motion.yrel));
      return 5;

    case SDL_EVENT_MOUSE_WHEEL:
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


static SDL_Cursor* cursor_cache[5];

static const char *cursor_opts[] = {
  "arrow",
  "ibeam",
  "sizeh",
  "sizev",
  "hand",
  NULL
};

static const SDL_SystemCursor cursor_enums[] = {
  SDL_SYSTEM_CURSOR_DEFAULT,
  SDL_SYSTEM_CURSOR_TEXT,
  SDL_SYSTEM_CURSOR_EW_RESIZE,
  SDL_SYSTEM_CURSOR_NS_RESIZE,
  SDL_SYSTEM_CURSOR_POINTER
};

static int f_set_cursor(lua_State *L) {
  int opt = luaL_checkoption(L, 1, "arrow", cursor_opts);
  SDL_Cursor *cursor = cursor_cache[opt];
  if (!cursor) {
    cursor = SDL_CreateSystemCursor(cursor_enums[opt]);
    cursor_cache[opt] = cursor;
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
 * BMP because SDL can write it with no extra dependency, which is the whole
 * bar for a diagnostic. */
static int f_save_screenshot(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  if (ren_save_screenshot(path) != 0) {
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
 * the frame loop reads renderer.get_size() from the retained backbuffer every
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
  SDL_SyncWindow(window);
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
  SDL_SetWindowFullscreen(window, n == WIN_FULLSCREEN);
  if (n == WIN_NORMAL) { SDL_RestoreWindow(window); }
  if (n == WIN_MAXIMIZED) { SDL_MaximizeWindow(window); }
  return 0;
}


static int f_window_has_focus(lua_State *L) {
  SDL_WindowFlags flags = SDL_GetWindowFlags(window);
  lua_pushboolean(L, (flags & SDL_WINDOW_INPUT_FOCUS) != 0);
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
  int buttonid = 0;   /* not written if the dialog fails to show */
  if (!SDL_ShowMessageBox(&data, &buttonid)) { buttonid = 0; }
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


#ifndef _WIN32
extern uv_loop_t *luv_loop(lua_State *L);

/* A detached child reaped by libuv: uv_spawn already forwards SIGCHLD to the
 * loop's handler, so this fires without us blocking. Free the heap process
 * handle the spawn allocated. */
static void on_exec_exit(uv_process_t *proc, int64_t status, int sig) {
  (void) status; (void) sig;
  uv_close((uv_handle_t *)proc, (uv_close_cb)free);
}

/* Split `cmd` into an argv the way the one caller builds it -- Lua's
 * string.format("%q %q", ...), i.e. double-quoted tokens with backslash
 * escapes. Whitespace separates tokens outside quotes; \\ and \" are literals.
 * Returns a NULL-terminated, heap-allocated argv (each entry heap-allocated),
 * or NULL if there are no tokens. Deliberately NOT a shell: no globbing, no
 * pipes, no injection surface -- the child is exec'd directly. */
static char **tokenize_argv(const char *cmd) {
  size_t cap = 8, argc = 0;
  char **argv = malloc(cap * sizeof(char *));
  if (!argv) { return NULL; }
  char *tok = malloc(strlen(cmd) + 1);      /* a token is never longer than cmd */
  if (!tok) { free(argv); return NULL; }
  const char *p = cmd;
  while (*p) {
    while (*p == ' ' || *p == '\t' || *p == '\n') { p++; }
    if (!*p) { break; }
    size_t n = 0; int quoted = 0;
    while (*p && (quoted || (*p != ' ' && *p != '\t' && *p != '\n'))) {
      if (*p == '"') { quoted = !quoted; p++; continue; }
      if (*p == '\\' && (p[1] == '"' || p[1] == '\\')) { p++; }
      tok[n++] = *p++;
    }
    tok[n] = '\0';
    if (argc + 1 >= cap) {
      cap *= 2;
      char **grown = realloc(argv, cap * sizeof(char *));
      if (!grown) { break; }
      argv = grown;
    }
    argv[argc] = malloc(n + 1);
    if (!argv[argc]) { break; }
    memcpy(argv[argc], tok, n + 1);
    argc++;
  }
  free(tok);
  argv[argc] = NULL;
  if (argc == 0) { free(argv); return NULL; }
  return argv;
}

static void free_argv(char **argv) {
  for (size_t i = 0; argv[i]; i++) { free(argv[i]); }
  free(argv);
}
#endif

/* Fire-and-forget launch of another program (studio uses it to open a file in a
 * fresh window). Non-blocking: the old implementation shelled out via
 * system("cmd &"), which forks a shell on the UI thread and leaks it as a
 * zombie. uv_spawn execs the child directly on the main loop and libuv reaps
 * it, so the UI never stalls and nothing is left behind. */
static int f_exec(lua_State *L) {
  size_t len;
  const char *cmd = luaL_checklstring(L, 1, &len);
#if _WIN32
  char *buf = malloc(len + 32);
  if (!buf) { luaL_error(L, "buffer allocation failed"); }
  sprintf(buf, "cmd /c \"%s\"", cmd);
  WinExec(buf, SW_HIDE);
  free(buf);
#else
  char **argv = tokenize_argv(cmd);
  if (!argv) { return 0; }   /* empty command: nothing to do */

  uv_process_t *proc = calloc(1, sizeof *proc);
  if (!proc) { free_argv(argv); luaL_error(L, "process allocation failed"); }

  uv_stdio_container_t stdio[3];
  stdio[0].flags = UV_INHERIT_FD; stdio[0].data.fd = 0;
  stdio[1].flags = UV_INHERIT_FD; stdio[1].data.fd = 1;
  stdio[2].flags = UV_INHERIT_FD; stdio[2].data.fd = 2;

  uv_process_options_t opts;
  memset(&opts, 0, sizeof opts);
  opts.file = argv[0];
  opts.args = argv;
  opts.exit_cb = on_exec_exit;
  opts.flags = UV_PROCESS_DETACHED;
  opts.stdio_count = 3;
  opts.stdio = stdio;

  int r = uv_spawn(luv_loop(L), proc, &opts);
  if (r != 0) {
    uv_close((uv_handle_t *)proc, (uv_close_cb)free);
    free_argv(argv);
    luaL_error(L, "exec failed: %s", uv_strerror(r));
  }
  /* Detached and unref'd: the child outlives us and never keeps the loop
   * (hence the process) alive on its own account. */
  uv_unref((uv_handle_t *)proc);
  free_argv(argv);   /* libuv copies argv during spawn */
#endif
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
