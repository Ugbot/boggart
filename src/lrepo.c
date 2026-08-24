/* lrepo.c -- the semantic data API ("repo").
 *
 * The harness and skills call OPERATIONS -- kv_get, sess_list, mem_search --
 * they never write SQL. Those operations are implemented HERE, in C, and
 * dispatched to a storage BACKEND chosen when the repo is bound. Today the only
 * backend is SQLite; the whole point of the layer is that a Postgres backend is
 * just a second set of identically-named methods, so swapping the store touches
 * no Lua and no skill.
 *
 *   repo.sqlite(dbconn)  -> a repo bound to that SQLite connection
 *   r:backend()          -> "sqlite"
 *   r:kv_get(k)          -> value | nil
 *   r:kv_set(k, v)       -> true
 *   r:kv_del(k)          -> rows_deleted
 *   r:kv_list([prefix])  -> { {key=, value=}, ... }
 *
 * THE METATABLE IS THE VTABLE: repo.sqlite() hands back a userdata whose
 * __index is the SQLite method table. A future repo.postgres(dsn) hands back one
 * whose identically-named methods speak libpq. `r:kv_get(k)` dispatches to the
 * right implementation with no caller change -- that is the swap seam.
 *
 * The SQLite backend BORROWS the sqlite3* from the Lua db connection (lua/store
 * still opens it, runs migrations, sets pragmas). The connection is pinned as a
 * uservalue so it cannot be closed out from under a live repo; the repo has no
 * __gc of its own and never closes the handle it borrowed.
 */
#include <string.h>
#include <time.h>

#include "sqlite3.h"
#include "lua.h"
#include "lauxlib.h"
#include "ldb.h" /* boggart_db_handle */

#define REPO_SQLITE "boggart.repo.sqlite"

typedef struct {
  sqlite3 *h; /* borrowed from the bound connection; NULL once unbound */
} RepoSqlite;

static RepoSqlite *check_sqlite(lua_State *L) {
  RepoSqlite *r = (RepoSqlite *)luaL_checkudata(L, 1, REPO_SQLITE);
  if (!r->h) luaL_error(L, "repo: not bound to an open connection");
  return r;
}

static int rfail(lua_State *L, sqlite3 *h, const char *ctx) {
  return luaL_error(L, "repo %s: %s", ctx, sqlite3_errmsg(h));
}

/* ---- kv ---------------------------------------------------------------- */

static int sq_kv_get(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  size_t klen;
  const char *k = luaL_checklstring(L, 2, &klen);
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(r->h, "SELECT value FROM kv WHERE key=?", -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "kv_get prepare");
  sqlite3_bind_text(st, 1, k, (int)klen, SQLITE_TRANSIENT);
  int rc = sqlite3_step(st);
  if (rc == SQLITE_ROW) {
    const char *v = (const char *)sqlite3_column_blob(st, 0);
    int vlen = sqlite3_column_bytes(st, 0);
    lua_pushlstring(L, v ? v : "", (size_t)vlen);
  } else if (rc == SQLITE_DONE) {
    lua_pushnil(L);
  } else {
    sqlite3_finalize(st);
    return rfail(L, r->h, "kv_get step");
  }
  sqlite3_finalize(st);
  return 1;
}

