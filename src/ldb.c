/* ldb.c -- minimal SQLite binding for boggart's local store.
 *
 *   db.open(path)               -> conn | nil, err
 *   conn:exec(sql)              -> true | nil, err          (raw, multi-statement; no params)
 *   conn:query(sql [, params])  -> rows (array of {col=val}) | nil, err
 *   conn:run(sql [, params])    -> { changes=n, rowid=n } | nil, err   (INSERT/UPDATE/DELETE)
 *   conn:close()                -> (idempotent)
 *
 * params is an array bound positionally to ? placeholders. Value mapping:
 * nil->NULL, boolean->0/1, integer->INTEGER, number->REAL, string->TEXT.
 * The amalgamation is compiled with FTS5 (see the Makefile), so full-text
 * search tables are available.
 */
#include <string.h>

#include "sqlite3.h"
#include "lua.h"
#include "lauxlib.h"
#include "ldb.h"

#define API_TYPE_DB "boggart.db"

typedef struct {
  sqlite3 *h; /* NULL once closed */
} DBConn;

sqlite3 *boggart_db_handle(lua_State *L, int idx) {
  DBConn *c = (DBConn *)luaL_checkudata(L, idx, API_TYPE_DB);
  if (!c->h) luaL_error(L, "db: connection is closed");
  return c->h;
}

static DBConn *check_conn(lua_State *L) {
  DBConn *c = (DBConn *)luaL_checkudata(L, 1, API_TYPE_DB);
  if (!c->h) luaL_error(L, "db: connection is closed");
  return c;
}

/* Bind params[1..n] (a Lua array at stack index `pidx`) to stmt. */
static int bind_params(lua_State *L, sqlite3_stmt *stmt, int pidx) {
  if (lua_isnoneornil(L, pidx)) return SQLITE_OK;
  luaL_checktype(L, pidx, LUA_TTABLE);
  int n = (int)luaL_len(L, pidx);
  for (int i = 1; i <= n; i++) {
    lua_geti(L, pidx, i);
    int t = lua_type(L, -1);
    int rc;
    if (t == LUA_TNIL) {
      rc = sqlite3_bind_null(stmt, i);
    } else if (t == LUA_TBOOLEAN) {
      rc = sqlite3_bind_int(stmt, i, lua_toboolean(L, -1));
    } else if (t == LUA_TNUMBER) {
      if (lua_isinteger(L, -1))
        rc = sqlite3_bind_int64(stmt, i, (sqlite3_int64)lua_tointeger(L, -1));
      else
        rc = sqlite3_bind_double(stmt, i, lua_tonumber(L, -1));
    } else if (t == LUA_TSTRING) {
      size_t len;
      const char *s = lua_tolstring(L, -1, &len);
      rc = sqlite3_bind_text(stmt, i, s, (int)len, SQLITE_TRANSIENT);
    } else {
      lua_pop(L, 1);
      return -1; /* unbindable type */
    }
    lua_pop(L, 1);
    if (rc != SQLITE_OK) return rc;
  }
  return SQLITE_OK;
}

/* Push one column value onto the Lua stack. */
static void push_column(lua_State *L, sqlite3_stmt *stmt, int col) {
  switch (sqlite3_column_type(stmt, col)) {
    case SQLITE_INTEGER:
      lua_pushinteger(L, (lua_Integer)sqlite3_column_int64(stmt, col));
      break;
    case SQLITE_FLOAT:
      lua_pushnumber(L, sqlite3_column_double(stmt, col));
      break;
    case SQLITE_NULL:
      lua_pushnil(L);
      break;
    default: { /* TEXT and BLOB both come back as Lua strings */
      const char *s = (const char *)sqlite3_column_blob(stmt, col);
      int len = sqlite3_column_bytes(stmt, col);
      lua_pushlstring(L, s ? s : "", (size_t)len);
      break;
    }
  }
}

static int fail(lua_State *L, sqlite3 *h, const char *ctx) {
  lua_pushnil(L);
  lua_pushfstring(L, "db %s: %s", ctx, sqlite3_errmsg(h));
  return 2;
}

