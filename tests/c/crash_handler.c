/* crash_handler.c -- src/bogcrash.c reports a crash (BOG-9).
 * A forked child installs the handler, registers its Lua state and a fatal
 * hook, then runs Lua: outer() -> deep() -> crash(), a C function that writes
 * to address 8. The parent checks the child still died of SIGSEGV (the default
 * action is preserved) and that the report names the signal, says near-NULL,
 * has C frames and the Lua frames with file:line, and that the hook ran. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <dirent.h>
#include <sys/wait.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "bogcrash.h"

int boggart_data_dir(char *out, size_t n, const char **source) { (void)source; snprintf(out, n, "/nonexistent"); return 1; }
int boggart_mkdir_p(const char *path) { char cmd[1200]; snprintf(cmd, sizeof(cmd), "mkdir -p '%s'", path); return system(cmd); }

static int crash(lua_State *L) { (void)L; volatile int *p = (volatile int *)8; *p = 1; return 0; }
static void hook(void) { const char m[] = "HOOK-RAN\n"; write(2, m, sizeof(m) - 1); }

int main(void) {
  char dir[512];
  snprintf(dir, sizeof(dir), "%s/bogcrash-test-%d", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
  int fds[2]; pipe(fds);
  fflush(stdout);
  pid_t pid = fork();
  if (pid == 0) {
    dup2(fds[1], 2); close(fds[0]);
    bog_crash_install();
    bog_crash_set_dir(dir);
    bog_crash_on_fatal(hook);
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    bog_crash_set_lua(L);
    lua_register(L, "crash", crash);
    const char *src = "local function deep() crash() end\nlocal function outer() deep() end\nouter()\n";
    if (luaL_loadbuffer(L, src, strlen(src), "=crashtest.lua") == LUA_OK) lua_call(L, 0, 0);
    _exit(0);   /* not reached */
  }
  close(fds[1]);
  char err[16384]; size_t n = 0; ssize_t r;
  while ((r = read(fds[0], err + n, sizeof(err) - 1 - n)) > 0) n += (size_t)r;
  err[n] = '\0';
  int st = 0;
  waitpid(pid, &st, 0);
  int fails = 0;
#define CHECK(c, what) do { if (c) printf("ok   %s\n", what); else { printf("FAIL %s\n", what); fails++; } } while (0)
  CHECK(WIFSIGNALED(st) && WTERMSIG(st) == SIGSEGV, "the child still died of SIGSEGV (default action preserved)");
  CHECK(strstr(err, "boggart crashed: SIGSEGV") != NULL, "stderr names the signal");
  CHECK(strstr(err, "near NULL") != NULL, "a near-NULL access is classified");
  CHECK(strstr(err, "C stack:") != NULL, "C frames are printed");
  CHECK(strstr(err, "crashtest.lua:1") != NULL && strstr(err, "crashtest.lua:2") != NULL, "Lua frames with file:line");
  CHECK(strstr(err, "HOOK-RAN") != NULL, "the fatal hook ran (the TUI's tty restore goes here)");
  /* the report file */
  DIR *d = opendir(dir);
  char rpt[16384] = "";
  if (d) {
    struct dirent *e;
    while ((e = readdir(d))) {
      if (strncmp(e->d_name, "crash-", 6) == 0) {
        char p[1200]; snprintf(p, sizeof(p), "%s/%s", dir, e->d_name);
        FILE *f = fopen(p, "r");
        if (f) { size_t m = fread(rpt, 1, sizeof(rpt) - 1, f); rpt[m] = '\0'; fclose(f); }
      }
    }
    closedir(d);
  }
  CHECK(strstr(rpt, "SIGSEGV") && strstr(rpt, "crashtest.lua:1") && strstr(rpt, "C stack:"), "the report file has it all");
  if (fails) printf("--- child stderr ---\n%s\n", err);
  printf("crash_handler: %s\n", fails ? "FAILED" : "all passed");
  return fails ? 1 : 0;
}
