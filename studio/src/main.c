#include <stdio.h>
#include <stdlib.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include "api/api.h"
#include "renderer.h"
#include "assets.h"
#include "version.h" /* BOGGART_VERSION, shared with the CLI so they can't drift */

/* boggart, embedded. See src/bogembed.c for why the agent shares this exact
 * lua_State rather than living in a subprocess. */
void boggart_open_libs(lua_State *L);
int  boggart_boot(lua_State *L, const char *mode, const char *version);
lua_State *boggart_newstate(void);
void boggart_http_shutdown(lua_State *L); /* src/lhttp.c: close raw uv handles before lua_close */
void boggart_voice_shutdown(void); /* src/lvoice.c: free the warm whisper ctx before exit */

#ifdef _WIN32
  #include <windows.h>
#elif __linux__
  #include <unistd.h>
#elif __APPLE__
  #include <mach-o/dyld.h>
#endif
#ifndef _WIN32
  #include <signal.h>
#endif


SDL_Window *window;


/* The backing-store scale factor.
 *
 * Upstream lite asks SDL_GetDisplayDPI and divides by 96, falling back to 1.0
 * everywhere but Windows. Both halves are wrong on a Retina Mac:
 *
 *   - macOS reports 72 DPI, not 96, so even the DPI path would give 0.75.
 *   - The real scaling on macOS is not a DPI at all. It is the ratio between
 *     the window in *points* and its drawable in *pixels*, and with
 *     SDL_WINDOW_HIGH_PIXEL_DENSITY that is 2.0 on a Retina display.
 *
 * Returning 1.0 there is what makes every font and padding render at half its
 * intended physical size. Measuring the ratio directly is correct on every
 * platform, including mixed-DPI setups and a window dragged between displays,
 * so the Windows special case goes away too.
 *
 * Note this must be called *after* the window exists, unlike the original. */
static double get_scale(void) {
  if (!window) return 1.0;
  int win_w = 0, win_h = 0, px_w = 0, px_h = 0;
  SDL_GetWindowSize(window, &win_w, &win_h);
  SDL_GetWindowSizeInPixels(window, &px_w, &px_h);
  if (px_w > 0 && win_w > 0) {
    double s = (double)px_w / (double)win_w;
    if (s > 0.1 && s < 8.0) return s;
  }
  return 1.0;
}

/* Exported so api/system.c can convert incoming mouse coordinates from points
 * to pixels -- see the note there. */
double studio_get_scale(void) { return get_scale(); }


static void get_exe_filename(char *buf, int sz) {
#if _WIN32
  int len = GetModuleFileName(NULL, buf, sz - 1);
  buf[len] = '\0';
#elif __linux__
  char path[512];
  snprintf(path, sizeof(path), "/proc/%d/exe", getpid());
  ssize_t len = readlink(path, buf, sz - 1);
  if (len <= 0) { strcpy(buf, "./boggart-studio"); }  /* readlink can return -1 */
  else { buf[len] = '\0'; }
#elif __APPLE__
  unsigned size = sz;
  if (_NSGetExecutablePath(buf, &size) != 0) { strcpy(buf, "./boggart-studio"); }
#else
  strcpy(buf, "./boggart-studio");
#endif
}


static void init_window_icon(void) {
#ifndef _WIN32
  #include "../icon.inl"
  (void) icon_rgba_len; /* unused */
  SDL_Surface *surf = SDL_CreateSurfaceFrom(
    64, 64, SDL_PIXELFORMAT_ABGR8888, (void *)icon_rgba, 64 * 4);
  SDL_SetWindowIcon(window, surf);
  SDL_DestroySurface(surf);
#endif
}


