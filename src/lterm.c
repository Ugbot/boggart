/* lterm.c -- the terminal's interactive layer.
 *
 * Right now: Tab completion. Later phases (see docs/cli-plan.md) add the syntax
 * highlighter and the status line here too. The mechanism lives in C because the
 * isocline callbacks are C; the *candidates* come from Lua (bog.complete), so no
 * command, tool, model or session list is ever duplicated into C -- the same
 * boundary the worker registry and the parity fingerprint hold.
 *
 * One interpreter, one thread. The CLI REPL calls ic_readline() from Lua, and
 * isocline calls straight back into that same lua_State when Tab is pressed. So
 * the completer reuses the REPL's state (handed to it as the completer arg via
 * ic_completion_arg) and a single static buffer for the current line -- there is
 * no second thread to race with, and nothing here is reached from the studio,
 * which has no isocline REPL.
 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifndef _WIN32
#include <sys/ioctl.h>
#endif

#include "lua.h"
#include "lauxlib.h"
#include "isocline.h"

/* The input up to the cursor, stashed by the outer completer so the inner word
 * handler -- which isocline only hands the current token -- can send the whole
 * line to bog.complete for context: is this the command, or one of its args? */
static char g_line[4096];

/* Everything that is not whitespace is part of a "word", so "/model" and
 * "@lua/api.lua" each stay a single token that a completion replaces whole
 * (isocline's default word boundary would split on the '/'). */
static bool word_char(const char *s, long len) {
  if (len != 1) return true; /* any continuation byte of a multibyte char */
  char c = s[0];
  return !(c == ' ' || c == '\t' || c == '\n' || c == '\r');
}

/* Ask bog.complete(g_line) and feed each {text, display?, help?} to the menu.
 * isocline (via ic_complete_word) replaces the current word with `text`, so
 * `text` is a full-token replacement. Any Lua error is swallowed: a completer
 * runs inside a keystroke and must never raise. */
static void add_candidates(ic_completion_env_t *cenv, const char *word) {
  (void) word;
  lua_State *L = (lua_State *) ic_completion_arg(cenv);
  if (!L) return;
  int top = lua_gettop(L);
  lua_getglobal(L, "bog");
  lua_getfield(L, -1, "complete");
  if (!lua_isfunction(L, -1)) { lua_settop(L, top); return; }
  lua_pushstring(L, g_line);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) { lua_settop(L, top); return; }
  if (lua_istable(L, -1)) {
    lua_Integer n = luaL_len(L, -1);
    for (lua_Integer i = 1; i <= n; i++) {
      lua_rawgeti(L, -1, i); /* item */
      if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "text");
        lua_getfield(L, -2, "display");
        lua_getfield(L, -3, "help");
        const char *text = lua_tostring(L, -3);
        const char *display = lua_tostring(L, -2);
        const char *help = lua_tostring(L, -1);
        bool more = true;
        if (text && *text) more = ic_add_completion_ex(cenv, text, display, help);
        lua_pop(L, 4); /* help, display, text, item */
        if (!more) break; /* isocline: enough, stop for latency */
      } else {
        lua_pop(L, 1); /* item */
      }
    }
  }
  lua_settop(L, top);
}

/* The default completer isocline calls on Tab: stash the whole line, then let
 * isocline peel the current word (and re-attach the chosen replacement) around
 * add_candidates. */
static void completer(ic_completion_env_t *cenv, const char *prefix) {
  snprintf(g_line, sizeof g_line, "%s", prefix ? prefix : "");
  ic_complete_word(cenv, prefix, add_candidates, word_char);
}

/* The syntax highlighter isocline runs as the line is edited. Like the
 * completer, the mechanism is here but the policy is in Lua: bog.repl_style(line)
 * returns { {pos, len, style}, ... } (byte offsets, and one of the named styles
 * defined in l_enable), and this applies each span. Its whole point is that an
 * unknown /command is coloured as an error before Enter is ever pressed. Errors
 * are swallowed -- it runs on every keystroke and must never raise. */
