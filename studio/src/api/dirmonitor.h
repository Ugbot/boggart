#ifndef STUDIO_DIRMONITOR_H
#define STUDIO_DIRMONITOR_H

#include "api.h"

/* Installs system.dirmonitor() and system.dirmonitor_caps() into the table on
 * the top of the stack, and registers the monitor metatable. Called from
 * luaopen_system so the watcher arrives with the rest of the platform surface
 * rather than as a module Lua has to remember to require. */
void dirmonitor_open(lua_State *L);

#endif
