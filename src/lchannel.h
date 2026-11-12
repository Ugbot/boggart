#ifndef BOGGART_LCHANNEL_H
#define BOGGART_LCHANNEL_H
#include "lua.h"
#include "bchannel.h"
int luaopen_boggart_channel(lua_State *L);
/* Push a rooted channel userdata, even on native failure. */
int boggart_channel_pair(lua_State *L,uv_loop_t *loop,int *child_fd);
void boggart_channel_close(lua_State *L,int index);
/* Disarm deferred Lua callbacks before any teardown routine drains the loop. */
void boggart_channel_quiesce(lua_State *L);
void boggart_channel_shutdown(lua_State *L);
#endif
