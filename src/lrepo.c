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

/* ---- the model catalog ----------------------------------------------------
 *
 * Which model lives where, what it can do, and which credential slot may be
 * used with which host. These are operations rather than SQL in Lua for the
 * reason the file exists: the harness calls named operations and a second
 * backend is a second set of identically-named methods. They are also on the
 * hot path -- a route is resolved for every request -- and one of them
 * (provider_for_url) is a SECURITY lookup: src/lauth.c asks it whether a
 * credential slot is registered for the host a request is going to, and
 * refuses the request's key if it is not. That answer must come from the store,
 * not from whichever caller assembled the request.
 */

/* Push a row of the given statement as a table of column name -> value. */
static void push_row(lua_State *L, sqlite3_stmt *st) {
  int ncol = sqlite3_column_count(st);
  lua_newtable(L);
  for (int i = 0; i < ncol; i++) {
    const char *name = sqlite3_column_name(st, i);
    if (!name) continue;
    switch (sqlite3_column_type(st, i)) {
      case SQLITE_NULL:
        continue;                       /* absent rather than a false value */
      case SQLITE_INTEGER:
        lua_pushinteger(L, (lua_Integer)sqlite3_column_int64(st, i));
        break;
      case SQLITE_FLOAT:
        lua_pushnumber(L, sqlite3_column_double(st, i));
        break;
      default: {
        const char *v = (const char *)sqlite3_column_blob(st, i);
        int vlen = sqlite3_column_bytes(st, i);
        lua_pushlstring(L, v ? v : "", (size_t)vlen);
        break;
      }
    }
    lua_setfield(L, -2, name);
  }
}

/* r:model_get(id) -> row | nil */
static int sq_model_get(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  size_t idlen;
  const char *id = luaL_checklstring(L, 2, &idlen);
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(r->h, "SELECT * FROM models WHERE id=?", -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "model_get prepare");
  sqlite3_bind_text(st, 1, id, (int)idlen, SQLITE_TRANSIENT);
  int rc = sqlite3_step(st);
  if (rc == SQLITE_ROW) push_row(L, st);
  else if (rc == SQLITE_DONE) lua_pushnil(L);
  else { sqlite3_finalize(st); return rfail(L, r->h, "model_get step"); }
  sqlite3_finalize(st);
  return 1;
}

/* r:provider_get(name) -> row | nil */
static int sq_provider_get(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  size_t nlen;
  const char *name = luaL_checklstring(L, 2, &nlen);
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(r->h, "SELECT * FROM providers WHERE name=?", -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "provider_get prepare");
  sqlite3_bind_text(st, 1, name, (int)nlen, SQLITE_TRANSIENT);
  int rc = sqlite3_step(st);
  if (rc == SQLITE_ROW) push_row(L, st);
  else if (rc == SQLITE_DONE) lua_pushnil(L);
  else { sqlite3_finalize(st); return rfail(L, r->h, "provider_get step"); }
  sqlite3_finalize(st);
  return 1;
}

/* r:catalog_list("models"|"providers"|"roles") -> { row, ... } */
static int sq_catalog_list(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  const char *what = luaL_optstring(L, 2, "models");
  const char *sql;
  if (strcmp(what, "providers") == 0)   sql = "SELECT * FROM providers ORDER BY name";
  else if (strcmp(what, "roles") == 0)  sql = "SELECT * FROM roles ORDER BY name";
  else if (strcmp(what, "models") == 0) sql = "SELECT * FROM models ORDER BY id";
  else return luaL_error(L, "catalog_list: unknown table %s", what);
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(r->h, sql, -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "catalog_list prepare");
  lua_newtable(L);
  int n = 0, rc;
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    push_row(L, st);
    lua_rawseti(L, -2, ++n);
  }
  sqlite3_finalize(st);
  if (rc != SQLITE_DONE) return rfail(L, r->h, "catalog_list step");
  return 1;
}

/* r:models_where{ vision=true, tools=true, min_context=500000, provider="xai" }
 * -> { row, ... }
 *
 * The capability query. Every filter is optional and absent means "do not
 * care", so this is one statement with guards rather than a query builder --
 * a catalog has hundreds of rows, not millions.
 */
