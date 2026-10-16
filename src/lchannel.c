#include "lchannel.h"
#include "lauxlib.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#define CHANNEL_MT "boggart.agent_channel"
extern int luaopen_luv(lua_State *L);
extern uv_loop_t *luv_loop(lua_State *L);
static char started,shutting_down,watch_owners;
typedef struct channel_watch channel_watch;
typedef struct{bchannel *native;channel_watch *watch;uint64_t notifications;char watch_error[256];} channel;
struct channel_watch {
  uv_async_t async;lua_State *L;channel *owner;channel_watch *next;bool closing,pending;
};
static _Thread_local channel_watch *watches;
static void watch_stop(channel_watch *w);
static channel *check(lua_State *L,int index){return luaL_checkudata(L,index,CHANNEL_MT);}
static channel *create(lua_State *L) {
  channel *c=lua_newuserdatauv(L,sizeof *c,1);*c=(channel){0};luaL_setmetatable(L,CHANNEL_MT);return c;
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
  index=lua_absindex(L,index);
  channel *c=luaL_testudata(L,index,CHANNEL_MT);
  if(c){watch_stop(c->watch);bchannel_close(c->native);lua_pushnil(L);lua_setiuservalue(L,index,1);}
}
static int close_channel(lua_State *L){check(L,1);boggart_channel_close(L,1);return 0;}
static int gc(lua_State *L){channel *c=check(L,1);watch_stop(c->watch);bchannel_destroy(c->native);c->native=NULL;return 0;}
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
/* Match terminal watchers: weak owner, callback in its uservalue, deferred Lua
 * delivery on the main thread, and no referenced handle while idle. */
