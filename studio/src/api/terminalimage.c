#include "terminalimage.h"
#include "lauxlib.h"
#include <stdlib.h>
#include <string.h>
#define IMAGE_MT "TerminalImage"
#define BUILD_MT "TerminalImageBuild"
#define IMAGE_BYTES (8u*1024u*1024u)
struct TerminalImage {
  tg_row **rows;size_t count,columns,history,bytes;
  uint64_t generation,captures;bool closed;
};
typedef struct {
  tg_row **prior,**next;size_t prior_count,next_count;
  uint64_t expected;
} ImageBuild;
static void release_rows(tg_row **rows,size_t count) {
  if(rows)for(size_t i=0;i<count;i++)tg_release(rows[i]);free(rows);
}
static void clear_build(ImageBuild *build) {
  release_rows(build->prior,build->prior_count);release_rows(build->next,build->next_count);
  memset(build,0,sizeof *build);
}
static int build_gc(lua_State *L){clear_build(luaL_checkudata(L,1,BUILD_MT));return 0;}
int terminalimage_test(lua_State *L,int index){return luaL_testudata(L,index,IMAGE_MT)!=NULL;}
TerminalImage *terminalimage_borrow(lua_State *L,int index) {
  TerminalImage *image=luaL_checkudata(L,index,IMAGE_MT);
  luaL_argcheck(L,!image->closed,index,"closed terminal image");return image;
}
size_t terminalimage_count(const TerminalImage *image){return image->count;}
size_t terminalimage_columns(const TerminalImage *image){return image->columns;}
tg_row *terminalimage_row(const TerminalImage *image,size_t index){return index<image->count ? image->rows[index] : NULL;}
static int close_image(lua_State *L) {
  TerminalImage *image=luaL_checkudata(L,1,IMAGE_MT);
  release_rows(image->rows,image->count);image->rows=NULL;image->count=image->columns=image->history=image->bytes=0;
  image->closed=true;image->generation++;lua_pushnil(L);lua_setiuservalue(L,1,1);return 0;
}
static void field(lua_State *L,int index,const char *name) {
  index=lua_absindex(L,index);lua_pushstring(L,name);lua_rawget(L,index);
}
static lua_Integer integer(lua_State *L,int index,const char *name,lua_Integer low,lua_Integer high) {
  field(L,index,name);lua_Integer n=luaL_checkinteger(L,-1);lua_pop(L,1);
  if(n<low || n>high)luaL_error(L,"image %s out of range",name);return n;
}
static size_t array(lua_State *L,int index,size_t maximum) {
  index=lua_absindex(L,index);luaL_checktype(L,index,LUA_TTABLE);size_t n=lua_rawlen(L,index),keys=0;
  if(n>maximum)luaL_error(L,"image array too large");
  lua_pushnil(L);while(lua_next(L,index)) {
    if(!lua_isinteger(L,-2) || lua_tointeger(L,-2)<1 || (lua_Unsigned)lua_tointeger(L,-2)>n)luaL_error(L,"image array must be dense");
    keys++;lua_pop(L,1);
  }
  if(keys!=n)luaL_error(L,"image array must be dense");return n;
}
static void push_row(lua_State *L,int view,size_t index,size_t history) {
  if(index<history){field(L,view,"scrollback");field(L,-1,"rows");lua_remove(L,-2);}
  else {field(L,view,"screen");index-=history;}
  lua_rawgeti(L,-1,(lua_Integer)index+1);lua_remove(L,-2);
}
static tg_row *capture_row(lua_State *L,int index,size_t columns,size_t budget) {
  int base=lua_gettop(L);index=lua_absindex(L,index);luaL_checktype(L,index,LUA_TTABLE);
  luaL_checkstack(L,(int)columns+24,"image row text roots");
  field(L,index,"cells");int cells=lua_gettop(L);
  if(array(L,cells,4096)!=columns)luaL_error(L,"image row width mismatch");
  tg_value *values=lua_newuserdatauv(L,columns*sizeof *values,0);memset(values,0,columns*sizeof *values);
  size_t bytes=sizeof(tg_row)+columns*sizeof(tg_cell);
  if(bytes>budget)luaL_error(L,"image byte limit exceeded");
  for(size_t x=0;x<columns;x++) {
    lua_rawgeti(L,cells,(lua_Integer)x+1);int cell=lua_gettop(L);luaL_checktype(L,cell,LUA_TTABLE);
    values[x].width=(uint8_t)integer(L,cell,"width",0,2);values[x].flags=(uint8_t)integer(L,cell,"flags",0,15);
    field(L,cell,"style");int style=lua_gettop(L);luaL_checktype(L,style,LUA_TTABLE);
    values[x].style=(lpage_style){(uint32_t)integer(L,style,"fg",0,UINT32_MAX),(uint32_t)integer(L,style,"bg",0,UINT32_MAX),
      (uint32_t)integer(L,style,"underline",0,UINT32_MAX),(uint32_t)integer(L,style,"attrs",0,UINT32_MAX)};
    lua_pop(L,1);field(L,cell,"text");luaL_checktype(L,-1,LUA_TSTRING);
    values[x].text=lua_tolstring(L,-1,&values[x].length);
    if(values[x].length>UINT16_MAX || values[x].length+1>budget-bytes)luaL_error(L,"image text/byte limit exceeded");
    bytes+=values[x].length+1;lua_remove(L,cell); /* retain each parsed string */
  }
  tg_row *row=tg_capture_values(values,columns);
  if(!row)luaL_error(L,"cannot capture image row");
  lua_settop(L,base);return row; /* No allocation before caller takes ownership. */
}
static int prepare_image(lua_State *L) {
  TerminalImage *image=terminalimage_borrow(L,1);ImageBuild *build=luaL_checkudata(L,3,BUILD_MT);
  luaL_checktype(L,2,LUA_TTABLE);uint64_t generation=build->expected;
  lua_getiuservalue(L,1,1);int prior_view=lua_gettop(L);
  if(image->closed || image->generation!=generation)luaL_error(L,"terminal image changed during apply");
  /* Retain all prior native rows before allocating/parsing more Lua values. */
  size_t prior_history=image->history,prior_columns=image->columns;
  build->prior_count=image->count;
  if(build->prior_count) {
    build->prior=calloc(build->prior_count,sizeof *build->prior);
    if(!build->prior)luaL_error(L,"cannot retain image rows");
    for(size_t i=0;i<build->prior_count;i++) {
      if(!tg_retain(image->rows[i]))luaL_error(L,"image row reference overflow");build->prior[i]=image->rows[i];
    }
  }
  size_t columns=(size_t)integer(L,2,"cols",1,4096),rows=(size_t)integer(L,2,"rows",1,4096);
  field(L,2,"screen");if(array(L,-1,4096)!=rows)luaL_error(L,"image height mismatch");lua_pop(L,1);
  field(L,2,"scrollback");luaL_checktype(L,-1,LUA_TTABLE);field(L,-1,"rows");size_t history=array(L,-1,256);lua_pop(L,2);
  size_t count=rows+history;if(columns*count>32768)luaL_error(L,"image cell limit exceeded");
  build->next_count=count;build->next=calloc(count,sizeof *build->next);
  if(!build->next)luaL_error(L,"cannot allocate image rows");
  size_t bytes=0;uint64_t captures=0;
  for(size_t i=0;i<count;i++) {
    int base=lua_gettop(L);push_row(L,2,i,history);int row=lua_gettop(L);bool same=false;
    if(i<build->prior_count && columns==prior_columns) {
      push_row(L,prior_view,i,prior_history);same=lua_rawequal(L,row,-1);lua_pop(L,1);
    }
    tg_row *next;
    if(same) {
      next=build->prior[i];if(!tg_retain(next))luaL_error(L,"image row reference overflow");
    } else {
      next=capture_row(L,row,columns,IMAGE_BYTES-bytes);captures++;
      if(i<build->prior_count && tg_equal(next,build->prior[i])) {
        tg_release(next);next=build->prior[i];if(!tg_retain(next))luaL_error(L,"image row reference overflow");
      }
    }
    build->next[i]=next;
    if(next->bytes>IMAGE_BYTES-bytes)luaL_error(L,"image byte limit exceeded");bytes+=next->bytes;
    lua_settop(L,base);
  }
  lua_pushvalue(L,2); /* stack already reserved; setiuservalue cannot allocate */
  if(image->closed || image->generation!=generation)luaL_error(L,"terminal image changed during apply");
  release_rows(image->rows,image->count);image->rows=build->next;build->next=NULL;build->next_count=0;
  image->columns=columns;image->count=count;image->history=history;image->bytes=bytes;
  image->generation++;image->captures+=captures;lua_setiuservalue(L,1,1);return 0;
}
static int apply_image(lua_State *L) {
  uint64_t generation=terminalimage_borrow(L,1)->generation;luaL_checktype(L,2,LUA_TTABLE);
  ImageBuild *build=lua_newuserdatauv(L,sizeof *build,0);memset(build,0,sizeof *build);build->expected=generation;luaL_setmetatable(L,BUILD_MT);
  int staged=lua_gettop(L);lua_pushcfunction(L,prepare_image);lua_pushvalue(L,1);lua_pushvalue(L,2);lua_pushvalue(L,staged);
  int status=lua_pcall(L,3,0,0);clear_build(build); /* eager on success AND error */
  if(status!=LUA_OK)return lua_error(L);lua_pushboolean(L,true);return 1;
}
static int create_image(lua_State *L) {
  TerminalImage *image=lua_newuserdatauv(L,sizeof *image,1);memset(image,0,sizeof *image);luaL_setmetatable(L,IMAGE_MT);return 1;
}
static int stats(lua_State *L) {
  TerminalImage *image=luaL_checkudata(L,1,IMAGE_MT);
  size_t count=image->count,columns=image->columns,history=image->history,bytes=image->bytes;
  uint64_t generation=image->generation,captures=image->captures;bool closed=image->closed;
  lua_createtable(L,0,7);
#define STAT(name,value) lua_pushinteger(L,(lua_Integer)(value));lua_setfield(L,-2,name)
  STAT("rows",count);STAT("cols",columns);STAT("history",history);STAT("bytes",bytes);STAT("generation",generation);STAT("captures",captures);
#undef STAT
  lua_pushboolean(L,closed);lua_setfield(L,-2,"closed");return 1;
}
void terminalimage_open(lua_State *L) {
  luaL_newmetatable(L,BUILD_MT);lua_pushcfunction(L,build_gc);lua_setfield(L,-2,"__gc");lua_pop(L,1);
  luaL_newmetatable(L,IMAGE_MT);
  const luaL_Reg methods[]={{"apply",apply_image},{"stats",stats},{"close",close_image},{"__gc",close_image},{"__close",close_image},{NULL,NULL}};
  luaL_setfuncs(L,methods,0);lua_pushvalue(L,-1);lua_setfield(L,-2,"__index");lua_pop(L,1);
  lua_pushcfunction(L,create_image);lua_setfield(L,-2,"terminal_image");
}