static int sq_models_where(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  const char *sql =
    "SELECT * FROM models WHERE "
    "(:provider IS NULL OR provider = :provider) AND "
    "(:vision IS NULL OR vision = 1) AND "
    "(:tools IS NULL OR tools = 1) AND "
    "(:effort IS NULL OR effort = 1) AND "
    "(:min_context IS NULL OR context >= :min_context) "
    "ORDER BY id";
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(r->h, sql, -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "models_where prepare");

  lua_getfield(L, 2, "provider");
  if (lua_isstring(L, -1)) {
    size_t plen; const char *pv = lua_tolstring(L, -1, &plen);
    sqlite3_bind_text(st, sqlite3_bind_parameter_index(st, ":provider"),
                      pv, (int)plen, SQLITE_TRANSIENT);
  }
  lua_pop(L, 1);
  static const char *flags[] = { "vision", "tools", "effort", NULL };
  for (int i = 0; flags[i]; i++) {
    lua_getfield(L, 2, flags[i]);
    if (lua_toboolean(L, -1)) {
      char param[16];
      snprintf(param, sizeof(param), ":%s", flags[i]);
      sqlite3_bind_int(st, sqlite3_bind_parameter_index(st, param), 1);
    }
    lua_pop(L, 1);
  }
  lua_getfield(L, 2, "min_context");
  if (lua_isnumber(L, -1)) {
    sqlite3_bind_int64(st, sqlite3_bind_parameter_index(st, ":min_context"),
                       (sqlite3_int64)lua_tointeger(L, -1));
  }
  lua_pop(L, 1);

  lua_newtable(L);
  int n = 0, rc;
  while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
    push_row(L, st);
    lua_rawseti(L, -2, ++n);
  }
  sqlite3_finalize(st);
  if (rc != SQLITE_DONE) return rfail(L, r->h, "models_where step");
  return 1;
}

/* Upserts. `row` is a table of column -> value; unknown keys are ignored so a
 * catalog file carrying a field this build does not know is imported rather
 * than rejected. */
static void bind_field(lua_State *L, sqlite3_stmt *st, int tbl, const char *col,
                       const char *param) {
  int idx = sqlite3_bind_parameter_index(st, param);
  if (idx == 0) return;
  lua_getfield(L, tbl, col);
  switch (lua_type(L, -1)) {
    case LUA_TSTRING: {
      size_t len; const char *v = lua_tolstring(L, -1, &len);
      sqlite3_bind_text(st, idx, v, (int)len, SQLITE_TRANSIENT);
      break;
    }
    case LUA_TNUMBER:
      if (lua_isinteger(L, -1)) sqlite3_bind_int64(st, idx, (sqlite3_int64)lua_tointeger(L, -1));
      else sqlite3_bind_double(st, idx, lua_tonumber(L, -1));
      break;
    case LUA_TBOOLEAN:
      sqlite3_bind_int(st, idx, lua_toboolean(L, -1) ? 1 : 0);
      break;
    default:
      sqlite3_bind_null(st, idx);
      break;
  }
  lua_pop(L, 1);
}

/* r:model_put{ id=, provider=, context=, ... } -> true */
static int sq_model_put(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  const char *sql =
    "INSERT INTO models(id,provider,label,context,max_output,tools,vision,effort,"
    "input_price,output_price,source,updated) "
    "VALUES(:id,:provider,:label,:context,:max_output,:tools,:vision,:effort,"
    ":input_price,:output_price,:source,:updated) "
    "ON CONFLICT(id) DO UPDATE SET provider=excluded.provider, label=excluded.label, "
    "context=excluded.context, max_output=excluded.max_output, tools=excluded.tools, "
    "vision=excluded.vision, effort=excluded.effort, input_price=excluded.input_price, "
    "output_price=excluded.output_price, source=excluded.source, updated=excluded.updated";
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(r->h, sql, -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "model_put prepare");
  static const char *cols[] = { "id", "provider", "label", "context", "max_output",
                                "tools", "vision", "effort", "input_price",
                                "output_price", "source", NULL };
  for (int i = 0; cols[i]; i++) {
    char param[24];
    snprintf(param, sizeof(param), ":%s", cols[i]);
    bind_field(L, st, 2, cols[i], param);
  }
  sqlite3_bind_int64(st, sqlite3_bind_parameter_index(st, ":updated"),
                     (sqlite3_int64)time(NULL));
  int rc = sqlite3_step(st);
  sqlite3_finalize(st);
  if (rc != SQLITE_DONE) return rfail(L, r->h, "model_put step");
  lua_pushboolean(L, 1);
  return 1;
}

