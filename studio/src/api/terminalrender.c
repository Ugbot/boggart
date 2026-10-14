#include "api.h"
#include "lterminal.h"
#include "rencache.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "terminalrender_source.h"

#define TERMINAL_RENDER_MT "TerminalRenderer"
#define VISIBLE_LIMIT 8192
typedef struct {
  uint64_t revision; tg_row *row;
  RenRect bounds;
  int cell_width,cell_height,tab_width;
} CachedRow;
typedef struct {
  CachedRow *rows;
  size_t count, capacity;
  uint64_t captures, submissions;
  bool closed;
} TerminalRenderer;

static RenColor read_color(lua_State *L, int index) {
  index=lua_absindex(L,index); luaL_checktype(L,index,LUA_TTABLE);
  uint8_t rgba[4];
  for(int i=0;i<4;i++) {
    lua_rawgeti(L,index,i+1);
    lua_Integer value=i==3 ? luaL_optinteger(L,-1,255) : luaL_checkinteger(L,-1);
    luaL_argcheck(L,value>=0 && value<=255,index,"color channels must be in 0..255");
    rgba[i]=(uint8_t)value; lua_pop(L,1);
  }
  return (RenColor){.r=rgba[0],.g=rgba[1],.b=rgba[2],.a=rgba[3]};
}
static tg_theme read_theme(lua_State *L,int index) {
  tg_theme theme; index=lua_absindex(L,index); luaL_checktype(L,index,LUA_TTABLE);
  lua_pushliteral(L,"foreground"); lua_rawget(L,index); theme.foreground=read_color(L,-1); lua_pop(L,1);
  lua_pushliteral(L,"background"); lua_rawget(L,index); theme.background=read_color(L,-1); lua_pop(L,1);
  lua_pushliteral(L,"palette"); lua_rawget(L,index); luaL_checktype(L,-1,LUA_TTABLE);
  for(int i=0;i<16;i++){lua_rawgeti(L,-1,i); theme.palette[i]=read_color(L,-1); lua_pop(L,1);}
  lua_pop(L,1); return theme;
}
static int dispose(lua_State *L) {
  TerminalRenderer *ctx=luaL_checkudata(L,1,TERMINAL_RENDER_MT);
  for(size_t i=0;i<ctx->count;i++)tg_release(ctx->rows[i].row);
  free(ctx->rows); ctx->rows=NULL; ctx->count=ctx->capacity=0; ctx->closed=true;
  for(int i=1;i<=3;i++){lua_pushnil(L); lua_setiuservalue(L,1,i);}
  return 0;
}
static int create(lua_State *L) {
  luaL_checkudata(L,1,API_TYPE_FONT); read_theme(L,3);
  TerminalRenderer *ctx=lua_newuserdatauv(L,sizeof *ctx,3); memset(ctx,0,sizeof *ctx);
  luaL_setmetatable(L,TERMINAL_RENDER_MT);
  for(int i=1;i<=3;i++){lua_pushvalue(L,i); lua_setiuservalue(L,-2,i);}
  /* All Lua allocations precede borrowing the source and checking the owner. */
  luaL_argcheck(L,*(RenFont **)luaL_checkudata(L,1,API_TYPE_FONT)!=NULL,1,"closed font");
  (void)boggart_terminal_borrow(L,2);
  return 1;
}
static double position(lua_State *L,int index) {
  double value=luaL_checknumber(L,index);
  luaL_argcheck(L,isfinite(value) && value>=-100000000 && value<=100000000,index,"position out of range");
  return value;
}
static int draw(lua_State *L) {
  TerminalRenderer *ctx=luaL_checkudata(L,1,TERMINAL_RENDER_MT);
  luaL_argcheck(L,!ctx->closed,1,"closed terminal renderer");
  double x=position(L,2),y=position(L,3);
  lua_Integer cw=luaL_checkinteger(L,4),ch=luaL_checkinteger(L,5);
  lua_Integer first=luaL_checkinteger(L,6),last=luaL_checkinteger(L,7);
  luaL_argcheck(L,cw>=1 && cw<=4096,4,"cell width out of range");
  luaL_argcheck(L,ch>=1 && ch<=4096,5,"cell height out of range");
  luaL_argcheck(L,first>=1 && first<=1004096,6,"first row out of range");
  luaL_argcheck(L,last>=first && last-first<VISIBLE_LIMIT,7,"visible row count out of range");
  double bottom=y+((double)last-1)*(double)ch;
  luaL_argcheck(L,bottom>=-100000000 && bottom<=100000000,3,"row position out of range");
  lua_getiuservalue(L,1,3); tg_theme theme=read_theme(L,-1); lua_pop(L,1);
  lua_getiuservalue(L,1,1); RenFont **owner=luaL_checkudata(L,-1,API_TYPE_FONT);
  lua_getiuservalue(L,1,2);
  luaL_argcheck(L,!ctx->closed,1,"closed terminal renderer");
  luaL_argcheck(L,*owner!=NULL,1,"closed font"); RenFont *font=*owner;
  bterm *term=boggart_terminal_borrow(L,-1);
  /* No Lua operation until the native borrow is finished. Cached/queued rows
   * own full text/style values; none retain screen pointers or pool IDs. */
  const lpage_screen *screen=bterm_screen(term);
  size_t history=lpage_history_count(screen),total=history+lpage_rows(screen),columns=lpage_columns(screen);
  if((size_t)last>total)last=(lua_Integer)total;
  size_t count=last<first ? 0 : (size_t)(last-first+1);
  if(count>ctx->capacity) {
    CachedRow *grown=realloc(ctx->rows,count*sizeof *grown);
    if(!grown)return luaL_error(L,"cannot allocate terminal row cache");
    memset(grown+ctx->capacity,0,(count-ctx->capacity)*sizeof *grown);
    ctx->rows=grown; ctx->capacity=count;
  }
  for(size_t i=count;i<ctx->count;i++){tg_release(ctx->rows[i].row); memset(&ctx->rows[i],0,sizeof ctx->rows[i]);}
  ctx->count=count;
  int tab_width=ren_get_font_tab_width(font);
  for(size_t i=0;i<count;i++) {
    size_t index=(size_t)first-1+i;
    const lpage_row *source=index<history ? lpage_history(screen,index) : lpage_visible(screen,index-history);
    CachedRow *cached=&ctx->rows[i];
    if(!cached->row || cached->revision!=source->revision || cached->row->columns!=columns) {
      tg_row *row=tg_capture(term,source,columns);
      if(!row)return luaL_error(L,"cannot capture terminal row");
      ctx->captures++;
      if(tg_equal(row,cached->row))tg_release(row);
      else {tg_release(cached->row); cached->row=row; cached->cell_width=0;}
      cached->revision=source->revision;
    }
    if(cached->cell_width!=cw || cached->cell_height!=ch || cached->tab_width!=tab_width) {
      cached->bounds=tg_measure(cached->row,font,(int)cw,(int)ch);
      cached->cell_width=(int)cw; cached->cell_height=(int)ch; cached->tab_width=tab_width;
    }
  }
  for(size_t i=0;i<count;i++) {
    int py=(int)(y+((double)first-1+(double)i)*(double)ch);
    if(!rencache_draw_row(ctx->rows[i].row,font,&theme,x,py,(int)cw,(int)ch,ctx->rows[i].bounds))
      return luaL_error(L,"cannot queue terminal row");
    ctx->submissions++;
  }
  return 0;
}
static int stats(lua_State *L) {
  TerminalRenderer *ctx=luaL_checkudata(L,1,TERMINAL_RENDER_MT);
  uint64_t captures=ctx->captures,submissions=ctx->submissions; size_t count=ctx->count;
  lua_createtable(L,0,3);
  lua_pushinteger(L,(lua_Integer)captures); lua_setfield(L,-2,"captures");
  lua_pushinteger(L,(lua_Integer)submissions); lua_setfield(L,-2,"submissions");
  lua_pushinteger(L,(lua_Integer)count); lua_setfield(L,-2,"cached_rows");
  return 1;
}
static int sources(lua_State *L) {
  lua_createtable(L,0,11);
  for(size_t i=0;i<sizeof terminalrender_source_files/sizeof *terminalrender_source_files;i++) {
    lua_pushstring(L,terminalrender_source_files[i].sha256);
    lua_setfield(L,-2,terminalrender_source_files[i].path);
  }
  return 1;
}
void terminalrender_open(lua_State *L) {
  luaL_newmetatable(L,TERMINAL_RENDER_MT);
  lua_pushcfunction(L,dispose); lua_setfield(L,-2,"__gc");
  lua_pushcfunction(L,dispose); lua_setfield(L,-2,"__close");
  lua_pushcfunction(L,draw); lua_setfield(L,-2,"draw");
  lua_pushcfunction(L,stats); lua_setfield(L,-2,"stats");
  lua_pushvalue(L,-1); lua_setfield(L,-2,"__index"); lua_pop(L,1);
  lua_pushcfunction(L,create); lua_setfield(L,-2,"new_terminal");
  lua_pushcfunction(L,sources); lua_setfield(L,-2,"terminal_sources");
}
