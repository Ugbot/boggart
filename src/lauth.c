/* lauth.c -- credentials, owned by the C side.
 *
 * The rule established elsewhere in this codebase is that capabilities live in
 * C with their policy attached and Lua composes them. A credential is a
 * capability like any other, and it was the one still being handled in Lua: the
 * key was read into a Lua string, concatenated into a header, and kept in the
 * kv table where the `sql` tool could dump it.
 *
 * Here the secret never enters the Lua state at all. Lua can set it, clear it,
 * and ask whether one exists; it cannot read it back. The header is attached
 * inside lhttp.c (see boggart_auth_header) when a request asks for auth, so the
 * value goes straight from this file to libcurl.
 *
 * What this does and does not buy, stated plainly:
 *
 *   It removes the routine exposure -- the key is not a Lua global, not in a
 *   table the model can SELECT, and completely unreachable from the sandboxed
 *   environment a generated tool runs in. That is the leak that actually
 *   happens: a model dumping kv contents into its context, and thence into a
 *   log or a transcript.
 *
 *   It is NOT a defence against a determined agent. boggart gives the model
 *   bash and an unrestricted read tool, so it can read ~/.boggart/auth
 *   directly, and it can edit the harness. Anyone claiming otherwise would be
 *   selling you a sandbox that is not there. The point is to stop accidents,
 *   not to contain an adversary who already has a shell.
 *
 * Storage is a plain file, not the SQLite store: the store is what the `sql`
 * tool reads, and keeping the secret out of it is most of the exercise. The
 * file is created 0600 inside a 0700 directory.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "uv.h"
#include "lua.h"
#include "lauxlib.h"
#include "bogpaths.h"

#define AUTH_MAX 4096

/* The three settings. Only api_key is secret; the other two are configuration
 * and are readable from Lua so the endpoint and model can be resolved there. */
static char g_api_key[AUTH_MAX];
static char g_base_url[AUTH_MAX];
static char g_model[AUTH_MAX];
static char g_path[4096];
static int g_loaded = 0;

/* The credential file sits in boggart's data directory, wherever the shared
 * policy in bogpaths.h puts it -- so BOGGART_HOME moves the key along with the
 * store instead of leaving it behind in the old location. With no home
 * directory at all there is nowhere to put it; "." keeps the old behaviour of
 * failing quietly at fopen() rather than crashing, and boot.lua refuses to
 * start in that case long before this matters. */
static void auth_path(void) {
  if (g_path[0]) return;
  char dir[4096];
  if (boggart_data_dir(dir, sizeof(dir), NULL) != 0) snprintf(dir, sizeof(dir), ".");
  snprintf(g_path, sizeof(g_path), "%s/auth", dir);
}

static void set_field(const char *k, const char *v) {
  if (strcmp(k, "api_key") == 0) snprintf(g_api_key, AUTH_MAX, "%s", v);
  else if (strcmp(k, "base_url") == 0) snprintf(g_base_url, AUTH_MAX, "%s", v);
  else if (strcmp(k, "model") == 0) snprintf(g_model, AUTH_MAX, "%s", v);
}

static void auth_load(void) {
  if (g_loaded) return;
  g_loaded = 1;
  auth_path();
  FILE *f = fopen(g_path, "rb");
  if (!f) return;
  char line[AUTH_MAX * 2];
  while (fgets(line, sizeof(line), f)) {
    char *nl = strpbrk(line, "\r\n");
    if (nl) *nl = '\0';
    char *eq = strchr(line, '=');
    if (!eq) continue;
    *eq = '\0';
    set_field(line, eq + 1);
  }
  fclose(f);
}

static void auth_save(void) {
  auth_path();
  /* Create the directory first; 0700 so the file below is not merely 0600 in a
   * directory anyone can list. */
  char dir[4096];
  snprintf(dir, sizeof(dir), "%s", g_path);
  char *slash = strrchr(dir, '/');
  if (slash) {
    *slash = '\0';
    /* mkdir -p, not a single mkdir: ~/.local/share/boggart has two components
     * that may both be missing on a new account. */
    boggart_mkdir_p(dir);
  }
  FILE *f = fopen(g_path, "wb");
  if (!f) return;
  if (g_api_key[0])  fprintf(f, "api_key=%s\n", g_api_key);
  if (g_base_url[0]) fprintf(f, "base_url=%s\n", g_base_url);
  if (g_model[0])    fprintf(f, "model=%s\n", g_model);
  fclose(f);
  /* Owner-only, always -- the write above may have created it with the
   * process umask, which is commonly 0644. */
  uv_fs_t req;
  uv_fs_chmod(NULL, &req, g_path, 0600, NULL);
  uv_fs_req_cleanup(&req);
}

