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
#include "ldb.h"      /* boggart_db_handle: the providers table is the slot registry */

#define AUTH_MAX 4096

/* The three settings. Only api_key is secret; the other two are configuration
 * and are readable from Lua so the endpoint and model can be resolved there. */
static char g_base_url[AUTH_MAX];
static char g_model[AUTH_MAX];
/* Wire protocol for the endpoint: "" / "anthropic" (the default -- POST
 * /v1/messages) or "openai" (POST /v1/chat/completions). Lets boggart talk to a
 * local OpenAI-compatible server (llama.cpp, vLLM, LM Studio) directly, since a
 * base URL alone can't say which shape a self-hosted server speaks. */
static char g_wire[AUTH_MAX];

/* Credentials, one per provider.
 *
 * One key was enough while there was one endpoint. There is more than one now
 * -- DeepSeek publishes an Anthropic-compatible endpoint, so boggart reaches
 * it with no new client but a different credential -- and a single slot meant
 * configuring the second provider destroyed the first one's key.
 *
 * Deliberately a table keyed by name rather than a field per vendor: adding a
 * provider should be a base URL and a name, which is data, not an edit to this
 * file. The provider is DERIVED FROM THE ENDPOINT rather than stored, because
 * a stored provider can disagree with the URL the request is actually going
 * to, and that disagreement is invisible at exactly the moment it matters. */
/* One slot per provider. Eight was enough for "Anthropic, DeepSeek, a local
 * server"; a catalog that knows about a dozen vendors is not unusual, and
 * running out silently would mean a key quietly failing to store. */
#define AUTH_MAX_PROVIDERS 24
#define AUTH_NAME_MAX 32
static struct { char name[AUTH_NAME_MAX]; char value[AUTH_MAX]; }
  g_keys[AUTH_MAX_PROVIDERS];

/* The provider a URL belongs to: the registrable part of the host, lowercased.
 * api.deepseek.com -> "deepseek", api.anthropic.com -> "anthropic",
 * 127.0.0.1:8000 -> "local". No vendor is named here; a new one costs nothing.
 */
static void provider_of(const char *base, char *out, size_t n) {
  snprintf(out, n, "%s", "anthropic");
  if (!base || !*base) return;                 /* the built-in default */

  const char *h = strstr(base, "://");
  h = h ? h + 3 : base;
  size_t len = strcspn(h, ":/");               /* host, without port or path */
  if (len == 0) return;

  char host[256];
  if (len >= sizeof(host)) len = sizeof(host) - 1;
  memcpy(host, h, len);
  host[len] = '\0';
  for (char *p = host; *p; p++) {
    if (*p >= 'A' && *p <= 'Z') *p = (char) (*p - 'A' + 'a');
  }

  /* An address rather than a name is somebody's own server. */
  if (strcmp(host, "localhost") == 0 || (host[0] >= '0' && host[0] <= '9')
      || strchr(host, ':')) {
    snprintf(out, n, "%s", "local");
    return;
  }

  /* Second-to-last label: api.deepseek.com and deepseek.com agree. */
  const char *last = NULL, *prev = NULL;
  for (char *p = host; ; ) {
    char *dot = strchr(p, '.');
    prev = last; last = p;
    if (!dot) break;
    *dot = '\0';
    p = dot + 1;
  }
  const char *label = prev ? prev : last;
  if (label && *label) snprintf(out, n, "%s", label);
}

static char *key_slot(const char *provider, int create) {
  for (int i = 0; i < AUTH_MAX_PROVIDERS; i++) {
    if (strcmp(g_keys[i].name, provider) == 0) return g_keys[i].value;
  }
  if (!create) return NULL;
  for (int i = 0; i < AUTH_MAX_PROVIDERS; i++) {
    if (g_keys[i].name[0] == '\0') {
      snprintf(g_keys[i].name, AUTH_NAME_MAX, "%s", provider);
      return g_keys[i].value;
    }
  }
  return NULL;
}

