/* auth_threads.c -- the credential code under concurrency (BOG-6).
 *
 * Sub-agents make HTTP requests on pool threads, and each asks src/lauth.c for
 * its auth header while the main thread may be reloading the shared file. This
 * hammers boggart_auth_header_for / boggart_auth_provider from 8 threads while
 * the main thread keeps rewriting the file (as another process would), and
 * checks every header is one of the two well-formed values -- never torn,
 * never mixed. Run it under BOGGART_SANITIZER=thread for the race check. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "uv.h"
#include "sqlite3.h"
#include "lua.h"

const char *boggart_auth_header_for(const char *url, const char *wire, const char *slot, const char *style);
const char *boggart_auth_provider(void);

/* lauth.c's l_bind_store references this; the test never binds a store. */
sqlite3 *boggart_db_handle(lua_State *L, int idx) { (void)L; (void)idx; return NULL; }
int boggart_mkdir_p(const char *path) { (void)path; return 0; }
static char g_dir[1024];
int boggart_data_dir(char *out, size_t n, const char **source) {
  if (source) *source = "test";
  snprintf(out, n, "%s", g_dir);
  return 0;
}

static const char *K1 = "sk-ant-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
static const char *K2 = "sk-ant-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
static atomic_int g_stop = 0;   /* volatile is not synchronization; TSan rightly says so */
static int g_bad = 0, g_calls = 0;
static uv_mutex_t g_count;

static void write_auth(const char *key) {
  char path[1100], tmp[1120];
  snprintf(path, sizeof(path), "%s/auth", g_dir);
  snprintf(tmp, sizeof(tmp), "%s/auth.w", g_dir);
  FILE *f = fopen(tmp, "wb");
  fprintf(f, "key.anthropic=%s\n", key);
  fclose(f);
  rename(tmp, path);
}

static void worker(void *arg) {
  (void)arg;
  char want1[256], want2[256];
  snprintf(want1, sizeof(want1), "x-api-key: %s", K1);
  snprintf(want2, sizeof(want2), "x-api-key: %s", K2);
  int bad = 0, n = 0;
  while (!atomic_load(&g_stop)) {
    const char *h = boggart_auth_header_for("https://api.anthropic.com/v1/messages", "anthropic", NULL, NULL);
    char copy[256];
    snprintf(copy, sizeof(copy), "%s", h ? h : "(null)");
    if (strcmp(copy, want1) != 0 && strcmp(copy, want2) != 0) bad++;
    const char *p = boggart_auth_provider();
    if (strcmp(p, "anthropic") != 0) bad++;
    n++;
  }
  uv_mutex_lock(&g_count); g_bad += bad; g_calls += n; uv_mutex_unlock(&g_count);
}

int main(void) {
  snprintf(g_dir, sizeof(g_dir), "%s/auth-threads-%d", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)uv_os_getpid());
  uv_fs_t req;
  uv_fs_mkdir(NULL, &req, g_dir, 0700, NULL);
  uv_fs_req_cleanup(&req);
  uv_mutex_init(&g_count);
  write_auth(K1);
  uv_thread_t t[8];
  for (int i = 0; i < 8; i++) uv_thread_create(&t[i], worker, NULL);
  for (int i = 0; i < 400; i++) { write_auth((i & 1) ? K2 : K1); uv_sleep(1); }
  atomic_store(&g_stop, 1);
  for (int i = 0; i < 8; i++) uv_thread_join(&t[i]);
  printf("auth_threads: %d header lookups across 8 threads, %d bad\n", g_calls, g_bad);
  return (g_bad == 0 && g_calls > 1000) ? 0 : 1;
}
