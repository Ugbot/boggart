/* Lua owns the terminal lifetime; C owns parsing, grid storage and reply bytes.
 * Snapshot/row copies are made only on explicit calls, never while feeding. */
#include "bterm.h"
#include "bpty.h"
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
#define PASTE_LIMIT (32u * 1024u * 1024u)
typedef struct { size_t count, used; bterm_event events[EVENT_CAPACITY]; uint8_t bytes[EVENT_BYTES]; } event_queue;
typedef struct {
  bterm *term; bpty *process; size_t reply_length; uint8_t replies[REPLY_CAPACITY];
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
  if (t->process) return bpty_write(t->process,bytes,n)==0;
  if (n > REPLY_CAPACITY - t->reply_length) return false;
  memcpy(t->replies + t->reply_length, bytes, n); t->reply_length += n; return true;
}
static void integer(lua_State *L, const char *key, lua_Integer n) { lua_pushinteger(L, n); lua_setfield(L, -2, key); }
static void boolean(lua_State *L, const char *key, bool b) { lua_pushboolean(L, b); lua_setfield(L, -2, key); }
static void style(lua_State *L, const lpage_style *s) {
  lua_createtable(L, 0, 4); integer(L, "fg", s->fg); integer(L, "bg", s->bg);
  integer(L, "underline", s->underline); integer(L, "attrs", s->attrs);
}
static void state(lua_State *L, bterm_status s) {
  lua_createtable(L, 0, 10);
  integer(L, "row", (lua_Integer)s.y + 1); integer(L, "col", (lua_Integer)s.x + 1);
  integer(L, "top", (lua_Integer)s.top + 1); integer(L, "bottom", (lua_Integer)s.bottom + 1);
  integer(L, "modes", s.modes); integer(L, "cursor_style", s.cursor_style);
  boolean(L, "alternate", s.alternate); boolean(L, "pending_wrap", s.pending_wrap);
  style(L, &s.pen); lua_setfield(L, -2, "pen");
}
/* The userdata roots an immutable image before any table/string allocation.
 * Lua finalizers may close or mutate the terminal at allocation boundaries. */
