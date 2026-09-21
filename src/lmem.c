/* Per-state Lua accounting and protected restricted execution. Allocator ceilings
 * are active only inside lua_resume, which protects allocation failures. Tokens
 * retain a conservative state-wide absolute ceiling across yields; host event
 * loop allocations occur after the previous active ceiling has been restored.
 * This bounds Lua allocations, not malloc performed privately by native modules. */
#include <stdlib.h>
#include <stdint.h>
#include "lua.h"
#include "lauxlib.h"

typedef struct Limit Limit;
typedef struct {
  size_t live, peak;
  void *root;
  Limit *active;
  int creating;
} Memory;
struct Limit {
  Memory *memory;
  size_t ceiling;
  int failed;
  Limit *previous, *parent;
};
#define LIMIT_MT "boggart.memory.limit"

static void *counting_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  Memory *m=ud;
  if (!nsize) {
    int last=ptr && ptr==m->root;
    if (ptr) m->live-=osize;
    free(ptr);
    if (last && !m->creating) free(m);
    return NULL;
  }
  size_t old=ptr ? osize : 0;
  if (nsize>old) {
    size_t growth=nsize-old;
    int denied=0;
    for (Limit *s=m->active;s;s=s->previous) {
      if (m->live>s->ceiling || growth>s->ceiling-m->live) {
        s->failed=1; denied=1;
      }
    }
    if (denied) return NULL;
  }
  void *np=realloc(ptr,nsize);
  if (!np) return NULL;
  if (!m->root) m->root=np;
  m->live=m->live-old+nsize;
  if (m->live>m->peak) m->peak=m->live;
  return np;
}
lua_State *boggart_newstate(void) {
  Memory *m=calloc(1,sizeof(*m));
  if (!m) return NULL;
  m->creating=1;
  lua_State *L=lua_newstate(counting_alloc,m,luaL_makeseed(NULL));
  m->creating=0;
  if (!L) free(m);
  return L;
}
static Memory *memory(lua_State *L) {
  void *ud=NULL;
  if (lua_getallocf(L,&ud)!=counting_alloc) return NULL;
  return ud;
}
static int l_memcapable(lua_State *L) {
  lua_pushboolean(L,memory(L)!=NULL);return 1;
}
static int l_membytes(lua_State *L) {
  Memory *m=memory(L);
  if (!m) return luaL_error(L,"counting allocator unavailable");
  lua_pushinteger(L,(lua_Integer)m->live);
  lua_pushinteger(L,(lua_Integer)m->peak);
  return 2;
}
static int l_memlimit(lua_State *L) {
  Memory *m=memory(L);
  if (!m) return luaL_error(L,"restricted allocator unavailable on this host");
  lua_Integer bytes=luaL_checkinteger(L,1);
  luaL_argcheck(L,bytes>0 && (lua_Unsigned)bytes<=SIZE_MAX-m->live,1,"invalid memory budget");
  Limit *parent=lua_isnoneornil(L,2) ? NULL : luaL_checkudata(L,2,LIMIT_MT);
  int depth=0;
  for (Limit *p=parent;p;p=p->parent) if (++depth>=64) return luaL_error(L,"restricted memory nesting exceeded");
  Limit *s=lua_newuserdatauv(L,sizeof(*s),1);
  s->memory=m; s->ceiling=m->live+(size_t)bytes; s->failed=0;s->previous=NULL;s->parent=parent;
  if (parent) {lua_pushvalue(L,2);lua_setiuservalue(L,-2,1);}
  luaL_setmetatable(L,LIMIT_MT);
  return 1;
}
static int l_memfailed(lua_State *L) {
  Limit *s=luaL_checkudata(L,1,LIMIT_MT);
  int failed=0;
  for (Limit *p=s;p;p=p->parent) failed|=p->failed;
  lua_pushboolean(L,failed);
  return 1;
}
/* sys.memresume(limit, coroutine, ...) -> resume-style success/results.
 * Limits are private host userdata, never passed into generated environments.
 * Same-state children use the minimum of all currently active ceilings. */
static int l_memresume(lua_State *L) {
  Limit *s=luaL_checkudata(L,1,LIMIT_MT);
  Memory *m=memory(L);
  lua_State *co=lua_tothread(L,2);
  luaL_argcheck(L,co!=NULL,2,"coroutine required");
  luaL_argcheck(L,m && s->memory==m,1,"foreign memory budget");
  int failed=0;
  for (Limit *p=s;p;p=p->parent) failed|=p->failed;
  if (failed) {
    lua_pushboolean(L,0);lua_pushliteral(L,"restricted allocation budget exhausted");return 2;
  }

  int nargs=lua_gettop(L)-2;
  if (!lua_checkstack(co,nargs)) return luaL_error(L,"coroutine stack exhausted");
  lua_xmove(L,co,nargs);
  Limit *saved=m->active;
  for (Limit *p=s;p;p=p->parent) {
    int present=0;
    for (Limit *a=m->active;a;a=a->previous) if (a==p) present=1;
    if (!present) {p->previous=m->active;m->active=p;}
  }
  int nresults=0;
  int status=lua_resume(co,L,nargs,&nresults);
  while (m->active!=saved) {Limit *p=m->active;m->active=p->previous;p->previous=NULL;}
  for (Limit *p=s;p;p=p->parent) failed|=p->failed;
  if (status!=LUA_OK && status!=LUA_YIELD) nresults=1;
  if (!lua_checkstack(L,nresults+1)) return luaL_error(L,"result stack exhausted");
  lua_pushboolean(L,(status==LUA_OK || status==LUA_YIELD) && !failed);
  if (failed) {
    lua_pushliteral(L,"restricted allocation budget exhausted");return 2;
  }
  lua_xmove(co,L,nresults);
  return nresults+1;
}
static int l_memclose(lua_State *L) {
  Limit *s=luaL_checkudata(L,1,LIMIT_MT);
  Memory *m=memory(L);
  lua_State *co=lua_tothread(L,2);
  luaL_argcheck(L,co!=NULL,2,"coroutine required");
  luaL_argcheck(L,m && s->memory==m,1,"foreign memory budget");
  Limit *saved=m->active;
  for (Limit *p=s;p;p=p->parent) {
    int present=0;
    for (Limit *a=m->active;a;a=a->previous) if (a==p) present=1;
    if (!present) {p->previous=m->active;m->active=p;}
  }
  int status=lua_closethread(co,L);
  while (m->active!=saved) {Limit *p=m->active;m->active=p->previous;p->previous=NULL;}
  lua_pushboolean(L,status==LUA_OK);
  if (status!=LUA_OK) {lua_xmove(co,L,1);return 2;}
  return 1;
}
void boggart_open_mem(lua_State *L) {
  luaL_newmetatable(L,LIMIT_MT);lua_pop(L,1);
  lua_getglobal(L,"sys");
  if (lua_istable(L,-1)) {
    const luaL_Reg functions[]={{"memcapable",l_memcapable},{"memlimit",l_memlimit},{"memresume",l_memresume},
      {"memclose",l_memclose},{"memfailed",l_memfailed},{NULL,NULL}};
    luaL_setfuncs(L,functions,0);
    if (memory(L)) {lua_pushcfunction(L,l_membytes);lua_setfield(L,-2,"membytes");}
  }
  lua_pop(L,1);
}