/* r:provider_put{ name=, url=, wire=, auth=, key_slot=, ... } -> true */
static int sq_provider_put(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  const char *sql =
    "INSERT INTO providers(name,label,url,wire,auth,key_slot,env,headers,"
    "catalog_url,source,updated) "
    "VALUES(:name,:label,:url,:wire,:auth,:key_slot,:env,:headers,"
    ":catalog_url,:source,:updated) "
    "ON CONFLICT(name) DO UPDATE SET label=excluded.label, url=excluded.url, "
    "wire=excluded.wire, auth=excluded.auth, key_slot=excluded.key_slot, "
    "env=excluded.env, headers=excluded.headers, catalog_url=excluded.catalog_url, "
    "source=excluded.source, updated=excluded.updated";
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(r->h, sql, -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "provider_put prepare");
  static const char *cols[] = { "name", "label", "url", "wire", "auth", "key_slot",
                                "env", "headers", "catalog_url", "source", NULL };
  for (int i = 0; cols[i]; i++) {
    char param[24];
    snprintf(param, sizeof(param), ":%s", cols[i]);
    bind_field(L, st, 2, cols[i], param);
  }
  sqlite3_bind_int64(st, sqlite3_bind_parameter_index(st, ":updated"),
                     (sqlite3_int64)time(NULL));
  int rc = sqlite3_step(st);
  sqlite3_finalize(st);
  if (rc != SQLITE_DONE) return rfail(L, r->h, "provider_put step");
  lua_pushboolean(L, 1);
  return 1;
}

/* r:role_get(name) -> spec | nil     r:role_put(name, spec) -> true */
static int sq_role_get(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  size_t nlen;
  const char *name = luaL_checklstring(L, 2, &nlen);
  sqlite3_stmt *st = NULL;
  if (sqlite3_prepare_v2(r->h, "SELECT spec FROM roles WHERE name=?", -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "role_get prepare");
  sqlite3_bind_text(st, 1, name, (int)nlen, SQLITE_TRANSIENT);
  int rc = sqlite3_step(st);
  if (rc == SQLITE_ROW) {
    const char *v = (const char *)sqlite3_column_blob(st, 0);
    int vlen = sqlite3_column_bytes(st, 0);
    lua_pushlstring(L, v ? v : "", (size_t)vlen);
  } else if (rc == SQLITE_DONE) {
    lua_pushnil(L);
  } else { sqlite3_finalize(st); return rfail(L, r->h, "role_get step"); }
  sqlite3_finalize(st);
  return 1;
}

static int sq_role_put(lua_State *L) {
  RepoSqlite *r = check_sqlite(L);
  size_t nlen, slen;
  const char *name = luaL_checklstring(L, 2, &nlen);
  const char *spec = luaL_checklstring(L, 3, &slen);
  sqlite3_stmt *st = NULL;
  const char *sql =
    "INSERT INTO roles(name,spec,updated) VALUES(?,?,?) "
    "ON CONFLICT(name) DO UPDATE SET spec=excluded.spec, updated=excluded.updated";
  if (sqlite3_prepare_v2(r->h, sql, -1, &st, NULL) != SQLITE_OK)
    return rfail(L, r->h, "role_put prepare");
  sqlite3_bind_text(st, 1, name, (int)nlen, SQLITE_TRANSIENT);
  sqlite3_bind_text(st, 2, spec, (int)slen, SQLITE_TRANSIENT);
  sqlite3_bind_int64(st, 3, (sqlite3_int64)time(NULL));
  int rc = sqlite3_step(st);
  sqlite3_finalize(st);
  if (rc != SQLITE_DONE) return rfail(L, r->h, "role_put step");
  lua_pushboolean(L, 1);
  return 1;
}

static const luaL_Reg sqlite_methods[] = {
  {"kv_get", sq_kv_get},
  {"kv_set", sq_kv_set},
  {"kv_del", sq_kv_del},
  {"kv_list", sq_kv_list},
  {"model_get", sq_model_get},
  {"model_put", sq_model_put},
  {"models_where", sq_models_where},
  {"provider_get", sq_provider_get},
  {"provider_put", sq_provider_put},
  {"catalog_list", sq_catalog_list},
  {"role_get", sq_role_get},
  {"role_put", sq_role_put},
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