int main(int argc, char **argv) {
#ifdef _WIN32
  /* Best-effort: on a stripped system either call can fail, and calling through
   * a NULL pointer would crash before the window ever opens. SDL sets DPI
   * awareness itself with SDL_WINDOW_HIGH_PIXEL_DENSITY, so skipping this is
   * merely belt-and-braces, not fatal. */
  HINSTANCE lib = LoadLibrary("user32.dll");
  if (lib) {
    int (*SetProcessDPIAware)() = (void*) GetProcAddress(lib, "SetProcessDPIAware");
    if (SetProcessDPIAware) { SetProcessDPIAware(); }
  }
#endif
#ifndef _WIN32
  /* MCP servers are stdio children. If one abort()s, a later write to the
   * pipe is SIGPIPE. That must not take the window down; a dead MCP server
   * is a missing tool, not a crash. The CLI already ignores it in termctl.c. */
  signal(SIGPIPE, SIG_IGN);
#endif

  if (!SDL_Init(SDL_INIT_VIDEO)) {
    fprintf(stderr, "boggart-studio: SDL_Init failed: %s\n", SDL_GetError());
    return EXIT_FAILURE;
  }
  SDL_EnableScreenSaver();
  atexit(SDL_Quit);

  SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
  SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");

  const SDL_DisplayID display = SDL_GetPrimaryDisplay();
  const SDL_DisplayMode *dm = SDL_GetCurrentDisplayMode(display);
  int win_w = 800, win_h = 600;
  if (dm) {
    win_w = (int)(dm->w * 0.8f);
    win_h = (int)(dm->h * 0.8f);
  }

  window = SDL_CreateWindow(
    "", win_w, win_h,
    SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_HIDDEN);
  if (!window) {
    fprintf(stderr, "boggart-studio: SDL_CreateWindow failed: %s\n", SDL_GetError());
    return EXIT_FAILURE;
  }
  init_window_icon();
  /* SDL3 gates SDL_EVENT_TEXT_INPUT behind an explicit per-window opt-in; without
   * this, plain typing delivers only key events (bindings) and no characters, and
   * IME composition never starts. The rest of the app already consumes
   * "textinput" events (studio/src/api/system.c handles SDL_EVENT_TEXT_INPUT), so
   * enable it once for the main window. */
  SDL_StartTextInput(window);
  ren_init(window);


  lua_State *L = boggart_newstate();
  luaL_openlibs(L);
  api_load_libs(L);

  /* boggart's capabilities, then its harness. Booting before lite's Lua runs
   * means `bog` exists by the time core.init() builds views, and boggart's own
   * overlay path (~/.boggart/lua) is set up independently of lite's. */
  boggart_open_libs(L);
  if (boggart_boot(L, "embedded", BOGGART_VERSION) != 0) {
    fprintf(stderr, "boggart-studio: failed to start the agent harness: %s\n",
            lua_tostring(L, -1));
    /* Not fatal: an editor that cannot reach a model is still an editor. */
    lua_pop(L, 1);
  }


  lua_newtable(L);
  for (int i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setglobal(L, "ARGS");

  lua_pushstring(L, "1.11");
  lua_setglobal(L, "VERSION");

  lua_pushstring(L, SDL_GetPlatform());
  lua_setglobal(L, "PLATFORM");

  lua_pushnumber(L, get_scale());
  lua_setglobal(L, "SCALE");

  char exename[2048];
  get_exe_filename(exename, sizeof(exename));
  lua_pushstring(L, exename);
  lua_setglobal(L, "EXEFILE");


  /* The baked-in studio/data. Installed before the bootstrap so require()
   * can find core/ even when there is no data/ directory anywhere. */
  studio_assets_open(L);

  (void) luaL_dostring(L,
    "local core\n"
    "xpcall(function()\n"
    "  SCALE = tonumber(os.getenv(\"BOGGART_SCALE\")) or SCALE\n"
    "  PATHSEP = package.config:sub(1, 1)\n"
    "  EXEDIR = EXEFILE:match(\"^(.+)[/\\\\].*$\")\n"
    /* Two layouts: installed (data/ beside the binary) and in-tree
     * (studio/data/, where the binary is built to the repo root next to the
     * boggart CLI). Trying both means `./boggart-studio` works from a fresh
     * checkout with no install step. */
    "  package.path = EXEDIR .. '/data/?.lua;' .. package.path\n"
    "  package.path = EXEDIR .. '/data/?/init.lua;' .. package.path\n"
    "  package.path = EXEDIR .. '/studio/data/?.lua;' .. package.path\n"
    "  package.path = EXEDIR .. '/studio/data/?/init.lua;' .. package.path\n"
    "  DATADIR = EXEDIR .. '/data'\n"
    "  if not io.open(DATADIR .. '/core/init.lua') then DATADIR = EXEDIR .. '/studio/data' end\n"
    /* Neither layout exists, so this is a single-file install: fall through
     * to the baked assets. renderer.font.load reads the marker; anything
     * else that pokes at DATADIR (core/init.lua lists a plugins dir) just
     * finds nothing there, which is what it already handles. */
    "  if not io.open(DATADIR .. '/core/init.lua') then DATADIR = '@assets' end\n"
    /* Bring up boggart before the editor: core.init() builds views, and the
     * agent view wants `bog` to already exist. boot in embedded mode wires the
     * harness and opens the store, then returns instead of dispatching a REPL. */
    "  core = require('core')\n"
    "  core.init()\n"
    "  core.run()\n"
    "end, function(err)\n"
    "  print('Error: ' .. tostring(err))\n"
    "  print(debug.traceback(nil, 2))\n"
    "  if core and core.on_error then\n"
    "    pcall(core.on_error, err)\n"
    "  end\n"
    "  os.exit(1)\n"
    "end)");


  /* Close our raw curl-on-libuv handles before lua_close() runs luv's loop_gc,
   * or it type-confuses on their non-luv handle->data and faults at exit -- the
   * same exit crash the CLI had. See boggart_http_shutdown in src/lhttp.c. */
  boggart_http_shutdown(L);
  /* Free the warm whisper context before GGML's Metal device destructors run at
   * exit, which assert every residency set was released. See src/lvoice.c. */
  boggart_voice_shutdown();
  lua_close(L);
  SDL_DestroyWindow(window);

  return EXIT_SUCCESS;
}