/* The provider currently configured, environment included. */
const char *boggart_auth_provider(void) {
  static char p[AUTH_NAME_MAX];
  const char *base = getenv("ANTHROPIC_BASE_URL");
  if (!base || !*base) base = g_base_url;
  provider_of(base, p, sizeof(p));
  return p;
}
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
  if (strcmp(k, "api_key") == 0) {
    char *slot = key_slot(boggart_auth_provider(), 1);
    if (slot) snprintf(slot, AUTH_MAX, "%s", v);
  } else if (strncmp(k, "key.", 4) == 0 && k[4]) {
    char *slot = key_slot(k + 4, 1);
    if (slot) snprintf(slot, AUTH_MAX, "%s", v);
  }
  else if (strcmp(k, "base_url") == 0) snprintf(g_base_url, AUTH_MAX, "%s", v);
  else if (strcmp(k, "model") == 0) snprintf(g_model, AUTH_MAX, "%s", v);
  else if (strcmp(k, "wire") == 0) snprintf(g_wire, AUTH_MAX, "%s", v);
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
  for (int i = 0; i < AUTH_MAX_PROVIDERS; i++) {
    if (g_keys[i].name[0] && g_keys[i].value[0]) {
      fprintf(f, "key.%s=%s\n", g_keys[i].name, g_keys[i].value);
    }
  }
  if (g_base_url[0]) fprintf(f, "base_url=%s\n", g_base_url);
  if (g_model[0])    fprintf(f, "model=%s\n", g_model);
  if (g_wire[0])     fprintf(f, "wire=%s\n", g_wire);
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
/* <PROVIDER>_API_KEY, e.g. ANTHROPIC_API_KEY or DEEPSEEK_API_KEY.
 *
 * Scoped to the provider it names, which it was not before: the Anthropic
 * variable used to override the key for EVERY request, so exporting it and
 * pointing the endpoint at another vendor sent an Anthropic credential to that
 * vendor -- by configuration alone, with nothing on screen to say so. A
 * variable named for one company is a statement about that company. */
static const char *env_key_for(const char *provider) {
  char var[AUTH_NAME_MAX + 16];
  snprintf(var, sizeof(var), "%s_API_KEY", provider);
  for (char *p = var; *p; p++) {
    if (*p >= 'a' && *p <= 'z') *p = (char) (*p - 'a' + 'A');
  }
  const char *v = getenv(var);
  return (v && *v) ? v : NULL;
}

/* ---- the credential-slot registry ----------------------------------------
 *
 * A request names a destination (url) and, when it is routed, the credential
 * SLOT to use. Those two must agree, and the agreement cannot be decided by the
 * caller: the Lua that assembles a request is rewritable, so "use the anthropic
 * key, and by the way send it to evil.example.com" has to be refusable
 * somewhere the caller cannot reach.
 *
 * That somewhere is the `providers` table -- the same rows lua/catalog.lua
 * imports and the user can inspect. A (host, slot) pair is honoured only if
 * some provider row registers that slot for that host. Otherwise the request
 * goes out with NO credential rather than the wrong one.
 *
 * The honest limit, because overclaiming here would be worse than not doing it:
 * this stops a routing MISTAKE and a single confused request from taking a key
 * somewhere it does not belong, and it makes the mapping auditable -- a durable
 * row you can read rather than an argument on one call. It is not a defence
 * against an agent determined to INSERT a provider row first; that path is
 * gated by tool permissions (lua/perm.lua), which is where a write to the store
 * should be gated. Defence in depth, not a wall.
 */
static sqlite3 *g_store;   /* borrowed from the Lua store; never closed here */

/* The host part of a URL, lowercased, without scheme, port or path. */
static void host_of(const char *url, char *out, size_t n) {
  out[0] = '\0';
  if (!url || !*url) return;
  const char *h = strstr(url, "://");
  h = h ? h + 3 : url;
  size_t len = strcspn(h, ":/");
  if (len == 0) return;
  if (len >= n) len = n - 1;
  memcpy(out, h, len);
  out[len] = '\0';
  for (char *p = out; *p; p++) {
    if (*p >= 'A' && *p <= 'Z') *p = (char) (*p - 'A' + 'a');
  }
}

/* Is `slot` registered for `host` by some provider row? With no store bound
 * (early startup, a test with no DB) the answer is "yes" -- the registry is an
 * additional check, and its absence must not break a configuration that worked
 * before the catalog existed. */
static int slot_registered_for_host(const char *slot, const char *host) {
  if (!g_store || !slot || !*slot || !host || !*host) return 1;
  sqlite3_stmt *st = NULL;
  const char *sql = "SELECT url FROM providers WHERE key_slot = ?";
  if (sqlite3_prepare_v2(g_store, sql, -1, &st, NULL) != SQLITE_OK) return 1;
  sqlite3_bind_text(st, 1, slot, -1, SQLITE_TRANSIENT);
  int found = 0, any = 0;
  while (sqlite3_step(st) == SQLITE_ROW) {
    const char *u = (const char *)sqlite3_column_text(st, 0);
    any = 1;
    char h[256];
    host_of(u, h, sizeof(h));
    if (h[0] && strcmp(h, host) == 0) { found = 1; break; }
  }
  sqlite3_finalize(st);
  /* A slot nothing registers is not yet catalogued -- treat it as the caller's
   * own arrangement rather than refusing a setup the catalog has no opinion on.
   * A slot that IS registered, for other hosts only, is a genuine mismatch. */
  return any ? found : 1;
}

