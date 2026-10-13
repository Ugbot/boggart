/* Lua owns the terminal lifetime; C owns parsing, grid storage and reply bytes.
 * Snapshot/row copies are made only on explicit calls, never while feeding. */
#include "bterm.h"
#include "lua.h"
#include "lauxlib.h"
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include "terminal-source.h"
#define TERMINAL_MT "boggart.terminal"
#define REPLY_CAPACITY 65536
#define EVENT_CAPACITY 256
#define EVENT_BYTES 65536
typedef struct { size_t count, used; bterm_event events[EVENT_CAPACITY]; uint8_t bytes[EVENT_BYTES]; } event_queue;
typedef struct {
  bterm *term; size_t reply_length; uint8_t replies[REPLY_CAPACITY];
  event_queue *events; size_t dropped; lua_Integer clipboard_generation; bool clipboard_read, clipboard_write;
} terminal;
static void dropped(terminal *t) { if (t->dropped < (size_t)LLONG_MAX) t->dropped++; }
static bosc_slice copy_slice(event_queue *q, bosc_slice s) {
  bosc_slice result = {q->bytes + q->used, s.length};
  if (s.length) memcpy(q->bytes + q->used, s.data, s.length);
  q->used += s.length; return result;
}
static void capture_event(void *context, const bterm_event *event) {
  terminal *t = context; bosc_command c = event->command;
  size_t n = 0;
  switch (c.type) {
    case BOSC_TITLE: case BOSC_CWD: n = c.value.text.length; break;
    case BOSC_HYPERLINK: n = c.value.link.id.length + c.value.link.uri.length; break;
    case BOSC_NOTIFY: n = c.value.notify.id.length + c.value.notify.title.length + c.value.notify.body.length; break;
    case BOSC_SHELL: n = c.value.shell.options.length; break;
    case BOSC_CLIPBOARD: n = c.value.clipboard.text.length; break;
    default: break;
  }
  if (!t->events) t->events = calloc(1, sizeof *t->events);
  event_queue *q = t->events;
  if (!q || q->count == EVENT_CAPACITY || n > EVENT_BYTES - q->used) { dropped(t); return; }
  switch (c.type) {
    case BOSC_TITLE: case BOSC_CWD: c.value.text = copy_slice(q,c.value.text); break;
    case BOSC_HYPERLINK: c.value.link.id = copy_slice(q,c.value.link.id); c.value.link.uri = copy_slice(q,c.value.link.uri); break;
    case BOSC_NOTIFY: c.value.notify.id = copy_slice(q,c.value.notify.id); c.value.notify.title = copy_slice(q,c.value.notify.title); c.value.notify.body = copy_slice(q,c.value.notify.body); break;
    case BOSC_SHELL: c.value.shell.options = copy_slice(q,c.value.shell.options); break;
    case BOSC_CLIPBOARD: c.value.clipboard.text = copy_slice(q,c.value.clipboard.text); break;
    default: break;
  }
  q->events[q->count] = *event; q->events[q->count++].command = c;
}
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
  bterm_set_event_sink(t->term, capture_event, t);
  return 1;
}
static int l_close(lua_State *L) {
  terminal *t = luaL_checkudata(L, 1, TERMINAL_MT);
  bterm_destroy(t->term); t->term = NULL; t->reply_length = 0; free(t->events); t->events = NULL; t->dropped = 0; return 0;
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
  if (t->events) t->events->count = t->events->used = 0; t->dropped = 0;
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
  integer(L, "reply_bytes", t->reply_length); integer(L, "reply_capacity", REPLY_CAPACITY);
  integer(L, "event_count", t->events ? t->events->count : 0); integer(L, "event_bytes", t->events ? t->events->used : 0);
  integer(L, "event_capacity", EVENT_CAPACITY); integer(L, "event_byte_capacity", EVENT_BYTES);
  integer(L, "events_dropped", t->dropped); return 1;
}
static void string(lua_State *L, const char *key, bosc_slice s) {
  lua_pushlstring(L, (const char *)s.data, s.length); lua_setfield(L,-2,key);
}
static int l_clipboard_policy(lua_State *L) {
  terminal *t = check(L);
  if (lua_gettop(L) == 1) {
    lua_createtable(L,0,3); boolean(L,"read",t->clipboard_read); boolean(L,"write",t->clipboard_write);
    integer(L,"generation",t->clipboard_generation); return 1;
  }
  luaL_checktype(L,2,LUA_TBOOLEAN); luaL_checktype(L,3,LUA_TBOOLEAN);
  if (t->clipboard_generation == LUA_MAXINTEGER) return luaL_error(L,"clipboard policy generation exhausted");
  t->clipboard_generation++;
  t->clipboard_read = lua_toboolean(L,2); t->clipboard_write = lua_toboolean(L,3);
  /* Revoke queued requests now, so granting later cannot resurrect them. */
  if (t->events) for (size_t i=0; i<t->events->count; i++) {
    bosc_command *c = &t->events->events[i].command;
    if (c->type == BOSC_CLIPBOARD && !(c->value.clipboard.query ? t->clipboard_read : t->clipboard_write)) c->type = BOSC_NONE;
  }
  bterm_clipboard_policy(t->term,t->clipboard_read,t->clipboard_write); return 0;
}
static int l_clipboard_reply(lua_State *L) {
  terminal *t = check(L); size_t n, selection_length;
  const char *selection = luaL_checklstring(L,2,&selection_length);
  luaL_argcheck(L,selection_length == 1,2,"single clipboard selection required");
  luaL_checktype(L,3,LUA_TBOOLEAN); luaL_checktype(L,4,LUA_TSTRING);
  const char *text = lua_tolstring(L,4,&n);
  lua_pushboolean(L,bterm_clipboard_reply(t->term,selection[0],lua_toboolean(L,3),(const uint8_t *)text,n)); return 1;
}
static int l_events(lua_State *L) {
  terminal *t = check(L); event_queue *q = t->events; size_t output = 0;
  static const char *names[] = {"none","title","cwd","hyperlink","notification","shell","clipboard","bell"};
  lua_createtable(L,q ? (int)q->count : 0,0);
  if (q) for (size_t i=0;i<q->count;i++) {
    bterm_event *e=&q->events[i]; bosc_command *c=&e->command;
    if (c->type == BOSC_NONE || (c->type == BOSC_CLIPBOARD && !(c->value.clipboard.query ? t->clipboard_read : t->clipboard_write))) continue;
    lua_createtable(L,0,10); lua_pushstring(L,names[c->type]); lua_setfield(L,-2,"type");
    integer(L,"code",c->code); integer(L,"row",e->y+1); integer(L,"col",e->x+1); boolean(L,"alternate",e->alternate);
    switch (c->type) {
      case BOSC_TITLE: case BOSC_CWD: string(L,"text",c->value.text); break;
      case BOSC_HYPERLINK: string(L,"id",c->value.link.id); string(L,"uri",c->value.link.uri); break;
      case BOSC_NOTIFY:
        string(L,"id",c->value.notify.id); string(L,"title",c->value.notify.title); string(L,"body",c->value.notify.body);
        integer(L,"urgency",c->value.notify.urgency);
        lua_pushstring(L,c->value.notify.payload == BOSC_NOTIFY_CLOSE ? "close" : c->value.notify.payload == BOSC_NOTIFY_QUERY ? "query" : "notify"); lua_setfield(L,-2,"action"); break;
      case BOSC_SHELL:
        string(L,"mark",(bosc_slice){(const uint8_t *)&c->value.shell.mark,1}); string(L,"options",c->value.shell.options);
        if (c->value.shell.has_status) integer(L,"status",c->value.shell.status); break;
      case BOSC_CLIPBOARD:
        string(L,"selection",(bosc_slice){(const uint8_t *)&c->value.clipboard.selection,1});
        integer(L,"clipboard_generation",t->clipboard_generation);
        boolean(L,"query",c->value.clipboard.query); boolean(L,"bel",c->value.clipboard.bel); string(L,"text",c->value.clipboard.text); break;
      default: break;
    }
    lua_rawseti(L,-2,++output);
  }
  if (q) q->count = q->used = 0;
  lua_pushinteger(L,(lua_Integer)t->dropped); t->dropped=0; return 2;
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
    {"replies", l_replies}, {"events", l_events}, {"clipboard_policy", l_clipboard_policy},
    {"clipboard_reply", l_clipboard_reply}, {"usage", l_usage}, {"close", l_close}, {"__gc", l_close}, {"__close", l_close}, {NULL, NULL} };
  luaL_newmetatable(L, TERMINAL_MT); luaL_setfuncs(L, methods, 0); lua_pushvalue(L, -1); lua_setfield(L, -2, "__index"); lua_pop(L, 1);
  lua_newtable(L); lua_pushcfunction(L, l_new); lua_setfield(L, -2, "new");
  lua_pushcfunction(L, l_source); lua_setfield(L, -2, "source");
  integer(L, "COLOR_INDEXED", LP_COLOR_INDEXED); integer(L, "COLOR_RGB", LP_COLOR_RGB);
  integer(L, "AUTOWRAP", BT_AUTOWRAP); integer(L, "ORIGIN", BT_ORIGIN); integer(L, "CURSOR_VISIBLE", BT_CURSOR_VISIBLE);
  integer(L, "BRACKETED_PASTE", BT_BRACKETED_PASTE); integer(L, "FOCUS", BT_FOCUS);
  return 1;
}
