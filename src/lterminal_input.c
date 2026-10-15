#include "lterminal.h"
#include "bpty.h"
#include "lauxlib.h"
#include <string.h>
#include <limits.h>
#define PASTE_LIMIT (32u * 1024u * 1024u)
static void integer(lua_State *L,const char *key,lua_Integer n){lua_pushinteger(L,n);lua_setfield(L,-2,key);}
static void boolean(lua_State *L,const char *key,bool b){lua_pushboolean(L,b);lua_setfield(L,-2,key);}
static void event_field(lua_State *L, const char *key) { lua_pushstring(L,key); lua_rawget(L,2); }
static lua_Integer event_integer(lua_State *L, const char *key, lua_Integer fallback, lua_Integer low, lua_Integer high) {
  event_field(L,key); lua_Integer value=luaL_optinteger(L,-1,fallback); lua_pop(L,1);
  if (value < low || value > high) luaL_error(L,"input %s out of range",key);
  return value;
}
static int l_input_state(lua_State *L) {
  bterm_input_status s=bterm_input_state(boggart_terminal_borrow(L,1));
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
  (void)boggart_terminal_borrow(L,1);size_t n;const uint8_t *data=paste_text(L,&n);
  bool safe=bterm_paste_safe(boggart_terminal_borrow(L,1),data,n);lua_pushboolean(L,safe);return 1;
}
static int l_paste(lua_State *L) {
  (void)boggart_terminal_borrow(L,1);size_t n;const uint8_t *data=paste_text(L,&n);
  if(!n){lua_pushliteral(L,"");return 1;}
  luaL_Buffer buffer;size_t capacity=n+BPASTE_FRAME_SIZE;
  uint8_t *output=(uint8_t *)luaL_buffinitsize(L,&buffer,capacity);size_t length;
  /* Allocation can run finalizers; reacquire the live core afterward. */
  if(!bterm_paste(boggart_terminal_borrow(L,1),data,n,output,capacity,&length))return luaL_error(L,"invalid paste");
  luaL_pushresultsize(&buffer,length);return 1;
}
static int l_focus(lua_State *L) {
  (void)boggart_terminal_borrow(L,1);luaL_checktype(L,2,LUA_TBOOLEAN);bool focused=lua_toboolean(L,2);
  uint8_t output[3];size_t length;
  if(!bterm_focus(boggart_terminal_borrow(L,1),focused,output,sizeof output,&length))return luaL_error(L,"invalid focus event");
  lua_pushlstring(L,(const char *)output,length);return 1;
}
static bool event_boolean(lua_State *L,const char *name) {
  event_field(L,name);bool value=false;
  if(!lua_isnil(L,-1)){luaL_checktype(L,-1,LUA_TBOOLEAN);value=lua_toboolean(L,-1);}
  lua_pop(L,1);return value;
}
static void read_key(lua_State *L,bterm_input_event *input) {
  luaL_checktype(L,2,LUA_TTABLE);bkey_event event={0};size_t n;
  event_field(L,"key");const char *key=luaL_optlstring(L,-1,"text",&n);
  if(!bkey_from_name(key,n,&event.key))luaL_error(L,"unknown terminal key");lua_pop(L,1);
  static const char *actions[]={"press","repeat","release",NULL};
  event_field(L,"action");const char *action=luaL_optlstring(L,-1,"press",&n);
  if(memchr(action,0,n))luaL_error(L,"invalid key action");
  event.action=(bkey_action)luaL_checkoption(L,-1,"press",actions);lua_pop(L,1);
  event.modifiers=(unsigned)event_integer(L,"modifiers",0,0,255);
  event.consumed_modifiers=(unsigned)event_integer(L,"consumed_modifiers",0,0,255);
  event.right_modifiers=(unsigned)event_integer(L,"right_modifiers",0,0,15);
  event.unshifted=(uint32_t)event_integer(L,"unshifted",0,0,0x10ffff);
  event.base_layout=(uint32_t)event_integer(L,"base_layout",0,0,0x10ffff);
  event.composing=event_boolean(L,"composing");
  static const char *options[]={"none","all","left","right",NULL};
  event_field(L,"option_as_alt");const char *option=luaL_optlstring(L,-1,"none",&n);
  if(memchr(option,0,n))luaL_error(L,"invalid Option policy");
  bkey_option alt=(bkey_option)luaL_checkoption(L,-1,"none",options);lua_pop(L,1);
  /* Keep text rooted on the stack, including a coerced Lua number. */
  event_field(L,"text");event.text=(const uint8_t *)luaL_optlstring(L,-1,"",&event.text_length);
#ifdef __APPLE__
  bool macos=true;
#else
  bool macos=false;
#endif
  input->key=event;input->macos=macos;input->option_as_alt=alt;
  event_field(L,"macos");if(!lua_isnil(L,-1)){luaL_checktype(L,-1,LUA_TBOOLEAN);input->macos=lua_toboolean(L,-1);}lua_pop(L,1);
}
static int l_key(lua_State *L) {
  (void)boggart_terminal_borrow(L,1);bterm_input_event event={0};read_key(L,&event);
  uint8_t output[BKEY_CAPACITY];size_t length;
  if(!bterm_key(boggart_terminal_borrow(L,1),&event.key,event.macos,event.option_as_alt,output,sizeof output,&length))return luaL_error(L,"invalid key event");
  lua_pushlstring(L,(const char *)output,length);return 1;
}
static void read_mouse(lua_State *L,bterm_input_event *input) {
  luaL_checktype(L,2,LUA_TTABLE);
  static const char *actions[]={"press","release","motion",NULL};
  event_field(L,"action");
  if (!lua_isnil(L,-1)) {
    size_t n; const char *value=luaL_checklstring(L,-1,&n);
    if (memchr(value,0,n))luaL_error(L,"invalid mouse action");
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
  input->mouse=event;input->cell_width=width;input->cell_height=height;
}
static int l_mouse(lua_State *L) {
  (void)boggart_terminal_borrow(L,1);bterm_input_event event={0};read_mouse(L,&event);
  uint8_t output[BMOUSE_CAPACITY]; size_t length;
  if (!bterm_mouse(boggart_terminal_borrow(L,1),&event.mouse,event.cell_width,event.cell_height,output,sizeof output,&length)) return luaL_error(L,"invalid mouse event");
  lua_pushlstring(L,(const char *)output,length); return 1;
}
typedef struct { bpty *process;int error; } input_sink;
static bool send_input(void *context,const uint8_t *bytes,size_t length) {
  input_sink *sink=context;sink->error=bpty_write(sink->process,bytes,length);return sink->error==0;
}
static int l_send_events(lua_State *L) {
  luaL_checktype(L,2,LUA_TTABLE);size_t count=lua_rawlen(L,2),keys=0;
  luaL_argcheck(L,count>=1 && count<=BTERM_INPUT_EVENTS,2,"input batch must contain 1..64 events");
  lua_pushnil(L);
  while(lua_next(L,2)) {
    if(!lua_isinteger(L,-2) || lua_tointeger(L,-2)<1 || (lua_Unsigned)lua_tointeger(L,-2)>count)return luaL_error(L,"input batch must be a dense array");
    keys++;lua_pop(L,1);
  }
  luaL_argcheck(L,keys==count,2,"input batch must be a dense array");
  lua_settop(L,2);luaL_checkstack(L,(int)count*4+32,"input batch stack");
  lua_pushvalue(L,2);int batch=lua_gettop(L);bterm_input_event events[BTERM_INPUT_EVENTS]={0};
  static const char *kinds[]={"key","paste","focus","mouse",NULL};
  for(size_t i=0;i<count;i++) {
    lua_rawgeti(L,batch,(lua_Integer)i+1);luaL_checktype(L,-1,LUA_TTABLE);
    lua_pushliteral(L,"kind");lua_rawget(L,-2);size_t n;const char *kind=luaL_checklstring(L,-1,&n);
    if(memchr(kind,0,n))return luaL_error(L,"invalid input kind");
    events[i].kind=(bterm_input_kind)luaL_checkoption(L,-1,NULL,kinds);lua_pop(L,1);
    lua_pushliteral(L,"value");lua_rawget(L,-2);lua_copy(L,-1,2);
    switch(events[i].kind) {
      case BT_INPUT_KEY:read_key(L,&events[i]);break;
      case BT_INPUT_PASTE:
        luaL_checktype(L,2,LUA_TSTRING);events[i].text=(const uint8_t *)lua_tolstring(L,2,&events[i].text_length);break;
      case BT_INPUT_FOCUS:luaL_checktype(L,2,LUA_TBOOLEAN);events[i].focused=lua_toboolean(L,2);break;
      case BT_INPUT_MOUSE:read_mouse(L,&events[i]);break;
    }
    /* Keep value tables and parsed/coerced key text on the Lua stack until
     * encoding completes. A finalizer can mutate the caller's batch. */
  }
  input_sink sink={boggart_terminal_process_borrow(L,1),0};size_t length;
  bterm *term=boggart_terminal_borrow(L,1);
  /* No Lua allocation/callback across native encoding, rollback or queueing. */
  if(!bterm_send_events(term,events,count,send_input,&sink,&length)) {
    lua_pushnil(L);lua_pushstring(L,uv_strerror(sink.error ? sink.error : UV_EINVAL));return 2;
  }
  boggart_terminal_changed(L,1); /* Focus/motion can change without PTY bytes. */
  lua_pushinteger(L,(lua_Integer)length);return 1;
}
void boggart_terminal_input_methods(lua_State *L) {
  const luaL_Reg methods[]={{"key",l_key},{"mouse",l_mouse},{"input_state",l_input_state},
    {"paste",l_paste},{"paste_safe",l_paste_safe},{"focus",l_focus},{"send_events",l_send_events},{NULL,NULL}};
  luaL_setfuncs(L,methods,0);
}
