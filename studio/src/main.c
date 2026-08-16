#include <stdio.h>
#include <SDL2/SDL.h>
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

#ifdef _WIN32
  #include <windows.h>
#elif __linux__
  #include <unistd.h>
#elif __APPLE__
  #include <mach-o/dyld.h>
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
 *     SDL_WINDOW_ALLOW_HIGHDPI that is 2.0 on a Retina display.
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
  SDL_GetRendererOutputSize(SDL_GetRenderer(window), &px_w, &px_h);
  if (px_w <= 0 || win_w <= 0) {
    /* No renderer (lite draws into the window surface): ask the surface. */
    SDL_Surface *s = SDL_GetWindowSurface(window);
    if (s) { px_w = s->w; px_h = s->h; }
  }
  if (px_w > 0 && win_w > 0) {
    double s = (double)px_w / (double)win_w;
    if (s > 0.1 && s < 8.0) return s;
  }
#if _WIN32
  {
    float dpi;
    if (SDL_GetDisplayDPI(0, NULL, &dpi, NULL) == 0 && dpi > 0) return dpi / 96.0;
  }
#endif
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
  sprintf(path, "/proc/%d/exe", getpid());
  int len = readlink(path, buf, sz - 1);
  buf[len] = '\0';
#elif __APPLE__
  unsigned size = sz;
  _NSGetExecutablePath(buf, &size);
#else
  strcpy(buf, "./boggart-studio");
#endif
}


static void init_window_icon(void) {
#ifndef _WIN32
  #include "../icon.inl"
  (void) icon_rgba_len; /* unused */
  SDL_Surface *surf = SDL_CreateRGBSurfaceFrom(
    icon_rgba, 64, 64,
    32, 64 * 4,
    0x000000ff,
    0x0000ff00,
    0x00ff0000,
    0xff000000);
  SDL_SetWindowIcon(window, surf);
  SDL_FreeSurface(surf);
#endif
}


int main(int argc, char **argv) {
#ifdef _WIN32
  HINSTANCE lib = LoadLibrary("user32.dll");
  int (*SetProcessDPIAware)() = (void*) GetProcAddress(lib, "SetProcessDPIAware");
  SetProcessDPIAware();
#endif

  SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS);
  SDL_EnableScreenSaver();
  SDL_EventState(SDL_DROPFILE, SDL_ENABLE);
  atexit(SDL_Quit);

#ifdef SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR /* Available since 2.0.8 */
  SDL_SetHint(SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
#endif
#if SDL_VERSION_ATLEAST(2, 0, 5)
  SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
#endif

  SDL_DisplayMode dm;
  SDL_GetCurrentDisplayMode(0, &dm);

  window = SDL_CreateWindow(
    "", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED, dm.w * 0.8, dm.h * 0.8,
    SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_HIDDEN);
  init_window_icon();
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
  lua_close(L);
  SDL_DestroyWindow(window);

  return EXIT_SUCCESS;
}
