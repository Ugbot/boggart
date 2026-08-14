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
#include <string.h>

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

/* term.enable() -- register the completer against this interpreter and switch on
 * the isocline niceties. Idempotent; the REPL calls it once at start-up. */
static int l_enable(lua_State *L) {
  ic_set_default_completer(completer, L);
  ic_enable_completion_preview(true); /* show the top completion inline */
  ic_enable_hint(true);               /* and a candidate's help as a dim hint */
  ic_enable_inline_help(true);
  ic_enable_auto_tab(true); /* Tab first fills the unambiguous common prefix */
  return 0;
}

static const luaL_Reg term_lib[] = {
  {"enable", l_enable},
  {NULL, NULL},
};

int luaopen_boggart_term(lua_State *L) {
  luaL_newlib(L, term_lib);
  return 1;
}