static int l_open(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  sqlite3 *h = NULL;
  int rc = sqlite3_open(path, &h);
  if (rc != SQLITE_OK) {
    lua_pushnil(L);
    lua_pushfstring(L, "db open %s: %s", path, h ? sqlite3_errmsg(h) : "out of memory");
    if (h) sqlite3_close(h);
    return 2;
  }
  sqlite3_busy_timeout(h, 5000);
  DBConn *c = (DBConn *)lua_newuserdatauv(L, sizeof(DBConn), 0);
  c->h = h;
  luaL_setmetatable(L, API_TYPE_DB);
  return 1;
}

static int l_exec(lua_State *L) {
  DBConn *c = check_conn(L);
  const char *sql = luaL_checkstring(L, 2);
  char *err = NULL;
  int rc = sqlite3_exec(c->h, sql, NULL, NULL, &err);
  if (rc != SQLITE_OK) {
    lua_pushnil(L);
    lua_pushfstring(L, "db exec: %s", err ? err : sqlite3_errmsg(c->h));
    sqlite3_free(err);
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int l_query(lua_State *L) {
  DBConn *c = check_conn(L);
  const char *sql = luaL_checkstring(L, 2);
  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(c->h, sql, -1, &stmt, NULL) != SQLITE_OK)
    return fail(L, c->h, "prepare");
  if (bind_params(L, stmt, 3) != SQLITE_OK) {
    sqlite3_finalize(stmt);
    return fail(L, c->h, "bind");
  }

  int ncol = sqlite3_column_count(stmt);
  lua_newtable(L); /* rows */
  int nrow = 0, rc;
  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    lua_newtable(L); /* row */
    for (int i = 0; i < ncol; i++) {
      push_column(L, stmt, i);
      lua_setfield(L, -2, sqlite3_column_name(stmt, i));
    }
    lua_rawseti(L, -2, ++nrow);
  }
  if (rc != SQLITE_DONE) {
    sqlite3_finalize(stmt);
    return fail(L, c->h, "step");
  }
  sqlite3_finalize(stmt);
  return 1;
}

static int l_run(lua_State *L) {
  DBConn *c = check_conn(L);
  const char *sql = luaL_checkstring(L, 2);
  sqlite3_stmt *stmt = NULL;
  if (sqlite3_prepare_v2(c->h, sql, -1, &stmt, NULL) != SQLITE_OK)
    return fail(L, c->h, "prepare");
  if (bind_params(L, stmt, 3) != SQLITE_OK) {
    sqlite3_finalize(stmt);
    return fail(L, c->h, "bind");
  }
  int rc;
  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) { /* drain any rows */ }
  if (rc != SQLITE_DONE) {
    sqlite3_finalize(stmt);
    return fail(L, c->h, "step");
  }
  sqlite3_finalize(stmt);
  lua_newtable(L);
  lua_pushinteger(L, sqlite3_changes(c->h));
  lua_setfield(L, -2, "changes");
  lua_pushinteger(L, (lua_Integer)sqlite3_last_insert_rowid(c->h));
  lua_setfield(L, -2, "rowid");
  return 1;
}

static int l_close(lua_State *L) {
  DBConn *c = (DBConn *)luaL_checkudata(L, 1, API_TYPE_DB);
  if (c->h) { sqlite3_close(c->h); c->h = NULL; }
  return 0;
}

static const luaL_Reg conn_methods[] = {
  {"exec", l_exec},
  {"query", l_query},
  {"run", l_run},
  {"close", l_close},
  {"__gc", l_close},
  {NULL, NULL},
};

static const luaL_Reg db_lib[] = {
  {"open", l_open},
  {NULL, NULL},
};

int luaopen_boggart_db(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_DB);
  luaL_setfuncs(L, conn_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index"); /* mt.__index = mt */
  lua_pop(L, 1);

  luaL_newlib(L, db_lib);
  return 1;
}