/* auth.slot_allowed(url, slot) -> bool
 *
 * The registry check on its own, with no credential involved: may this slot's
 * key be sent to this host? Exposed because a security property nothing can
 * observe is a security property nothing can test -- and because `doctor` and
 * the model picker want to say "that endpoint is not registered for that key"
 * before a request fails. It reveals nothing: the answer is a yes/no about
 * configuration, and the key is not read to produce it. */
static int l_slot_allowed(lua_State *L) {
  const char *url = luaL_optstring(L, 1, NULL);
  const char *slot = luaL_optstring(L, 2, NULL);
  char host[256];
  host_of(url, host, sizeof(host));
  lua_pushboolean(L, slot_registered_for_host(slot, host));
  return 1;
}

/* auth.bind_store(db) -- hand C the store so the registry can be consulted.
 * Called once from lua/store.lua on open. */
static int l_bind_store(lua_State *L) {
  g_store = lua_isnoneornil(L, 1) ? NULL : boggart_db_handle(L, 1);
  lua_pushboolean(L, 1);
  return 1;
}

/* The credential for the endpoint a request is ACTUALLY going to.
 *
 * The single-endpoint version of this derived the provider from the globally
 * configured base URL, which is fine while there is one endpoint and wrong the
 * moment there is more than one: a fleet with a local model on one port and a
 * cloud model on another would have sent one provider's key to the other's
 * host. This file already warned about exactly that -- "a stored provider can
 * disagree with the URL the request is actually going to, and that disagreement
 * is invisible at exactly the moment it matters" -- so routing per request is
 * the correctness fix and the per-agent-model feature at once.
 *
 * `url` and `wire` are the request's own; either may be NULL, in which case the
 * globally configured value stands in. The key itself never crosses into Lua:
 * Lua names a destination, C picks the credential for it. */
const char *boggart_auth_header_for(const char *url, const char *wire,
                                    const char *slot, const char *style) {
  auth_load();
  char pbuf[AUTH_NAME_MAX];
  const char *provider;
  if (slot && *slot) {
    /* A routed request names its slot. Honour it only if the registry agrees
     * this slot belongs with this host; otherwise send nothing. */
    char host[256];
    host_of(url, host, sizeof(host));
    if (!slot_registered_for_host(slot, host)) return NULL;
    provider = slot;
  } else if (url && *url) {
    provider_of(url, pbuf, sizeof(pbuf));
    provider = pbuf;
  } else {
    provider = boggart_auth_provider();
  }
  const char *env = env_key_for(provider);
  const char *stored = key_slot(provider, 0);
  const char *key = env ? env : ((stored && stored[0]) ? stored : NULL);
  if (!key) return NULL;
  static char hdr[AUTH_MAX + 32];
  /* OpenAI-shaped wires (chat-completions and the Responses API) authenticate
   * with a Bearer token; Anthropic uses x-api-key. A wire named by the request
   * wins; otherwise the env override, then the stored value -- matching
   * auth.wire()'s precedence. */
  /* An explicit style wins. It has to be separate from the wire because the
   * two genuinely come apart: Z.ai speaks the Anthropic wire and authenticates
   * with a Bearer token, which no wire-derived rule can express. */
  if (style && *style) {
    if (strcmp(style, "bearer") == 0) {
      snprintf(hdr, sizeof(hdr), "authorization: Bearer %s", key);
    } else {
      snprintf(hdr, sizeof(hdr), "x-api-key: %s", key);
    }
    return hdr;
  }
  if (!wire || !*wire) wire = getenv("ANTHROPIC_WIRE");
  if (!wire || !*wire) wire = g_wire;
  if (wire && (strcmp(wire, "openai") == 0 || strcmp(wire, "responses") == 0)) {
    snprintf(hdr, sizeof(hdr), "authorization: Bearer %s", key);
  } else {
    snprintf(hdr, sizeof(hdr), "x-api-key: %s", key);
  }
  return hdr;
}

/* The configured endpoint's credential -- the old behaviour, unchanged, for
 * every caller that is not routing a specific request. */
const char *boggart_auth_header(void) {
  return boggart_auth_header_for(NULL, NULL, NULL, NULL);
}

/* ---- Lua surface ---------------------------------------------------------- */

