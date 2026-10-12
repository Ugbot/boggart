/* bogcrash.h -- the crash handler (see bogcrash.c, BOG-9). */
#ifndef BOGCRASH_H
#define BOGCRASH_H

#include "lua.h"

/* Install once, first thing in main(): SEGV/BUS/ILL/FPE/ABRT/TRAP (POSIX) or
 * the unhandled-exception filter (Windows). Reports go to <data dir>/crashes. */
void bog_crash_install(void);
/* The interpreter whose Lua stack a report should show. */
void bog_crash_set_lua(lua_State *L);
/* Run fn (async-signal-safe!) before the process dies -- the TUI's tty restore. */
void bog_crash_on_fatal(void (*fn)(void));
/* Where reports go (tests point this at a temp dir). */
void bog_crash_set_dir(const char *dir);
const char *bog_crash_dir(void);
int bog_crash_installed(void);

#endif
