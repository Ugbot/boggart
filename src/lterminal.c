/* Lua owns the terminal lifetime; C owns parsing, grid storage and reply bytes.
 * Snapshot/row copies are made only on explicit calls, never while feeding. */
#include "bterm.h"
#include "lua.h"
#include "lauxlib.h"
#include <string.h>
#include "terminal-source.h"
#define TERMINAL_MT "boggart.terminal"
#define REPLY_CAPACITY 65536
typedef struct { bterm *term; size_t reply_length; uint8_t replies[REPLY_CAPACITY]; } terminal;
static terminal *check(lua_State *L) {
  terminal *t = luaL_checkudata(L, 1, TERMINAL_MT);
  luaL_argcheck(L, t->term != NULL, 1, "closed terminal"); return t;
}
static bool reply(void *ctx, const uint8_t *bytes, size_t n) {
  terminal *t = ctx;
  if (n > REPLY_CAPACITY - t->reply_length) return false;
  memcpy(t->replies + t->reply_length, bytes, n); t->reply_length += n; return true;
}
static void integer(lua_State *L, const char *key, lua_Integer n) { lua_pushinteger(L, n); lua_setfield(L, -2, key); }
static void boolean(lua_State *L, const char *key, bool b) { lua_pushboolean(L, b); lua_setfield(L, -2, key); }
static void style(lua_State *L, const lpage_style *s) {
  lua_createtable(L, 0, 4); integer(L, "fg", s->fg); integer(L, "bg", s->bg);
  integer(L, "underline", s->underline); integer(L, "attrs", s->attrs);
}
static void state(lua_State *L, bterm *t) {
  bterm_status s = bterm_state(t);
  lua_createtable(L, 0, 10);
  integer(L, "row", (lua_Integer)s.y + 1); integer(L, "col", (lua_Integer)s.x + 1);
  integer(L, "top", (lua_Integer)s.top + 1); integer(L, "bottom", (lua_Integer)s.bottom + 1);
  integer(L, "modes", s.modes); integer(L, "cursor_style", s.cursor_style);
  boolean(L, "alternate", s.alternate); boolean(L, "pending_wrap", s.pending_wrap);
  style(L, &s.pen); lua_setfield(L, -2, "pen");
}
static void row(lua_State *L, bterm *t, const lpage_row *r) {
  lua_createtable(L, 0, 2); boolean(L, "wrapped", r->wrapped);
  lua_createtable(L, (int)r->columns, 0);
  for (size_t x = 0; x < r->columns; x++) {
    const lpage_cell *c = &r->cells[x];
    lua_createtable(L, 0, 5); integer(L, "codepoint", c->codepoint);
    integer(L, "width", c->width); integer(L, "flags", c->flags); integer(L, "hyperlink", c->hyperlink);
    style(L, bterm_style(t, c->style)); lua_setfield(L, -2, "style");
    lua_rawseti(L, -2, (lua_Integer)x + 1);
  }
  lua_setfield(L, -2, "cells");
}
static void pending(lua_State *L, const lvt_parser *p) {
  lua_createtable(L, 0, 13);
  integer(L, "state", p->state); integer(L, "param_acc", p->param_acc);
  integer(L, "param_digits", p->param_digits); integer(L, "separators", p->separators);
  integer(L, "utf8_acc", p->utf8_acc); integer(L, "utf8_need", p->utf8_need);
  integer(L, "utf8_low", p->utf8_low); integer(L, "utf8_high", p->utf8_high);
  boolean(L, "osc_overflow", p->osc_overflow);
  /* Raw pending bytes are numeric arrays, so unfinished UTF-8/OSC payloads
   * remain JSON-compatible even if they contain invalid UTF-8 or NUL. */
  lua_createtable(L, p->nintermediates, 0);
  for (size_t i = 0; i < p->nintermediates; i++) { lua_pushinteger(L, p->intermediates[i]); lua_rawseti(L, -2, i + 1); }
  lua_setfield(L, -2, "intermediates");
  lua_createtable(L, p->nparams, 0);
  for (size_t i = 0; i < p->nparams; i++) { lua_pushinteger(L, p->params[i]); lua_rawseti(L, -2, i + 1); }
  lua_setfield(L, -2, "params");
  lua_createtable(L, (int)p->osc_length, 0);
  for (size_t i = 0; i < p->osc_length; i++) { lua_pushinteger(L, p->osc[i]); lua_rawseti(L, -2, i + 1); }
  lua_setfield(L, -2, "osc");
}
static int l_new(lua_State *L) {
  lua_Integer cols = luaL_optinteger(L, 1, 80), rows = luaL_optinteger(L, 2, 24), history = luaL_optinteger(L, 3, 2000);
  luaL_argcheck(L, cols > 0 && cols <= 4096, 1, "columns must be in 1..4096");
  luaL_argcheck(L, rows > 0 && rows <= 4096, 2, "rows must be in 1..4096");
  luaL_argcheck(L, history >= 0 && history <= 1000000, 3, "history must be in 0..1000000");
  terminal *t = lua_newuserdatauv(L, sizeof *t, 0); memset(t, 0, sizeof *t);
  luaL_setmetatable(L, TERMINAL_MT);
  t->term = bterm_create((size_t)cols, (size_t)rows, (size_t)history, reply, t);
  if (!t->term) return luaL_error(L, "cannot allocate terminal");
  return 1;
}
static int l_close(lua_State *L) {
  terminal *t = luaL_checkudata(L, 1, TERMINAL_MT);
  bterm_destroy(t->term); t->term = NULL; t->reply_length = 0; return 0;
}
static int l_feed(lua_State *L) {
  terminal *t = check(L); luaL_checktype(L, 2, LUA_TSTRING);
  size_t n; const char *bytes = lua_tolstring(L, 2, &n);
  if (!bterm_feed(t->term, (const uint8_t *)bytes, n)) return luaL_error(L, "terminal allocation or reply queue failure; drain replies and reset");
  return 0;
}
static int l_finish(lua_State *L) { if (!bterm_finish(check(L)->term)) return luaL_error(L, "terminal failed; reset required"); return 0; }
static int l_reset(lua_State *L) {
  terminal *t = check(L); t->reply_length = 0;
  if (!bterm_reset(t->term)) return luaL_error(L, "terminal reset failed"); return 0;
}
static int l_state(lua_State *L) { state(L, check(L)->term); return 1; }
static int l_row(lua_State *L) {
  terminal *t = check(L); lua_Integer index = luaL_checkinteger(L, 2);
  bool history = lua_toboolean(L, 3); const lpage_screen *s = bterm_screen(t->term);
  size_t count = history ? lpage_history_count(s) : lpage_rows(s);
  luaL_argcheck(L, index > 0 && (lua_Unsigned)index <= count, 2, "row out of range");
  row(L, t->term, history ? lpage_history(s, (size_t)index - 1) : lpage_visible(s, (size_t)index - 1)); return 1;
}
static int l_snapshot(lua_State *L) {
  terminal *t = check(L); const lpage_screen *s = bterm_screen(t->term);
  bool history = lua_toboolean(L, 2);
  lua_createtable(L, 0, 6); integer(L, "cols", (lua_Integer)lpage_columns(s)); integer(L, "rows", (lua_Integer)lpage_rows(s));
  state(L, t->term); lua_setfield(L, -2, "state");
  pending(L, bterm_parser(t->term)); lua_setfield(L, -2, "pending");
  lua_createtable(L, (int)lpage_rows(s), 0);
  for (size_t y = 0; y < lpage_rows(s); y++) { row(L, t->term, lpage_visible(s, y)); lua_rawseti(L, -2, y + 1); }
  lua_setfield(L, -2, "screen");
  size_t count = history ? lpage_history_count(s) : 0;
  lua_createtable(L, (int)count, 0);
  for (size_t y = 0; y < count; y++) { row(L, t->term, lpage_history(s, y)); lua_rawseti(L, -2, y + 1); }
  lua_setfield(L, -2, "scrollback"); return 1;
}
static int l_damage(lua_State *L) {
  const lpage_screen *s = bterm_screen(check(L)->term); lua_createtable(L, 0, 0);
  lua_Integer i = 0;
  for (size_t y = 0; y < lpage_rows(s); y++) if (lpage_dirty(s, y)) { lua_pushinteger(L, y + 1); lua_rawseti(L, -2, ++i); }
  return 1;
}
static int l_ack(lua_State *L) { bterm_ack_damage(check(L)->term); return 0; }
static int l_replies(lua_State *L) {
  terminal *t = check(L); lua_pushlstring(L, (const char *)t->replies, t->reply_length);
  t->reply_length = 0; return 1;
}
static int l_usage(lua_State *L) {
  terminal *t = check(L); lpage_stats s = lpage_usage(bterm_screen(t->term));
  lua_createtable(L, 0, 7); integer(L, "pages", s.pages); integer(L, "row_capacity", s.row_capacity);
  integer(L, "history_rows", s.history_rows); integer(L, "styles", s.styles); integer(L, "screen_bytes", s.bytes);
  integer(L, "reply_bytes", t->reply_length); integer(L, "reply_capacity", REPLY_CAPACITY); return 1;
}
static int l_source(lua_State *L) {
  lua_createtable(L, 0, 1);
  lua_createtable(L, (int)(sizeof terminal_source_files / sizeof terminal_source_files[0]), 0);
  for (size_t i = 0; i < sizeof terminal_source_files / sizeof terminal_source_files[0]; i++) {
    lua_createtable(L, 0, 2);
    lua_pushstring(L, terminal_source_files[i].path); lua_setfield(L, -2, "path");
    lua_pushstring(L, terminal_source_files[i].sha256); lua_setfield(L, -2, "sha256");
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "files"); return 1;
}
int luaopen_boggart_terminal(lua_State *L) {
  const luaL_Reg methods[] = { {"feed", l_feed}, {"finish", l_finish}, {"reset", l_reset}, {"state", l_state},
    {"row", l_row}, {"snapshot", l_snapshot}, {"damage", l_damage}, {"ack_damage", l_ack},
    {"replies", l_replies}, {"usage", l_usage}, {"close", l_close}, {"__gc", l_close}, {"__close", l_close}, {NULL, NULL} };
  luaL_newmetatable(L, TERMINAL_MT); luaL_setfuncs(L, methods, 0); lua_pushvalue(L, -1); lua_setfield(L, -2, "__index"); lua_pop(L, 1);
  lua_newtable(L); lua_pushcfunction(L, l_new); lua_setfield(L, -2, "new");
  lua_pushcfunction(L, l_source); lua_setfield(L, -2, "source");
  integer(L, "COLOR_INDEXED", LP_COLOR_INDEXED); integer(L, "COLOR_RGB", LP_COLOR_RGB);
  integer(L, "AUTOWRAP", BT_AUTOWRAP); integer(L, "ORIGIN", BT_ORIGIN); integer(L, "CURSOR_VISIBLE", BT_CURSOR_VISIBLE);
  integer(L, "BRACKETED_PASTE", BT_BRACKETED_PASTE); integer(L, "FOCUS", BT_FOCUS);
  return 1;
}