typedef struct {
  uint32_t codepoint, hyperlink; lpage_style style;
  uint8_t width, flags;
  size_t text, text_length, key, key_length, uri, uri_length;
} snapshot_cell;
typedef struct {
  bterm_status state; lvt_parser parser;
  size_t columns, rows, history, count;
  snapshot_cell cells[];
} snapshot_image;
static size_t utf8(uint32_t cp, char bytes[4]) {
  if (cp>0x10ffff || (cp>=0xd800 && cp<=0xdfff)) cp=0xfffd;
  if (cp<0x80) { bytes[0]=(char)cp; return 1; }
  if (cp<0x800) { bytes[0]=(char)(0xc0|(cp>>6)); bytes[1]=(char)(0x80|(cp&63)); return 2; }
  if (cp<0x10000) { bytes[0]=(char)(0xe0|(cp>>12)); bytes[1]=(char)(0x80|((cp>>6)&63)); bytes[2]=(char)(0x80|(cp&63)); return 3; }
  bytes[0]=(char)(0xf0|(cp>>18)); bytes[1]=(char)(0x80|((cp>>12)&63)); bytes[2]=(char)(0x80|((cp>>6)&63)); bytes[3]=(char)(0x80|(cp&63)); return 4;
}
static size_t snapshot_add(lua_State *L,size_t a,size_t b) {
  if (b>SIZE_MAX-a) luaL_error(L,"terminal snapshot too large"); return a+b;
}
static const lpage_row *snapshot_source(const lpage_screen *s,bool single,size_t index,bool history,size_t y) {
  return single ? (history ? lpage_history(s,index) : lpage_visible(s,index))
    : (y<lpage_rows(s) ? lpage_visible(s,y) : lpage_history(s,y-lpage_rows(s)));
}
static size_t snapshot_size(lua_State *L,bterm *t,bool single,size_t index,bool history) {
  const lpage_screen *s=bterm_screen(t);
  if (single) luaL_argcheck(L,index<(history ? lpage_history_count(s) : lpage_rows(s)),2,"row out of range");
  size_t rows=single ? 1 : snapshot_add(L,lpage_rows(s),history ? lpage_history_count(s) : 0);
  size_t columns=lpage_columns(s), n;
  if (rows>SIZE_MAX/columns) return (size_t)luaL_error(L,"terminal snapshot too large");
  n=rows*columns;
  if (n>(SIZE_MAX-sizeof(snapshot_image))/sizeof(snapshot_cell)) return (size_t)luaL_error(L,"terminal snapshot too large");
  size_t bytes=snapshot_add(L,sizeof(snapshot_image)+n*sizeof(snapshot_cell),rows);
  for (size_t y=0;y<rows;y++) {
    const lpage_row *r=snapshot_source(s,single,index,history,y);
    for (size_t x=0;x<columns;x++) {
      lgrapheme_value g=lpage_grapheme(s,&r->cells[x]); char encoded[4];
      for (size_t i=0;i<g.length;i++) bytes=snapshot_add(L,bytes,utf8(g.codepoints[i],encoded));
      const llink_value *link=lpage_link(s,r->cells[x].hyperlink);
      if (link) bytes=snapshot_add(L,snapshot_add(L,bytes,link->key_length),link->uri_length);
    }
  }
  return bytes;
}
static snapshot_image *snapshot_copy(lua_State *L,bool single,size_t index,bool history) {
  size_t capacity=snapshot_size(L,check(L)->term,single,index,history);
  snapshot_image *image=lua_newuserdatauv(L,capacity,0);
  /* Allocating the image can itself run finalizers. Revalidate lifetime and
   * size before copying. No Lua allocation occurs while the core is borrowed. */
  bterm *t=check(L)->term;
  if (snapshot_size(L,t,single,index,history)>capacity) luaL_error(L,"terminal changed while creating snapshot");
  const lpage_screen *s=bterm_screen(t);
  image->state=bterm_state(t); image->parser=*bterm_parser(t);
  image->columns=lpage_columns(s); image->rows=single ? 1 : lpage_rows(s);
  image->history=!single && history ? lpage_history_count(s) : 0;
  image->count=(image->rows+image->history)*image->columns;
  char *wrapped=(char *)(image->cells+image->count), *bytes=wrapped+image->rows+image->history;
  for (size_t y=0;y<image->rows+image->history;y++) {
    const lpage_row *r=snapshot_source(s,single,index,history,y); wrapped[y]=r->wrapped;
    for (size_t x=0;x<image->columns;x++) {
      const lpage_cell *c=&r->cells[x]; snapshot_cell *out=&image->cells[y*image->columns+x];
      *out=(snapshot_cell){0}; out->codepoint=lpage_codepoint(s,c);
      out->hyperlink=c->hyperlink; out->style=*bterm_style(t,c->style);out->width=c->width;out->flags=c->flags;
      out->text=(size_t)(bytes-(char *)image);
      lgrapheme_value g=lpage_grapheme(s,c);
      for (size_t i=0;i<g.length;i++) bytes+=utf8(g.codepoints[i],bytes);
      out->text_length=(size_t)(bytes-(char *)image)-out->text;
      const llink_value *link=lpage_link(s,c->hyperlink);
      if (link) {
        out->key=(size_t)(bytes-(char *)image);out->key_length=link->key_length;
        memcpy(bytes,link->key,link->key_length);bytes+=link->key_length;
        out->uri=(size_t)(bytes-(char *)image);out->uri_length=link->uri_length;
        memcpy(bytes,link->uri,link->uri_length);bytes+=link->uri_length;
      }
    }
  }
  return image;
}
static void row(lua_State *L,const snapshot_image *image,size_t y) {
  const char *wrapped=(const char *)(image->cells+image->count), *bytes=(const char *)image;
  lua_createtable(L,0,2); boolean(L,"wrapped",wrapped[y]);
  lua_createtable(L,(int)image->columns,0);
  for (size_t x=0;x<image->columns;x++) {
    const snapshot_cell *c=&image->cells[y*image->columns+x];
    lua_createtable(L,0,7);integer(L,"codepoint",c->codepoint);
    integer(L,"width",c->width);integer(L,"flags",c->flags);integer(L,"hyperlink",c->hyperlink);
    lua_pushlstring(L,bytes+c->text,c->text_length);lua_setfield(L,-2,"text");
    if (c->hyperlink) {
      lua_createtable(L,0,2);
      lua_pushlstring(L,bytes+c->key,c->key_length);lua_setfield(L,-2,"id");
      lua_pushlstring(L,bytes+c->uri,c->uri_length);lua_setfield(L,-2,"uri");lua_setfield(L,-2,"link");
    }
    style(L,&c->style);lua_setfield(L,-2,"style");lua_rawseti(L,-2,(lua_Integer)x+1);
  }
  lua_setfield(L,-2,"cells");
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
static terminal *create_terminal(lua_State *L,size_t cols,size_t rows,size_t history) {
  terminal *t=lua_newuserdatauv(L,sizeof *t,0); memset(t,0,sizeof *t);
  luaL_setmetatable(L,TERMINAL_MT);
  t->term=bterm_create(cols,rows,history,reply,t);
  if (!t->term) luaL_error(L,"cannot allocate terminal");
  bterm_set_event_sink(t->term,capture_event,t); return t;
}
static int l_new(lua_State *L) {
  lua_Integer cols = luaL_optinteger(L, 1, 80), rows = luaL_optinteger(L, 2, 24), history = luaL_optinteger(L, 3, 2000);
  luaL_argcheck(L, cols > 0 && cols <= 4096, 1, "columns must be in 1..4096");
  luaL_argcheck(L, rows > 0 && rows <= 4096, 2, "rows must be in 1..4096");
  luaL_argcheck(L, history >= 0 && history <= 1000000, 3, "history must be in 0..1000000");
  create_terminal(L,(size_t)cols,(size_t)rows,(size_t)history);
  return 1;
}
extern uv_loop_t *luv_loop(lua_State *L);
extern int luaopen_luv(lua_State *L);
static char process_loop_started,process_loop_shutdown;
void boggart_terminal_shutdown(lua_State *L) {
  lua_rawgetp(L,LUA_REGISTRYINDEX,&process_loop_started); bool started=lua_toboolean(L,-1); lua_pop(L,1);
  if (!started) return; /* Preserve lazy loop creation for parser-only users. */
  lua_pushboolean(L,true); lua_rawsetp(L,LUA_REGISTRYINDEX,&process_loop_shutdown);
  bpty_shutdown(luv_loop(L));
}
static const char *spawn_string(lua_State *L,int index) {
  size_t length; luaL_checktype(L,index,LUA_TSTRING); const char *s=lua_tolstring(L,index,&length);
  if (memchr(s,0,length)) luaL_error(L,"terminal spawn strings must not contain NUL");
  return s;
}
static lua_Integer spawn_integer(lua_State *L,const char *field,lua_Integer fallback,lua_Integer low,lua_Integer high) {
  lua_getfield(L,1,field); lua_Integer n=luaL_optinteger(L,-1,fallback); lua_pop(L,1);
  if (n<low || n>high) luaL_error(L,"terminal %s out of range",field); return n;
}
static int l_open(lua_State *L) {
  luaL_checktype(L,1,LUA_TTABLE);
  lua_rawgetp(L,LUA_REGISTRYINDEX,&process_loop_shutdown); bool shutting_down=lua_toboolean(L,-1); lua_pop(L,1);
  if (shutting_down) return luaL_error(L,"terminal process loop is shutting down");
  luaL_requiref(L,"uv",luaopen_luv,0); lua_pop(L,1); uv_loop_t *loop=luv_loop(L);
  lua_pushboolean(L,true); lua_rawsetp(L,LUA_REGISTRYINDEX,&process_loop_started);
  size_t cols=(size_t)spawn_integer(L,"cols",80,1,4096),rows=(size_t)spawn_integer(L,"rows",24,1,4096);
  size_t history=(size_t)spawn_integer(L,"history",2000,0,1000000);
  /* Keep every command/cwd/argument string rooted on the stack throughout
   * validation and userdata allocation, including values from metamethods. */
  lua_getfield(L,1,"cmd");
  if (lua_isnil(L,-1)) { lua_pop(L,1); const char *shell=getenv("SHELL"); lua_pushstring(L,shell && *shell ? shell : "/bin/sh"); }
  const char *command=spawn_string(L,-1); if (!*command) return luaL_error(L,"terminal command must not be empty");
  lua_getfield(L,1,"cwd"); const char *cwd=lua_isnil(L,-1) ? NULL : spawn_string(L,-1);
  lua_getfield(L,1,"args"); int args_index=lua_gettop(L); size_t count=0;
  if (!lua_isnil(L,args_index)) { luaL_checktype(L,args_index,LUA_TTABLE); count=lua_rawlen(L,args_index); }
  if (count>1024 || !lua_checkstack(L,(int)count+8)) return luaL_error(L,"terminal argv too large");
  char *argv[1026]; argv[0]=(char *)command;
  for (size_t i=0;i<count;i++) { lua_rawgeti(L,args_index,(lua_Integer)i+1); argv[i+1]=(char *)spawn_string(L,-1); }
  argv[count+1]=NULL;
  terminal *t=create_terminal(L,cols,rows,history); int error;
  t->process=bpty_open(loop,t->term,(bpty_options){command,cwd,argv},&error);
  if (!t->process) { bterm_destroy(t->term); t->term=NULL; lua_pushnil(L); lua_pushstring(L,uv_strerror(error)); return 2; }
  return 1;
}
static int l_write(lua_State *L) {
  luaL_checktype(L,2,LUA_TSTRING); size_t length; const uint8_t *bytes=(const uint8_t *)lua_tolstring(L,2,&length);
  terminal *t=check(L); if (!t->process) return luaL_error(L,"terminal has no process");
  int error=bpty_write(t->process,bytes,length);
  if (error) { lua_pushnil(L); lua_pushstring(L,uv_strerror(error)); return 2; }
  lua_pushinteger(L,(lua_Integer)length); return 1;
}
static int l_process_state(lua_State *L) {
  terminal *t=check(L); if (!t->process) { lua_pushnil(L); return 1; }
  bpty_status s=bpty_state(t->process); /* No native borrow across Lua allocation. */
  lua_createtable(L,0,11); integer(L,"pid",s.pid); boolean(L,"exited",s.exited); boolean(L,"eof",s.eof);
  integer(L,"exit_status",s.exit_status); integer(L,"term_signal",s.term_signal); integer(L,"error_code",s.error);
  if (s.error) { lua_pushstring(L,uv_strerror(s.error)); lua_setfield(L,-2,"error"); }
  integer(L,"revision",(lua_Integer)s.revision); integer(L,"bytes_read",(lua_Integer)s.bytes_read);
  integer(L,"read_callbacks",(lua_Integer)s.read_callbacks); integer(L,"queued_bytes",(lua_Integer)s.queued_bytes); return 1;
}
static int l_foreground_group(lua_State *L) {
  terminal *t=check(L); int64_t group; int error=bpty_foreground_group(t->process,&group);
  if (error) { lua_pushnil(L); lua_pushstring(L,uv_strerror(error)); return 2; }
  lua_pushinteger(L,group); return 1;
}
static int l_close(lua_State *L) {
  terminal *t = luaL_checkudata(L, 1, TERMINAL_MT);
  bpty_destroy(t->process); t->process=NULL;
  bterm_destroy(t->term); t->term = NULL; t->reply_length = 0; free(t->events); t->events = NULL; t->dropped = 0; return 0;
}
static int l_feed(lua_State *L) {
  terminal *t = check(L); luaL_checktype(L, 2, LUA_TSTRING);
  size_t n; const char *bytes = lua_tolstring(L, 2, &n);
  if (!bterm_feed(t->term, (const uint8_t *)bytes, n)) return luaL_error(L, "terminal allocation or reply queue failure; drain replies and reset");
  return 0;
}
static int l_finish(lua_State *L) { if (!bterm_finish(check(L)->term)) return luaL_error(L, "terminal failed; reset required"); return 0; }
static int l_resize(lua_State *L) {
  lua_Integer columns=luaL_checkinteger(L,2),rows=luaL_checkinteger(L,3);
  luaL_argcheck(L,columns>0 && columns<=4096,2,"columns must be in 1..4096");
  luaL_argcheck(L,rows>0 && rows<=4096,3,"rows must be in 1..4096");
  terminal *t=check(L);
  if (t->process && !bpty_state(t->process).eof) {
    int error=bpty_resize(t->process,(unsigned)columns,(unsigned)rows);
    if (error) return luaL_error(L,"terminal/PTY resize failed: %s",uv_strerror(error));
    return 0;
  }
  if (!bterm_resize(t->term,(size_t)columns,(size_t)rows))
    return luaL_error(L,"terminal resize allocation failure; geometry preserved");
  return 0;
}
static int l_reset(lua_State *L) {
  terminal *t = check(L); t->reply_length = 0;
  if (t->events) t->events->count = t->events->used = 0; t->dropped = 0;
  if (!bterm_reset(t->term)) return luaL_error(L, "terminal reset failed"); return 0;
}
static int l_state(lua_State *L) { state(L, bterm_state(check(L)->term)); return 1; }
static int l_row(lua_State *L) {
  lua_Integer index=luaL_checkinteger(L,2);luaL_argcheck(L,index>0,2,"row out of range");
  snapshot_image *image=snapshot_copy(L,true,(size_t)index-1,lua_toboolean(L,3));
  row(L,image,0);lua_remove(L,-2);return 1;
}
static int l_snapshot(lua_State *L) {
  snapshot_image *image=snapshot_copy(L,false,0,lua_toboolean(L,2));
  lua_createtable(L,0,6);integer(L,"cols",(lua_Integer)image->columns);integer(L,"rows",(lua_Integer)image->rows);
  state(L,image->state);lua_setfield(L,-2,"state");pending(L,&image->parser);lua_setfield(L,-2,"pending");
  lua_createtable(L,(int)image->rows,0);
  for(size_t y=0;y<image->rows;y++){row(L,image,y);lua_rawseti(L,-2,y+1);}lua_setfield(L,-2,"screen");
  lua_createtable(L,(int)image->history,0);
  for(size_t y=0;y<image->history;y++){row(L,image,image->rows+y);lua_rawseti(L,-2,y+1);}lua_setfield(L,-2,"scrollback");
  lua_remove(L,-2);return 1;
}
static int l_damage(lua_State *L) {
  const lpage_screen *s=bterm_screen(check(L)->term);lua_Integer rows[4096],count=0;
  for(size_t y=0;y<lpage_rows(s);y++)if(lpage_dirty(s,y))rows[count++]=(lua_Integer)y+1;
  lua_createtable(L,(int)count,0);
  for(lua_Integer i=0;i<count;i++){lua_pushinteger(L,rows[i]);lua_rawseti(L,-2,i+1);}return 1;
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
  integer(L, "links", s.links); integer(L, "link_bytes", s.link_bytes);
  integer(L, "graphemes", s.graphemes); integer(L, "grapheme_bytes", s.grapheme_bytes);
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
static bosc_slice rebase_slice(const event_queue *source,event_queue *copy,bosc_slice s) {
  return (bosc_slice){copy->bytes+(s.data-source->bytes),s.length};
}
static int l_events(lua_State *L) {
  terminal *t=check(L); size_t output=0;
  if ((!t->events || !t->events->count) && !t->dropped) { lua_newtable(L); lua_pushinteger(L,0); return 2; }
  /* Root an immutable copy before building any tables/strings. Finalizers can
   * close/feed the terminal or run uv, so no queue/terminal pointer may be
   * borrowed across a subsequent Lua allocation. */
  event_queue *q=lua_newuserdatauv(L,sizeof *q,0); t=check(L);
  const event_queue *source=t->events;
  if (source) memcpy(q,source,sizeof *q); else memset(q,0,sizeof *q);
  bool clipboard_read=t->clipboard_read,clipboard_write=t->clipboard_write;
  lua_Integer generation=t->clipboard_generation; size_t dropped_count=t->dropped;
  for (size_t i=0;i<q->count;i++) {
    bosc_command *c=&q->events[i].command;
    switch (c->type) {
      case BOSC_TITLE: case BOSC_CWD: c->value.text=rebase_slice(source,q,c->value.text); break;
      case BOSC_HYPERLINK: c->value.link.id=rebase_slice(source,q,c->value.link.id); c->value.link.uri=rebase_slice(source,q,c->value.link.uri); break;
      case BOSC_NOTIFY: c->value.notify.id=rebase_slice(source,q,c->value.notify.id); c->value.notify.title=rebase_slice(source,q,c->value.notify.title); c->value.notify.body=rebase_slice(source,q,c->value.notify.body); break;
      case BOSC_SHELL: c->value.shell.options=rebase_slice(source,q,c->value.shell.options); break;
      case BOSC_CLIPBOARD: c->value.clipboard.text=rebase_slice(source,q,c->value.clipboard.text); break;
      default: break;
    }
  }
  if (t->events) t->events->count=t->events->used=0; t->dropped=0;
  static const char *names[] = {"none","title","cwd","hyperlink","notification","shell","clipboard","bell"};
  lua_createtable(L,q ? (int)q->count : 0,0);
  if (q) for (size_t i=0;i<q->count;i++) {
    bterm_event *e=&q->events[i]; bosc_command *c=&e->command;
    if (c->type == BOSC_NONE || (c->type == BOSC_CLIPBOARD && !(c->value.clipboard.query ? clipboard_read : clipboard_write))) continue;
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
        integer(L,"clipboard_generation",generation);
        boolean(L,"query",c->value.clipboard.query); boolean(L,"bel",c->value.clipboard.bel); string(L,"text",c->value.clipboard.text); break;
      default: break;
    }
    lua_rawseti(L,-2,++output);
  }
  lua_pushinteger(L,(lua_Integer)dropped_count); return 2;
}
static void event_field(lua_State *L, const char *key) { lua_pushstring(L,key); lua_rawget(L,2); }
static lua_Integer event_integer(lua_State *L, const char *key, lua_Integer fallback, lua_Integer low, lua_Integer high) {
  event_field(L,key); lua_Integer value=luaL_optinteger(L,-1,fallback); lua_pop(L,1);
  if (value < low || value > high) luaL_error(L,"input %s out of range",key);
  return value;
}
static int l_input_state(lua_State *L) {
  bterm_input_status s=bterm_input_state(check(L)->term);
  static const char *modes[]={"none","x10","normal","button","any"};
  static const char *formats[]={"x10","utf8","sgr","urxvt","pixels"};
  lua_createtable(L,0,10); lua_pushstring(L,modes[s.mouse_mode]); lua_setfield(L,-2,"mouse_mode");
  lua_pushstring(L,formats[s.mouse_format]); lua_setfield(L,-2,"mouse_format");
  integer(L,"kitty_flags",s.kitty_flags); boolean(L,"backarrow",s.backarrow);
  boolean(L,"ignore_keypad_numlock",s.ignore_keypad_numlock); boolean(L,"alt_prefix",s.alt_prefix);
  boolean(L,"modify_other_keys_2",s.modify_other_keys_2);
  boolean(L,"bracketed_paste",s.bracketed_paste); boolean(L,"focus_reporting",s.focus_reporting);
  boolean(L,"focused",s.focused); return 1;
}
static const uint8_t *paste_text(lua_State *L,size_t *length) {
  luaL_checktype(L,2,LUA_TSTRING);const uint8_t *data=(const uint8_t *)luaL_checklstring(L,2,length);
  luaL_argcheck(L,*length<=PASTE_LIMIT,2,"paste exceeds 32 MiB");return data;
}
static int l_paste_safe(lua_State *L) {
  check(L);size_t n;const uint8_t *data=paste_text(L,&n);
  bool safe=bterm_paste_safe(check(L)->term,data,n);lua_pushboolean(L,safe);return 1;
}
static int l_paste(lua_State *L) {
  check(L);size_t n;const uint8_t *data=paste_text(L,&n);
  if(!n){lua_pushliteral(L,"");return 1;}
  luaL_Buffer buffer;size_t capacity=n+BPASTE_FRAME_SIZE;
  uint8_t *output=(uint8_t *)luaL_buffinitsize(L,&buffer,capacity);size_t length;
  /* Allocation can run finalizers; reacquire the live core afterward. */
  if(!bterm_paste(check(L)->term,data,n,output,capacity,&length))return luaL_error(L,"invalid paste");
  luaL_pushresultsize(&buffer,length);return 1;
}
static int l_focus(lua_State *L) {
  check(L);luaL_checktype(L,2,LUA_TBOOLEAN);bool focused=lua_toboolean(L,2);
  uint8_t output[3];size_t length;
  if(!bterm_focus(check(L)->term,focused,output,sizeof output,&length))return luaL_error(L,"invalid focus event");
  lua_pushlstring(L,(const char *)output,length);return 1;
}
static bool event_boolean(lua_State *L,const char *name) {
  event_field(L,name);bool value=false;
  if(!lua_isnil(L,-1)){luaL_checktype(L,-1,LUA_TBOOLEAN);value=lua_toboolean(L,-1);}
  lua_pop(L,1);return value;
}
static int l_key(lua_State *L) {
  check(L);luaL_checktype(L,2,LUA_TTABLE);bkey_event event={0};size_t n;
  event_field(L,"key");const char *key=luaL_optlstring(L,-1,"text",&n);
  if(!bkey_from_name(key,n,&event.key))return luaL_error(L,"unknown terminal key");lua_pop(L,1);
  static const char *actions[]={"press","repeat","release",NULL};
  event_field(L,"action");const char *action=luaL_optlstring(L,-1,"press",&n);
  if(memchr(action,0,n))return luaL_error(L,"invalid key action");
  event.action=(bkey_action)luaL_checkoption(L,-1,"press",actions);lua_pop(L,1);
  event.modifiers=(unsigned)event_integer(L,"modifiers",0,0,255);
  event.consumed_modifiers=(unsigned)event_integer(L,"consumed_modifiers",0,0,255);
  event.right_modifiers=(unsigned)event_integer(L,"right_modifiers",0,0,15);
  event.unshifted=(uint32_t)event_integer(L,"unshifted",0,0,0x10ffff);
  event.base_layout=(uint32_t)event_integer(L,"base_layout",0,0,0x10ffff);
  event.composing=event_boolean(L,"composing");
  static const char *options[]={"none","all","left","right",NULL};
  event_field(L,"option_as_alt");const char *option=luaL_optlstring(L,-1,"none",&n);
  if(memchr(option,0,n))return luaL_error(L,"invalid Option policy");
  bkey_option alt=(bkey_option)luaL_checkoption(L,-1,"none",options);lua_pop(L,1);
  /* Keep text rooted on the stack, including a coerced Lua number. */
  event_field(L,"text");event.text=(const uint8_t *)luaL_optlstring(L,-1,"",&event.text_length);
  uint8_t output[BKEY_CAPACITY];size_t length;
#ifdef __APPLE__
  bool macos=true;
#else
  bool macos=false;
#endif
  if(!bterm_key(check(L)->term,&event,macos,alt,output,sizeof output,&length))return luaL_error(L,"invalid key event");
  lua_pushlstring(L,(const char *)output,length);return 1;
}
static int l_mouse(lua_State *L) {
  check(L); luaL_checktype(L,2,LUA_TTABLE);
  static const char *actions[]={"press","release","motion",NULL};
  event_field(L,"action");
  if (!lua_isnil(L,-1)) {
    size_t n; const char *value=luaL_checklstring(L,-1,&n);
    if (memchr(value,0,n)) return luaL_error(L,"invalid mouse action");
  }
  bmouse_action action=(bmouse_action)luaL_checkoption(L,-1,"press",actions); lua_pop(L,1);
  bmouse_event event={action,(unsigned)event_integer(L,"button",0,0,9),
    (unsigned)event_integer(L,"modifiers",0,0,7),
    (int32_t)event_integer(L,"x",0,INT32_MIN,INT32_MAX), (int32_t)event_integer(L,"y",0,INT32_MIN,INT32_MAX),false};
  event_field(L,"any_button_pressed");
  if (!lua_isnil(L,-1)) { luaL_checktype(L,-1,LUA_TBOOLEAN); event.any_button_pressed=lua_toboolean(L,-1); }
  else event.any_button_pressed=event.button != 0 && event.action != BM_RELEASE;
  lua_pop(L,1);
  uint32_t width=(uint32_t)event_integer(L,"cell_width",1,1,65535), height=(uint32_t)event_integer(L,"cell_height",1,1,65535);
  uint8_t output[BMOUSE_CAPACITY]; size_t length;
  if (!bterm_mouse(check(L)->term,&event,width,height,output,sizeof output,&length)) return luaL_error(L,"invalid mouse event");
  lua_pushlstring(L,(const char *)output,length); return 1;
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
  const luaL_Reg methods[] = { {"feed", l_feed}, {"finish", l_finish}, {"reset", l_reset}, {"resize", l_resize}, {"state", l_state},
    {"row", l_row}, {"snapshot", l_snapshot}, {"damage", l_damage}, {"ack_damage", l_ack},
    {"replies", l_replies}, {"key", l_key}, {"mouse", l_mouse}, {"input_state", l_input_state}, {"events", l_events}, {"clipboard_policy", l_clipboard_policy},
    {"paste", l_paste}, {"paste_safe", l_paste_safe}, {"focus", l_focus},
    {"write",l_write}, {"process_state",l_process_state}, {"foreground_group",l_foreground_group},
    {"clipboard_reply", l_clipboard_reply}, {"usage", l_usage}, {"close", l_close}, {"__gc", l_close}, {"__close", l_close}, {NULL, NULL} };
  luaL_newmetatable(L, TERMINAL_MT); luaL_setfuncs(L, methods, 0); lua_pushvalue(L, -1); lua_setfield(L, -2, "__index"); lua_pop(L, 1);
  lua_newtable(L); lua_pushcfunction(L, l_new); lua_setfield(L, -2, "new");
  lua_pushcfunction(L,l_open); lua_setfield(L,-2,"open");
  lua_pushcfunction(L, l_source); lua_setfield(L, -2, "source");
  integer(L, "COLOR_INDEXED", LP_COLOR_INDEXED); integer(L, "COLOR_RGB", LP_COLOR_RGB);
  integer(L, "GRAPHEME", BT_GRAPHEME); integer(L, "AUTOWRAP", BT_AUTOWRAP); integer(L, "ORIGIN", BT_ORIGIN); integer(L, "CURSOR_VISIBLE", BT_CURSOR_VISIBLE);
  integer(L, "BRACKETED_PASTE", BT_BRACKETED_PASTE); integer(L, "FOCUS", BT_FOCUS);
  integer(L, "SHIFT", BI_SHIFT); integer(L, "ALT", BI_ALT); integer(L, "CTRL", BI_CTRL);
  integer(L, "SUPER", BI_SUPER); integer(L, "HYPER", BI_HYPER); integer(L, "META", BI_META);
  integer(L, "CAPS_LOCK", BI_CAPS_LOCK); integer(L, "NUM_LOCK", BI_NUM_LOCK);
  integer(L, "KITTY_DISAMBIGUATE", BK_DISAMBIGUATE); integer(L, "KITTY_EVENTS", BK_EVENTS);
  integer(L, "KITTY_ALTERNATES", BK_ALTERNATES); integer(L, "KITTY_ALL", BK_ALL); integer(L, "KITTY_ASSOCIATED", BK_ASSOCIATED);
  return 1;
}
