#ifndef BOGGART_LTERMINAL_H
#define BOGGART_LTERMINAL_H
#include "bterm.h"
#include "lua.h"
/* Borrow only for an allocation-free native operation on the owning thread.
 * Validate every Lua argument first; never retain across a Lua allocation. */
bterm *boggart_terminal_borrow(lua_State *L,int index);
struct bpty *boggart_terminal_process_borrow(lua_State *L,int index);
void boggart_terminal_input_methods(lua_State *L);
void boggart_terminal_changed(lua_State *L,int index);
#endif
