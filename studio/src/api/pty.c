/* pty.c -- the PTY host for the embedded terminal (docs/studio-panels.md
 * phase 3). Spawns a shell on a pseudo-terminal and exposes non-blocking
 * read/write, resize and close to Lua as the global `pty`. TerminalView
 * (studio/data/core/terminalview.lua) owns the ANSI parsing and the cell
 * grid; this file only moves bytes and reaps the child.
 *
 * forkpty() -- <util.h> on macOS/BSD, <pty.h> on glibc Linux -- does
 * openpty + fork + login_tty in one call. login_tty is the part plain
 * uv_spawn (system.c's f_exec) cannot give us: it setsid()s and TIOCSCTTY's
 * the slave onto the child before dup2'ing it over stdin/stdout/stderr, which
 * is what makes the slave the child's controlling terminal and gives it job
 * control (Ctrl-C, Ctrl-Z). A bare uv_spawn with the slave fd as stdio never
 * calls setsid, so the child would never acquire a controlling tty at all.
 * That is the one reason this does not reuse system.c's uv_spawn path.
 *
 * Because the child is not uv_spawn'd, libuv's own SIGCHLD reaping never
 * sees it, and this file does not install a competing SIGCHLD handler
 * either -- that would race uv_spawn's internal reaping for unrelated
 * children (system.exec) over the same signal. Instead the child is reaped
 * by polling waitpid(pid, WNOHANG) from pty_read/pty_alive, which callers
 * already call once a frame (TerminalView:update()) the same way the studio
 * already polls system.poll_event once a frame -- one more thing drained by
 * the frame loop rather than pushed onto the uv loop.
 *
 * v1: no window title / OSC parsing here, no uv integration -- see
 * terminalview.lua for what v1 of the terminal itself covers and defers.
 */
#ifndef _WIN32

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
  #include <util.h>      /* forkpty, openpty */
#else
  #include <pty.h>       /* forkpty, openpty (glibc) */
#endif

#include "lua.h"
#include "lauxlib.h"

#define PTY_HANDLE "boggart.pty"

typedef struct {
  int master;         /* -1 once closed */
  pid_t pid;          /* forkpty's child pid; 0 once reaped */
  int exited;
  int exit_status;
} pty_handle;

static pty_handle *check_pty(lua_State *L) {
  return (pty_handle *) luaL_checkudata(L, 1, PTY_HANDLE);
}

/* Non-blocking reap: safe to call every frame, including long after the
 * child is gone -- waitpid on an already-reaped pid just fails ECHILD. */
static void reap(pty_handle *h) {
  if (h->exited || h->pid <= 0) { return; }
  int status;
  pid_t r = waitpid(h->pid, &status, WNOHANG);
  if (r == h->pid) {
    h->exited = 1;
    h->exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  }
}

/* pty.open{cmd=, args={...}, cwd=, cols=, rows=} -> handle | nil, err
 * cmd defaults to $SHELL, falling back to /bin/sh; args is the argv tail
 * (argv[0] is always cmd). cwd defaults to the process's own cwd -- studio
 * already system.chdir()s into the project root, so that is normally what a
 * caller wants without asking. */
static int f_open(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);

  lua_getfield(L, 1, "cmd");
  const char *cmd = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
  if (!cmd) { cmd = getenv("SHELL"); }
  if (!cmd) { cmd = "/bin/sh"; }
  lua_pop(L, 1);

  lua_getfield(L, 1, "cwd");
  const char *cwd = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
  lua_pop(L, 1);

  int cols = 80, rows = 24;
  lua_getfield(L, 1, "cols");
  if (lua_isnumber(L, -1)) { cols = (int) lua_tointeger(L, -1); }
  lua_pop(L, 1);
  lua_getfield(L, 1, "rows");
  if (lua_isnumber(L, -1)) { rows = (int) lua_tointeger(L, -1); }
  lua_pop(L, 1);
  if (cols < 1) { cols = 1; }
  if (rows < 1) { rows = 1; }

  /* argv[0] = cmd, then the "args" array, NULL-terminated. Bounded rather
   * than dynamic -- a terminal shell command line is never close to 62
   * tokens, and this keeps the open() path free of another allocation. */
  char *argv[64];
  int argc = 0;
  argv[argc++] = (char *) cmd;
  lua_getfield(L, 1, "args");
  if (lua_istable(L, -1)) {
    lua_Integer n = luaL_len(L, -1);
    for (lua_Integer i = 1; i <= n && argc < 63; i++) {
      lua_rawgeti(L, -1, i);
      argv[argc++] = (char *) lua_tostring(L, -1);
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);
  argv[argc] = NULL;

  struct winsize ws;
  memset(&ws, 0, sizeof ws);
  ws.ws_col = (unsigned short) cols;
  ws.ws_row = (unsigned short) rows;

  int master;
  pid_t pid = forkpty(&master, NULL, NULL, &ws);
  if (pid < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }

  if (pid == 0) {
    /* Child: login_tty (inside forkpty) already made the slave our
     * controlling terminal and dup2'd it onto fd 0/1/2. */
    if (cwd && chdir(cwd) != 0) { _exit(127); }
    setenv("TERM", "xterm-256color", 1);
    execvp(cmd, argv);
    _exit(127);   /* execvp only returns on failure */
  }

  /* Parent: non-blocking master, matching the poll-every-frame read model
   * pty_read is built around -- a blocking read here would freeze the whole
   * studio the instant a pane's shell went quiet. */
  int flags = fcntl(master, F_GETFL, 0);
  fcntl(master, F_SETFL, flags | O_NONBLOCK);

  pty_handle *h = (pty_handle *) lua_newuserdata(L, sizeof(pty_handle));
  h->master = master;
  h->pid = pid;
  h->exited = 0;
  h->exit_status = -1;
  luaL_getmetatable(L, PTY_HANDLE);
  lua_setmetatable(L, -2);
  return 1;
}

