#ifndef BOGGART_TERMINALIMAGE_H
#define BOGGART_TERMINALIMAGE_H
#include "lua.h"
#include "termgrid.h"
typedef struct TerminalImage TerminalImage;
/* Borrow only after Lua argument validation; no Lua allocation during use. */
int terminalimage_test(lua_State *L,int index);
TerminalImage *terminalimage_borrow(lua_State *L,int index);
size_t terminalimage_count(const TerminalImage *image);
size_t terminalimage_columns(const TerminalImage *image);
tg_row *terminalimage_row(const TerminalImage *image,size_t index);
void terminalimage_open(lua_State *L);
#endif
