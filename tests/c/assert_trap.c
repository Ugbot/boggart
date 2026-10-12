/* assert_trap.c -- bogassert.h traps at the call site (BOG-8).
 * Each case runs in a forked child that breaks one invariant on purpose; the
 * parent checks the child died by a trap signal (not a segfault, not a clean
 * exit) and that its stderr names the condition, the file and the line. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "bogassert.h"

static int failures = 0;

static void expect_trap(const char *name, void (*fn)(void), const char *needle) {
  int fds[2];
  if (pipe(fds) != 0) { perror("pipe"); failures++; return; }
  fflush(stdout);   /* or the child re-prints our buffered output when the assert flushes */
  pid_t pid = fork();
  if (pid == 0) {
    dup2(fds[1], 2);
    close(fds[0]);
    fn();
    _exit(0);   /* reaching here means the assert did NOT fire */
  }
  close(fds[1]);
  char buf[4096]; size_t n = 0; ssize_t r;
  while ((r = read(fds[0], buf + n, sizeof(buf) - 1 - n)) > 0) n += (size_t)r;
  buf[n] = '\0';
  close(fds[0]);
  int st = 0;
  waitpid(pid, &st, 0);
  int trapped = WIFSIGNALED(st) && (WTERMSIG(st) == SIGTRAP || WTERMSIG(st) == SIGILL);
  int named = strstr(buf, needle) != NULL && strstr(buf, "assert_trap.c:") != NULL;
  printf("%-28s %s%s\n", name, trapped ? "trapped" : "DID NOT TRAP",
         named ? "" : "  (message missing the condition or file:line)");
  if (!trapped || !named) { failures++; fprintf(stdout, "  stderr was: %s\n", buf); }
}

static void case_assert(void) { int handle = 0; BOG_ASSERT(handle != 0, "handle %d", handle); }
static void case_bounds(void) { BOG_ASSERT_BOUNDS(7, 3); }
static void case_stack(void) {
  lua_State *L = luaL_newstate();
  BOG_STACK_GUARD(L);
  lua_pushnil(L);            /* a block that was meant to leave the stack alone */
  BOG_STACK_EXPECT(L, 0);
}
static void case_udata(void) {
  lua_State *L = luaL_newstate();
  luaL_newmetatable(L, "bog.handle");
  lua_pop(L, 1);
  lua_pushinteger(L, 5);
  BOG_CHECK_UDATA(L, 1, "bog.handle");
}
static void case_ok(void) {   /* holding invariants must not trap */
  lua_State *L = luaL_newstate();
  BOG_STACK_GUARD(L);
  lua_pushnil(L); lua_pop(L, 1);
  BOG_STACK_EXPECT(L, 0);
  BOG_ASSERT_BOUNDS(2, 3);
  BOG_ASSERT(1, "fine");
  lua_close(L);
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);
  expect_trap("BOG_ASSERT", case_assert, "handle != 0");
  expect_trap("BOG_ASSERT_BOUNDS", case_bounds, "7 not in [0,3)");
  expect_trap("BOG_STACK_EXPECT", case_stack, "stack top is 1, expected 0");
  expect_trap("BOG_CHECK_UDATA", case_udata, "is not a bog.handle");
  case_ok();
  printf("assert_trap: %s\n", failures ? "FAILED" : "all passed");
  return failures ? 1 : 0;
}
