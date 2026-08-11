/* boggart.c -- entry point.
 *
 * The C core is deliberately dumb: it builds a Lua state, exposes three
 * capability libraries (http, sys, and the boggart table with the embedded
 * default scripts), parses argv into boggart.mode/args, then hands control to
 * the embedded `boot` module. Everything interesting -- the agent loop, tools,
 * memory, the overlay/mutability system -- is Lua.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "embedded.h"

#define BOGGART_VERSION "0.1.0"

int luaopen_boggart_http(lua_State *L);
int luaopen_boggart_sys(lua_State *L);
int luaopen_boggart_db(lua_State *L);
int luaopen_boggart_swarm(lua_State *L);
int luaopen_boggart_mcp(lua_State *L);
int luaopen_boggart_auth(lua_State *L);
lua_State *boggart_newstate(void);       /* src/lmem.c: counts real bytes */
void boggart_open_mem(lua_State *L);
int luaopen_ltui_lcurses(lua_State *L); /* vendored ltui curses binding */
int luaopen_luv(lua_State *L);          /* vendored luv: libuv bindings for Lua */

/* boggart.embedded(name) -> source string | nil */
static int l_embedded(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  size_t len = 0;
  const char *src = boggart_embedded_get(name, &len);
  if (!src) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, src, len);
  return 1;
}

/* boggart.embedded_names() -> { name, ... } */
static int l_embedded_names(lua_State *L) {
  size_t n = boggart_embedded_count();
  lua_createtable(L, (int)n, 0);
  for (size_t i = 0; i < n; i++) {
    lua_pushstring(L, boggart_embedded_name(i));
    lua_rawseti(L, -2, (int)i + 1);
  }
  return 1;
}

static void push_argv(lua_State *L, int argc, char **argv, int from) {
  lua_newtable(L);
  int j = 0;
  for (int i = from; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, ++j);
  }
}

/* Parse argv into fields on the boggart table (already on top of stack). */
static void configure(lua_State *L, int argc, char **argv) {
  const char *mode = "repl";
  const char *eval_file = NULL;
  const char *reset_target = NULL;
  const char *prompt = NULL;
  const char *model = NULL;
  int resume = 0;
  int tui = 0;
  const char *resume_id = NULL;
  int consumed = argc; /* index after which remaining args go to boggart.args */

  int i = 1;
  if (i < argc && argv[i][0] != '-') {
    if (strcmp(argv[i], "init") == 0) { mode = "init"; i++; }
    else if (strcmp(argv[i], "swarm") == 0) { mode = "swarm"; i++; }
  }
  for (; i < argc; i++) {
    const char *a = argv[i];
    if (strcmp(a, "--headless") == 0) {
      mode = "headless";
    } else if (strcmp(a, "--eval") == 0 && i + 1 < argc) {
      mode = "eval"; eval_file = argv[++i];
    } else if (strcmp(a, "--reset") == 0) {
      mode = "reset";
      if (i + 1 < argc && argv[i + 1][0] != '-') reset_target = argv[++i];
      else reset_target = "";
    } else if (strcmp(a, "--resume") == 0) {
      resume = 1;
      if (i + 1 < argc && argv[i + 1][0] != '-') resume_id = argv[++i];
    } else if ((strcmp(a, "-p") == 0 || strcmp(a, "--prompt") == 0) && i + 1 < argc) {
      if (strcmp(mode, "headless") != 0 && strcmp(mode, "swarm") != 0) mode = "oneshot";
      prompt = argv[++i];
    } else if (strcmp(a, "--model") == 0 && i + 1 < argc) {
      model = argv[++i];
    } else if (strcmp(a, "--tui") == 0) {
      tui = 1;
    } else if (strcmp(a, "--") == 0) {
      consumed = i + 1;
      break;
    } else if (a[0] != '-') {
      /* a bare argument is a one-shot prompt (repl) or the task (swarm) */
      if (strcmp(mode, "repl") == 0) { mode = "oneshot"; prompt = a; }
      else if (strcmp(mode, "swarm") == 0 && prompt == NULL) { prompt = a; }
    }
  }

  lua_pushstring(L, mode);           lua_setfield(L, -2, "mode");
  if (eval_file)    { lua_pushstring(L, eval_file);    lua_setfield(L, -2, "eval_file"); }
  if (reset_target) { lua_pushstring(L, reset_target); lua_setfield(L, -2, "reset_target"); }
  if (prompt)       { lua_pushstring(L, prompt);       lua_setfield(L, -2, "prompt"); }
  if (model)        { lua_pushstring(L, model);        lua_setfield(L, -2, "model"); }
  lua_pushboolean(L, resume);        lua_setfield(L, -2, "resume");
  lua_pushboolean(L, tui);           lua_setfield(L, -2, "tui");
  if (resume_id)    { lua_pushstring(L, resume_id);    lua_setfield(L, -2, "resume_id"); }
  push_argv(L, argc, argv, consumed);  lua_setfield(L, -2, "args");
}