/* ---- used by lhttp.c ------------------------------------------------------ */

/* Returns the credential header line for an outgoing request, or NULL when
 * there is no key. The buffer is static and overwritten on each call; libcurl
 * copies header strings, so that is safe here and keeps the value from being
 * duplicated around the heap. */
const char *boggart_auth_header(void) {
  auth_load();
  const char *env = getenv("ANTHROPIC_API_KEY");
  const char *key = (env && *env) ? env : (g_api_key[0] ? g_api_key : NULL);
  if (!key) return NULL;
  static char hdr[AUTH_MAX + 32];
  snprintf(hdr, sizeof(hdr), "x-api-key: %s", key);
  return hdr;
}

/* ---- Lua surface ---------------------------------------------------------- */

/* auth.set(kind, value) -> true | nil, err */
static int l_set(lua_State *L) {
  const char *k = luaL_checkstring(L, 1);
  const char *v = luaL_checkstring(L, 2);
  if (strcmp(k, "api_key") != 0 && strcmp(k, "base_url") != 0 && strcmp(k, "model") != 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "unknown setting: %s", k);
    return 2;
  }
  auth_load();
  set_field(k, v);
  auth_save();
  lua_pushboolean(L, 1);
  return 1;
}

/* auth.clear(kind?) -> true. No argument clears everything. */
static int l_clear(lua_State *L) {
  const char *k = luaL_optstring(L, 1, NULL);
  auth_load();
  if (!k) { g_api_key[0] = g_base_url[0] = g_model[0] = '\0'; }
  else set_field(k, "");
  auth_save();
  lua_pushboolean(L, 1);
  return 1;
}

/* auth.has_key() -> bool. Whether a key exists, from either source. Lua needs
 * this to decide between "use the key" and "fall back to the CLI"; it does not
 * need the key itself. */
static int l_has_key(lua_State *L) {
  auth_load();
  const char *env = getenv("ANTHROPIC_API_KEY");
  lua_pushboolean(L, (env && *env) || g_api_key[0]);
  return 1;
}

/* auth.masked() -> string. For display only; never the value. */
static int l_masked(lua_State *L) {
  auth_load();
  const char *env = getenv("ANTHROPIC_API_KEY");
  const char *key = (env && *env) ? env : g_api_key;
  size_t n = strlen(key);
  if (n == 0) { lua_pushstring(L, "(unset)"); return 1; }
  char out[64];
  if (n <= 12) snprintf(out, sizeof(out), "************");
  else snprintf(out, sizeof(out), "%.6s******%s", key, key + n - 4);
  lua_pushstring(L, out);
  if (env && *env) { lua_pushstring(L, "environment"); return 2; }
  lua_pushstring(L, "stored");
  return 2;
}

/* base_url and model are configuration, not secrets: readable. Environment
 * wins over the stored value, so a one-off override needs no undo. */
static int l_base_url(lua_State *L) {
  auth_load();
  const char *env = getenv("ANTHROPIC_BASE_URL");
  if (env && *env) lua_pushstring(L, env);
  else if (g_base_url[0]) lua_pushstring(L, g_base_url);
  else lua_pushnil(L);
  return 1;
}

static int l_model(lua_State *L) {
  auth_load();
  if (g_model[0]) lua_pushstring(L, g_model);
  else lua_pushnil(L);
  return 1;
}

static int l_path(lua_State *L) {
  auth_path();
  lua_pushstring(L, g_path);
  return 1;
}

static const luaL_Reg auth_lib[] = {
  {"set", l_set},
  {"clear", l_clear},
  {"has_key", l_has_key},
  {"masked", l_masked},
  {"base_url", l_base_url},
  {"model", l_model},
  {"path", l_path},
  {NULL, NULL},
};

int luaopen_boggart_auth(lua_State *L) {
  luaL_newlib(L, auth_lib);
  return 1;
}
