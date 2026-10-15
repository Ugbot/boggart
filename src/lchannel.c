#include "lchannel.h"
#include "lauxlib.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#define CHANNEL_MT "boggart.agent_channel"
extern int luaopen_luv(lua_State *L);
extern uv_loop_t *luv_loop(lua_State *L);
static char started,shutting_down;
typedef struct{bchannel *native;} channel;
static channel *check(lua_State *L,int index){return luaL_checkudata(L,index,CHANNEL_MT);}
static channel *create(lua_State *L) {
  channel *c=lua_newuserdatauv(L,sizeof *c,0);c->native=NULL;luaL_setmetatable(L,CHANNEL_MT);return c;
}
static uv_loop_t *loop(lua_State *L) {
  lua_rawgetp(L,LUA_REGISTRYINDEX,&shutting_down);bool shutdown=lua_toboolean(L,-1);lua_pop(L,1);
  if(shutdown)luaL_error(L,"agent channel loop is shutting down");
  luaL_requiref(L,"uv",luaopen_luv,0);lua_pop(L,1);
  lua_pushboolean(L,true);lua_rawsetp(L,LUA_REGISTRYINDEX,&started);return luv_loop(L);
}
static int result(lua_State *L,int error) {
  if(error){lua_pushnil(L);lua_pushstring(L,uv_strerror(error));return 2;}
  lua_pushboolean(L,true);return 1;
}
int boggart_channel_pair(lua_State *L,uv_loop_t *owner,int *child_fd) {
  (void)owner;luaL_requiref(L,"agent_channel",luaopen_boggart_channel,0);lua_pop(L,1);
  uv_loop_t *native_loop=loop(L);
  channel *c=create(L);int error;c->native=bchannel_pair(native_loop,child_fd,&error);return error;
}
void boggart_channel_close(lua_State *L,int index) {
  channel *c=luaL_testudata(L,index,CHANNEL_MT);if(c)bchannel_close(c->native);
}
static int close_channel(lua_State *L){bchannel_close(check(L,1)->native);return 0;}
static int gc(lua_State *L){channel *c=check(L,1);bchannel_destroy(c->native);c->native=NULL;return 0;}
static int send_frame(lua_State *L) {
  size_t n;const char *bytes=luaL_checklstring(L,2,&n);
  return result(L,bchannel_send(check(L,1)->native,bytes,n));
}
static int receive(lua_State *L) {
  size_t capacity=bchannel_next_size(check(L,1)->native);
  if(!capacity){lua_pushnil(L);return 1;}
  /* A finalizer may close this channel during allocation. Borrow again and
   * copy to rooted workspace before publishing a Lua string. */
  void *bytes=lua_newuserdatauv(L,capacity,0);
  size_t n=bchannel_take(check(L,1)->native,bytes,capacity);
  if(!n){lua_pushnil(L);return 1;}
  lua_pushlstring(L,bytes,n);return 1;
}
static int revision(lua_State *L){bchannel_status s=bchannel_state(check(L,1)->native);lua_pushinteger(L,(lua_Integer)s.revision);return 1;}
static void integer(lua_State *L,const char *key,size_t value){lua_pushinteger(L,(lua_Integer)value);lua_setfield(L,-2,key);}
static int state(lua_State *L) {
  bchannel_status s=bchannel_state(check(L,1)->native);lua_createtable(L,0,7);
  lua_pushboolean(L,s.closed);lua_setfield(L,-2,"closed");lua_pushinteger(L,s.error);lua_setfield(L,-2,"error_code");
  if(s.error){lua_pushstring(L,uv_strerror(s.error));lua_setfield(L,-2,"error");}
  integer(L,"revision",s.revision);integer(L,"received_frames",s.received_frames);integer(L,"received_bytes",s.received_bytes);
  integer(L,"queued_frames",s.queued_frames);integer(L,"queued_bytes",s.queued_bytes);return 1;
}
static int adopt_env(lua_State *L) {
#ifdef _WIN32
  lua_pushnil(L);return 1;
#else
  const char *value=getenv("BOGGART_AGENT_CHANNEL_FD");if(!value){lua_pushnil(L);return 1;}
  char *end=NULL;errno=0;long number=strtol(value,&end,10);
  bool valid=!errno && end!=value && !*end && number>=3 && number<=INT_MAX;
  unsetenv("BOGGART_AGENT_CHANNEL_FD");
  if(!valid)return result(L,UV_EINVAL);
  uv_loop_t *owner=loop(L);channel *c=create(L);int error;
  c->native=bchannel_adopt(owner,(int)number,&error);
  if(error)return result(L,error);return 1;
#endif
}
void boggart_channel_shutdown(lua_State *L) {
  lua_rawgetp(L,LUA_REGISTRYINDEX,&started);bool active=lua_toboolean(L,-1);lua_pop(L,1);if(!active)return;
  lua_pushboolean(L,true);lua_rawsetp(L,LUA_REGISTRYINDEX,&shutting_down);bchannel_shutdown(luv_loop(L));
}
int luaopen_boggart_channel(lua_State *L) {
  const luaL_Reg methods[]={{"send",send_frame},{"receive",receive},{"state",state},{"revision",revision},{"close",close_channel},{"__close",close_channel},{"__gc",gc},{NULL,NULL}};
  luaL_newmetatable(L,CHANNEL_MT);luaL_setfuncs(L,methods,0);lua_pushvalue(L,-1);lua_setfield(L,-2,"__index");lua_pop(L,1);
  lua_newtable(L);lua_pushcfunction(L,adopt_env);lua_setfield(L,-2,"adopt_env");
  integer(L,"frame_limit",BCHANNEL_FRAME_LIMIT);integer(L,"queue_limit",BCHANNEL_QUEUE_LIMIT);return 1;
}