static void highlighter(ic_highlight_env_t *henv, const char *input, void *arg) {
  lua_State *L = (lua_State *) arg;
  if (!L || !input) return;
  int top = lua_gettop(L);
  lua_getglobal(L, "bog");
  lua_getfield(L, -1, "repl_style");
  if (!lua_isfunction(L, -1)) { lua_settop(L, top); return; }
  lua_pushstring(L, input);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) { lua_settop(L, top); return; }
  if (lua_istable(L, -1)) {
    lua_Integer n = luaL_len(L, -1);
    for (lua_Integer i = 1; i <= n; i++) {
      lua_rawgeti(L, -1, i);
      if (lua_istable(L, -1)) {
        lua_getfield(L, -1, "pos");
        lua_getfield(L, -2, "len");
        lua_getfield(L, -3, "style");
        long pos = (long) luaL_optinteger(L, -3, -1);
        long len = (long) luaL_optinteger(L, -2, 0);
        const char *style = lua_tostring(L, -1);
        if (pos >= 0 && len > 0 && style) ic_highlight(henv, pos, len, style);
        lua_pop(L, 3);
      }
      lua_pop(L, 1);
    }
  }
  lua_settop(L, top);
}

/* term.size() -> width, height. The terminal's cell dimensions, so the renderer
 * can wrap and the status line can fill the row. 80x24 if it cannot be asked.
 *
 * Precedence: a live tty (TIOCGWINSZ) first, then the COLUMNS/LINES environment
 * as an override/fallback. The env matters in two cases the ioctl cannot serve:
 * output piped to a file or another process (no tty, so ws.ws_col is 0), and a
 * deliberate override (COLUMNS=100 boggart ...) used to render at a fixed width
 * -- the same convention readline and isocline honour. An env value only counts
 * when it parses to a positive integer, so an empty or junk COLUMNS is ignored
 * rather than collapsing the width to zero. */
static int env_dim(const char *name) {
  const char *v = getenv(name);
  if (!v || !*v) { return 0; }
  char *end = NULL;
  long n = strtol(v, &end, 10);
  if (end == v || n <= 0 || n > 100000) { return 0; }
  return (int) n;
}

static int l_size(lua_State *L) {
  int w = 80, h = 24;
#ifndef _WIN32
  struct winsize ws;
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
    w = ws.ws_col;
    h = ws.ws_row > 0 ? ws.ws_row : h;
  }
#endif
  int ec = env_dim("COLUMNS"); if (ec > 0) { w = ec; }
  int er = env_dim("LINES");   if (er > 0) { h = er; }
  lua_pushinteger(L, w);
  lua_pushinteger(L, h);
  return 2;
}

/* term.istty() -> bool. True only when both ends are a real terminal, so the
 * REPL knows to colour, animate a spinner and paint a status line -- and to do
 * none of that when piped, where the output must stay clean. */
static int l_istty(lua_State *L) {
  lua_pushboolean(L, isatty(STDIN_FILENO) && isatty(STDOUT_FILENO));
  return 1;
}

/* term.enable() -- register the completer and highlighter against this
 * interpreter and switch on the isocline niceties. Idempotent; the REPL calls it
 * once at start-up. */
static int l_enable(lua_State *L) {
  ic_set_default_completer(completer, L);
  ic_set_default_highlighter(highlighter, L);
  /* The named styles the highlighter refers to, from the studio palette
   * (style.lua): a valid command reads as "good", an unknown one as "error",
   * an @file reference as a link. Defined once here so Lua names them, not
   * hexes. */
  ic_style_def("bog-cmd", "color=#7fb77e");
  ic_style_def("bog-bad", "color=#f77483");
  ic_style_def("bog-file", "color=#93ddfa");
  ic_enable_highlight(true);
  ic_enable_completion_preview(true); /* show the top completion inline */
  ic_enable_hint(true);               /* and a candidate's help as a dim hint */
  ic_enable_inline_help(true);
  ic_enable_auto_tab(true); /* Tab first fills the unambiguous common prefix */
  return 0;
}

static const luaL_Reg term_lib[] = {
  {"enable", l_enable},
  {"size", l_size},
  {"istty", l_istty},
  {NULL, NULL},
};

int luaopen_boggart_term(lua_State *L) {
  luaL_newlib(L, term_lib);
  return 1;
}