/* auth.set(kind, value) -> true | nil, err */
static int l_set(lua_State *L) {
  const char *k = luaL_checkstring(L, 1);
  const char *v = luaL_checkstring(L, 2);
  if (strcmp(k, "api_key") != 0 && strcmp(k, "base_url") != 0 && strcmp(k, "model") != 0
      && strcmp(k, "wire") != 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "unknown setting: %s", k);
    return 2;
  }
  auth_load();
  /* auth.set("api_key", v, provider): store a key for a provider you are not
   * currently pointed at, which a catalog of a dozen vendors makes routine.
   * Without the third argument this is exactly as it was: the current one. */
  const char *slot = luaL_optstring(L, 3, NULL);
  if (slot && *slot && strcmp(k, "api_key") == 0) {
    char *dst = key_slot(slot, 1);
    if (!dst) {
      lua_pushnil(L);
      lua_pushliteral(L, "no free credential slot");
      return 2;
    }
    snprintf(dst, AUTH_MAX, "%s", v);
  } else {
    set_field(k, v);
  }
  auth_save();
  lua_pushboolean(L, 1);
  return 1;
}

/* auth.clear(kind?) -> true. No argument clears everything. */
static int l_clear(lua_State *L) {
  const char *k = luaL_optstring(L, 1, NULL);
  auth_load();
  if (!k) {
    /* Everything, every provider. */
    for (int i = 0; i < AUTH_MAX_PROVIDERS; i++) {
      g_keys[i].name[0] = g_keys[i].value[0] = '\0';
    }
    g_base_url[0] = g_model[0] = g_wire[0] = '\0';
  }
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
  /* auth.has_key([provider]).
   *
   * For the provider the endpoint points at, not "any key anywhere": having an
   * Anthropic key configured says nothing about whether a request to DeepSeek
   * will be authenticated. The optional argument -- the same one l_masked has
   * always taken -- asks about a specific one instead, which is what a catalog
   * of a dozen providers needs in order to say which are actually usable.
   * Without it this silently answered for the CURRENT provider whatever was
   * asked, so "is the xai key set?" was really "is the anthropic key set?". */
  const char *provider = luaL_optstring(L, 1, boggart_auth_provider());
  const char *stored = key_slot(provider, 0);
  lua_pushboolean(L, env_key_for(provider) != NULL || (stored && stored[0]));
  return 1;
}

/* auth.masked() -> string. For display only; never the value. */
static int l_masked(lua_State *L) {
  auth_load();
  /* auth.masked([provider]) -> mask, source, provider. Defaults to the
   * provider in force, so a settings screen showing "the key" shows the one
   * that would actually be sent. */
  const char *provider = luaL_optstring(L, 1, boggart_auth_provider());
  const char *env = env_key_for(provider);
  const char *stored = key_slot(provider, 0);
  const char *key = env ? env : (stored ? stored : "");
  size_t n = strlen(key);
  if (n == 0) {
    lua_pushstring(L, "(unset)");
    lua_pushnil(L);
    lua_pushstring(L, provider);
    return 3;
  }
  char out[64];
  if (n <= 12) snprintf(out, sizeof(out), "************");
  else snprintf(out, sizeof(out), "%.6s******%s", key, key + n - 4);
  lua_pushstring(L, out);
  /* Name the variable, not just "environment": knowing WHICH one is winning is
   * the whole value of the answer when it is the wrong one. */
  if (env) {
    char var[AUTH_NAME_MAX + 16];
    snprintf(var, sizeof(var), "%s_API_KEY", provider);
    for (char *p = var; *p; p++) {
      if (*p >= 'a' && *p <= 'z') *p = (char) (*p - 'a' + 'A');
    }
    lua_pushstring(L, var);
  } else {
    lua_pushstring(L, "stored");
  }
  lua_pushstring(L, provider);
  return 3;
}

/* auth.provider() -> the provider name the current endpoint resolves to. */
static int l_provider(lua_State *L) {
  auth_load();
  lua_pushstring(L, boggart_auth_provider());
  return 1;
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

/* auth.wire() -> "openai" | "anthropic" | nil. The wire protocol the endpoint
 * speaks; ANTHROPIC_WIRE overrides the stored value for a one-off. */
static int l_wire(lua_State *L) {
  auth_load();
  const char *env = getenv("ANTHROPIC_WIRE");
  if (env && *env) lua_pushstring(L, env);
  else if (g_wire[0]) lua_pushstring(L, g_wire);
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
  {"wire", l_wire},
  {"path", l_path},
  {"bind_store", l_bind_store},
  {"slot_allowed", l_slot_allowed},
  {"provider", l_provider},
  {NULL, NULL},
};

int luaopen_boggart_auth(lua_State *L) {
  luaL_newlib(L, auth_lib);
  return 1;
}