static int sq_kv_set(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  size_t klen, vlen;
  const char *k = luaL_checklstring(L, 2, &klen);
  const char *v = luaL_checklstring(L, 3, &vlen);
  sqlite3_stmt *st = NULL;
  const char *sql =
    "INSERT INTO kv(key,value,updated) VALUES(?,?,?) "
    "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated=excluded.updated";
  if (sqlite3_prepare_v2(r->h, sql, -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "kv_set prepare");
  sqlite3_bind_text(st, 1, k, (int)klen, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 2, v, (int)vlen, SQLITE_TRANSIENT);
  sqlite3_bind_int64(st, 3, (sqlite3_int64)time(NULL));
  int rc = sqlite3_step(st);
  sqlite3_finalize(st);
  if (rc != SQLITE_DONE) return rfail(L, r->h, "kv_set step");
  lua_pushboolean(L, 1);
  return 1;
}

static int sq_kv_del(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  size_t klen;
  const char *k = luaL_checklstring(L, 2, &klen);
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(r->h, "DELETE FROM kv WHERE key=?", -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "kv_del prepare");
  sqlite3_bind_text(st, 1, k, (int)klen, SQLITE_TRANSIENT);
  int rc = sqlite3_step(st);
  sqlite3_finalize(st);
  if (rc != SQLITE_DONE) return rfail(L, r->h, "kv_del step");
  lua_pushinteger(L, sqlite3_changes(r->h));
  return 1;
}

static int sq_kv_list(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  const char *prefix = luaL_optstring(L, 2, NULL);
  sqlite3_stmt *st = NULL;
  if (prefix && prefix[0]) {
    if (sqlite3_prepare_v2(r->h, "SELECT key,value FROM kv WHERE key LIKE ? ORDER BY key",
                           -1, &st, NULL) != SQLITE_OK)
      return rfail(L, r->h, "kv_list prepare");
    /* bind prefix || '%' */
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    luaL_addstring(&b, prefix);
    luaL_addchar(&b, '%');
    luaL_pushresult(&b);
    size_t plen;
    const char *pat = lua_tolstring(L, -1, &plen);
    sqlite3_bind_text(st, 1, pat, (int)plen, SQLITE_TRANSIENT);
    lua_pop(L, 1);
  } else {
    if (sqlite3_prepare_v2(r->h, "SELECT key,value FROM kv ORDER BY key", -1, &st, NULL) != SQLITE_OK)
      return rfail(L, r->h, "kv_list prepare");
  }
  lua_newtable(L); /* rows */
  int n = 0, rc;
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    lua_newtable(L); /* row */
    const char *kk = (const char *)sqlite3_column_blob(st, 0);
    int kl = sqlite3_column_bytes(st, 0);
    const char *vv = (const char *)sqlite3_column_blob(st, 1);
    int vl = sqlite3_column_bytes(st, 1);
    lua_pushlstring(L, kk ? kk : "", (size_t)kl);
    lua_setfield(L, -2, "key");
    lua_pushlstring(L, vv ? vv : "", (size_t)vl);
    lua_setfield(L, -2, "value");
    lua_rawseti(L, -2, ++n);
  }
  if (rc != SQLITE_DONE) {
    sqlite3_finalize(st);
    return rfail(L, r->h, "kv_list step");
  }
  sqlite3_finalize(st);
  return 1;
}

static int sq_backend(lua_State *L) {
  luaL_checkudata(L, 1, REPO_SQLITE);
  lua_pushstring(L, "sqlite");
  return 1;
}

/* ---- bind -------------------------------------------------------------- */

/* repo.sqlite(dbconn) -> repo bound to that connection's sqlite3 handle. */
static int l_sqlite(lua_State *L) {
  sqlite3 *h = boggart_db_handle(L, 1); /* raises unless a live boggart.db */
  RepoSqlite *r = (RepoSqlite *)lua_newuserdatauv(L, sizeof(RepoSqlite), 1);
  r->h = h;
  /* Pin the connection for as long as the repo lives, so the borrowed handle
   * cannot be closed under us. Slot 1 of the repo's uservalues. */
  lua_pushvalue(L, 1);
  lua_setiuservalue(L, -2, 1);
  luaL_setmetatable(L, REPO_SQLITE);
  return 1;
}

static const luaL_Reg sqlite_methods[] = {
  {"kv_get", sq_kv_get},
  {"kv_set", sq_kv_set},
  {"kv_del", sq_kv_del},
  {"kv_list", sq_kv_list},
  {"backend", sq_backend},
  {NULL, NULL},
};

static const luaL_Reg repo_lib[] = {
  {"sqlite", l_sqlite},
  {NULL, NULL},
};

int luaopen_boggart_repo(lua_State *L) {
  luaL_newmetatable(L, REPO_SQLITE);
  luaL_setfuncs(L, sqlite_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index"); /* mt.__index = mt */
  lua_pop(L, 1);

  luaL_newlib(L, repo_lib);
  return 1;
}
