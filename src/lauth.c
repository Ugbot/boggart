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
#define AUTH_MAX_PROVIDERS 8
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
const char *boggart_auth_header_for(const char *url, const char *wire) {
  auth_load();
  char pbuf[AUTH_NAME_MAX];
  const char *provider;
  if (url && *url) {
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
  return boggart_auth_header_for(NULL, NULL);
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
  set_field(k, v);
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
  /* For the provider the endpoint points at, not "any key anywhere": having an
   * Anthropic key configured says nothing about whether a request to DeepSeek
   * will be authenticated. */
  const char *provider = boggart_auth_provider();
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
  {"provider", l_provider},
  {NULL, NULL},
};

int luaopen_boggart_auth(lua_State *L) {
  luaL_newlib(L, auth_lib);
  return 1;
}