static void watch_closed(uv_handle_t *handle) {
  channel_watch *w=handle->data,**slot=&watches;
  while(*slot && *slot!=w)slot=&(*slot)->next;
  if(*slot)*slot=w->next;free(w);
}
static void watch_stop(channel_watch *w) {
  if(!w || w->closing)return;
  w->closing=true;
  if(w->owner && w->owner->watch==w) {
    bchannel_set_notify(w->owner->native,NULL,NULL);w->owner->watch=NULL;
  }
  w->owner=NULL;
  lua_rawgetp(w->L,LUA_REGISTRYINDEX,&watch_owners);
  if(lua_istable(w->L,-1)){lua_pushnil(w->L);lua_rawsetp(w->L,-2,w);}
  lua_pop(w->L,1);uv_close((uv_handle_t *)&w->async,watch_closed);
}
static void watch_schedule(void *context) {
  channel_watch *w=context;if(!w || w->closing)return;
  if(!w->pending){w->pending=true;uv_ref((uv_handle_t *)&w->async);}
  (void)uv_async_send(&w->async);
}
static void watch_deliver(uv_async_t *async) {
  channel_watch *w=async->data;if(w->closing)return;
  w->pending=false;uv_unref((uv_handle_t *)async);
  lua_State *L=w->L;int top=lua_gettop(L);
  if(!lua_checkstack(L,8)){watch_stop(w);return;}
  lua_rawgetp(L,LUA_REGISTRYINDEX,&watch_owners);lua_rawgetp(L,-1,w);lua_remove(L,-2);
  channel *c=luaL_testudata(L,-1,CHANNEL_MT);
  if(!c || c->watch!=w || !c->native){watch_stop(w);lua_settop(L,top);return;}
  int owner=lua_gettop(L);lua_getiuservalue(L,owner,1);
  if(!lua_isfunction(L,-1)){watch_stop(w);lua_settop(L,top);return;}
  c->notifications++;lua_pushvalue(L,owner);
  if(lua_pcall(L,1,0,0)!=LUA_OK && c->watch==w) {
    const char *error=lua_tostring(L,-1);
    snprintf(c->watch_error,sizeof c->watch_error,"%s",error ? error : "agent channel watch callback failed");
    watch_stop(w);lua_pushnil(L);lua_setiuservalue(L,owner,1);
  }
  lua_settop(L,top);
}
static int watch(lua_State *L) {
  channel *c=check(L,1);
  if(lua_isnoneornil(L,2)) {
    watch_stop(c->watch);lua_pushnil(L);lua_setiuservalue(L,1,1);lua_pushboolean(L,true);return 1;
  }
  luaL_checktype(L,2,LUA_TFUNCTION);
  if(!c->native)return luaL_error(L,"agent channel unavailable");
  uv_loop_t *owner_loop=loop(L);
  lua_rawgetp(L,LUA_REGISTRYINDEX,&watch_owners);
  if(!lua_istable(L,-1)) {
    lua_pop(L,1);lua_newtable(L);lua_newtable(L);lua_pushliteral(L,"v");lua_setfield(L,-2,"__mode");
    lua_setmetatable(L,-2);lua_pushvalue(L,-1);lua_rawsetp(L,LUA_REGISTRYINDEX,&watch_owners);
  }
  c=check(L,1);watch_stop(c->watch);
  channel_watch *w=calloc(1,sizeof *w);if(!w)return luaL_error(L,"agent channel watch allocation failed");
  int error=uv_async_init(owner_loop,&w->async,watch_deliver);
  if(error){free(w);return luaL_error(L,"agent channel watch: %s",uv_strerror(error));}
  lua_rawgeti(L,LUA_REGISTRYINDEX,LUA_RIDX_MAINTHREAD);w->L=lua_tothread(L,-1);lua_pop(L,1);
  w->owner=c;w->async.data=w;w->next=watches;watches=w;c->watch=w;
  uv_unref((uv_handle_t *)&w->async);lua_pushvalue(L,1);lua_rawsetp(L,-2,w);lua_pop(L,1);
  c=check(L,1);
  if(c->watch!=w)return luaL_error(L,"agent channel watch replaced during setup");
  lua_pushvalue(L,2);lua_setiuservalue(L,1,1);c->watch_error[0]=0;
  bchannel_set_notify(c->native,watch_schedule,w);watch_schedule(w);lua_pushboolean(L,true);return 1;
}
static int watch_state(lua_State *L) {
  channel *c=check(L,1);lua_createtable(L,0,3);
  lua_pushboolean(L,c->watch!=NULL);lua_setfield(L,-2,"active");integer(L,"callbacks",c->notifications);
  if(c->watch_error[0]){lua_pushstring(L,c->watch_error);lua_setfield(L,-2,"error");}return 1;
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
void boggart_channel_quiesce(lua_State *L) {
  lua_pushboolean(L,true);lua_rawsetp(L,LUA_REGISTRYINDEX,&shutting_down);
  for(channel_watch *w=watches;w;w=w->next)if(w->L==L)watch_stop(w);
}
void boggart_channel_shutdown(lua_State *L) {
  lua_rawgetp(L,LUA_REGISTRYINDEX,&started);bool active=lua_toboolean(L,-1);lua_pop(L,1);if(!active)return;
  boggart_channel_quiesce(L);
  for(;;) {
    bool pending=false;for(channel_watch *w=watches;w;w=w->next)if(w->L==L){pending=true;break;}
    if(!pending)break;uv_run(luv_loop(L),UV_RUN_NOWAIT);
  }
  bchannel_shutdown(luv_loop(L));
}
int luaopen_boggart_channel(lua_State *L) {
  const luaL_Reg methods[]={{"send",send_frame},{"receive",receive},{"state",state},{"revision",revision},{"watch",watch},{"watch_state",watch_state},{"close",close_channel},{"__close",close_channel},{"__gc",gc},{NULL,NULL}};
  luaL_newmetatable(L,CHANNEL_MT);luaL_setfuncs(L,methods,0);lua_pushvalue(L,-1);lua_setfield(L,-2,"__index");lua_pop(L,1);
  lua_newtable(L);lua_pushcfunction(L,adopt_env);lua_setfield(L,-2,"adopt_env");
  integer(L,"frame_limit",BCHANNEL_FRAME_LIMIT);integer(L,"queue_limit",BCHANNEL_QUEUE_LIMIT);return 1;
}