/* h:read() -> data:string (possibly "" -- nothing available this frame) |
 * nil, "eof" once the child side is gone. */
static int f_read(lua_State *L) {
  pty_handle *h = check_pty(L);
  if (h->master < 0) { lua_pushnil(L); lua_pushliteral(L, "eof"); return 2; }

  char buf[4096];
  ssize_t n = read(h->master, buf, sizeof buf);
  if (n > 0) { lua_pushlstring(L, buf, (size_t) n); return 1; }
  if (n == 0) { lua_pushnil(L); lua_pushliteral(L, "eof"); return 2; }
  if (errno == EAGAIN || errno == EWOULDBLOCK) { lua_pushliteral(L, ""); return 1; }
  /* BSD/macOS report a dead child's slave as EIO on the master rather than a
   * clean 0-byte read -- both mean the same thing to a caller: nothing left
   * to read, ever. */
  if (errno == EIO) { lua_pushnil(L); lua_pushliteral(L, "eof"); return 2; }
  lua_pushnil(L);
  lua_pushstring(L, strerror(errno));
  return 2;
}

/* h:write(data) -> n:integer | nil, err. Non-blocking: a full pty ring just
 * accepts fewer bytes than given, same shape as a non-blocking socket write --
 * the caller keeps whatever wasn't written and retries next frame. */
static int f_write(lua_State *L) {
  pty_handle *h = check_pty(L);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  if (h->master < 0) { lua_pushnil(L); lua_pushliteral(L, "closed"); return 2; }
  ssize_t n = write(h->master, data, len);
  if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) { lua_pushinteger(L, 0); return 1; }
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  lua_pushinteger(L, n);
  return 1;
}

/* h:resize(cols, rows) -> ok:boolean. ioctl(TIOCSWINSZ) raises SIGWINCH in
 * the child, same as a real terminal being dragged wider. */
static int f_resize(lua_State *L) {
  pty_handle *h = check_pty(L);
  int cols = (int) luaL_checkinteger(L, 2);
  int rows = (int) luaL_checkinteger(L, 3);
  if (h->master < 0 || cols < 1 || rows < 1) { lua_pushboolean(L, 0); return 1; }
  struct winsize ws;
  memset(&ws, 0, sizeof ws);
  ws.ws_col = (unsigned short) cols;
  ws.ws_row = (unsigned short) rows;
  lua_pushboolean(L, ioctl(h->master, TIOCSWINSZ, &ws) == 0);
  return 1;
}

/* h:alive() -> bool. Reaps the child first, so this is also the thing that
 * keeps a finished child from sitting around as a zombie. */
static int f_alive(lua_State *L) {
  pty_handle *h = check_pty(L);
  reap(h);
  lua_pushboolean(L, !h->exited);
  return 1;
}

/* h:exit_status() -> integer | nil (still running, or never started). */
static int f_exit_status(lua_State *L) {
  pty_handle *h = check_pty(L);
  reap(h);
  if (!h->exited) { lua_pushnil(L); return 1; }
  lua_pushinteger(L, h->exit_status);
  return 1;
}

static void pty_close(pty_handle *h) {
  if (h->master >= 0) { close(h->master); h->master = -1; }
  if (h->pid > 0 && !h->exited) {
    kill(h->pid, SIGHUP);
    reap(h);   /* one non-blocking attempt; a straggler is init's problem now */
  }
}

static int f_close(lua_State *L) {
  pty_close(check_pty(L));
  return 0;
}

static int f_gc(lua_State *L) {
  pty_close(check_pty(L));
  return 0;
}

static const luaL_Reg pty_methods[] = {
  { "read",        f_read        },
  { "write",       f_write       },
  { "resize",      f_resize      },
  { "alive",       f_alive       },
  { "exit_status", f_exit_status },
  { "close",       f_close       },
  { "__gc",        f_gc          },
  { NULL, NULL }
};

static const luaL_Reg pty_lib[] = {
  { "open", f_open },
  { NULL, NULL }
};

int luaopen_pty(lua_State *L) {
  luaL_newmetatable(L, PTY_HANDLE);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, pty_methods, 0);
  lua_pop(L, 1);

  luaL_newlib(L, pty_lib);
  return 1;
}

#else /* _WIN32: no PTY host yet. Registering an empty table (rather than not
       * registering `pty` at all) means terminalview.lua can still say
       * `if not pty.open then ...` instead of every caller needing a pcall,
       * and the studio still links and runs on Windows with the terminal
       * simply unavailable. */

#include "lua.h"
#include "lauxlib.h"

int luaopen_pty(lua_State *L) {
  lua_newtable(L);
  return 1;
}

#endif