static void register_boggart(lua_State *L, int argc, char **argv) {
  /* http, sys libs */
  luaL_requiref(L, "http", luaopen_boggart_http, 0);
  lua_setglobal(L, "http");
  luaL_requiref(L, "sys", luaopen_boggart_sys, 0);
  lua_setglobal(L, "sys");
  luaL_requiref(L, "db", luaopen_boggart_db, 0);
  lua_setglobal(L, "db");
  luaL_requiref(L, "swarm", luaopen_boggart_swarm, 0);
  lua_setglobal(L, "swarm");
  luaL_requiref(L, "mcp", luaopen_boggart_mcp, 0);
  lua_setglobal(L, "mcp");
  luaL_requiref(L, "auth", luaopen_boggart_auth, 0);
  lua_setglobal(L, "auth");

  /* ltui's curses binding, as package.preload["ltui.lcurses"] rather than an
   * eager require: opening it allocates metatables and calls setlocale, which
   * no headless or one-shot run should pay for. lua/ltui/curses.lua requires
   * it by that exact name, so the TUI pulls it in on demand. */
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, luaopen_ltui_lcurses);
  lua_setfield(L, -2, "ltui.lcurses");
  /* luv, as require("uv"). Preload rather than a global: opening it creates a
   * uv_loop_t for this lua_State, which a headless one-shot run has no use
   * for. Everything asynchronous -- spawn, pipes, timers, async wakeups --
   * goes through this, in Lua, where the agent can rewrite it. */
  lua_pushcfunction(L, luaopen_luv);
  lua_setfield(L, -2, "uv");
  lua_pop(L, 2);

  /* the boggart table */
  lua_newtable(L);
  lua_pushstring(L, BOGGART_VERSION);      lua_setfield(L, -2, "version");
  lua_pushcfunction(L, l_embedded);        lua_setfield(L, -2, "embedded");
  lua_pushcfunction(L, l_embedded_names);  lua_setfield(L, -2, "embedded_names");
  configure(L, argc, argv);
  lua_setglobal(L, "boggart");
}

static int msghandler(lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  if (msg == NULL) msg = "(non-string error)";
  luaL_traceback(L, L, msg, 1);
  return 1;
}

int main(int argc, char **argv) {
  /* Counting allocator rather than luaL_newstate: the generated-tool memory
   * limit needs real byte counts, which the GC no longer reports for strings
   * on Lua 5.5. See src/lmem.c. */
  lua_State *L = boggart_newstate();
  if (!L) { fprintf(stderr, "boggart: cannot create Lua state\n"); return 1; }
  luaL_openlibs(L);
  register_boggart(L, argc, argv);
  boggart_open_mem(L);

  size_t len = 0;
  const char *boot = boggart_embedded_get("boot", &len);
  if (!boot) {
    fprintf(stderr, "boggart: embedded boot module missing\n");
    lua_close(L);
    return 1;
  }

  lua_pushcfunction(L, msghandler);
  int base = lua_gettop(L);
  if (luaL_loadbuffer(L, boot, len, "@boot") != LUA_OK) {
    fprintf(stderr, "boggart: boot load error: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 1;
  }
  int rc = lua_pcall(L, 0, 1, base);
  int status = 0;
  if (rc != LUA_OK) {
    fprintf(stderr, "boggart: %s\n", lua_tostring(L, -1));
    status = 1;
  } else if (lua_isinteger(L, -1)) {
    status = (int)lua_tointeger(L, -1);
  }
  lua_close(L);
  return status;
}
