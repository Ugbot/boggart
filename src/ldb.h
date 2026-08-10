#ifndef BOGGART_LDB_H
#define BOGGART_LDB_H
#include "lua.h"
#include "sqlite3.h"

/* Return the sqlite3* wrapped by the boggart.db connection userdata at the
 * given stack index, or raise a Lua error if it is not a live connection.
 * Lets other C subsystems (e.g. the swarm bus) journal to the same database
 * the Lua store opened. */
sqlite3 *boggart_db_handle(lua_State *L, int idx);

#endif
