/* lsys.c -- small OS bindings boggart needs that the Lua stdlib lacks.
 *
 *   sys.listdir(path)            -> { name, ... }        | nil, err
 *   sys.mkdir_p(path)            -> true                  | nil, err
 *   sys.stat(path)               -> "file" | "dir" | nil
 *   sys.home()                   -> $HOME (or ".")
 *   sys.exec                     -- installed by boot.lua from lua/proc.lua
 *   sys.readline(prompt)         -> line:string | nil (EOF/^D)
 *   sys.add_history(line)        -> (void)
 *
 * File read/write, os.getenv, os.tmpname, io.popen etc. are already provided by
 * the Lua standard library, so we do not re-bind them.
 */
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "uv.h"

#include "lua.h"
#include "lauxlib.h"
#include "isocline.h"

/* MSVC's <sys/stat.h> defines S_IFDIR/S_IFREG but not the S_IS* predicates,
 * so test the format bits directly. uv_stat_t fills st_mode portably. */
#define BOG_ISDIR(m)  (((m) & S_IFMT) == S_IFDIR)
#define BOG_ISREG(m)  (((m) & S_IFMT) == S_IFREG)

/* All uv_fs_* calls here pass a NULL loop and NULL callback, which makes them
 * synchronous -- no event loop needed. That is deliberate: these are fast
 * metadata operations on local files, and making them async would buy nothing
 * while complicating every caller. libuv is here for the *process* work and
 * for hiding the Win32/POSIX split, not to make stat() concurrent. */
static int l_listdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  uv_fs_t req;
  int rc = uv_fs_scandir(NULL, &req, path, 0, NULL);
  if (rc < 0) {
    uv_fs_req_cleanup(&req);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }
  lua_newtable(L);
  int i = 0;
  uv_dirent_t ent;
  /* uv_fs_scandir_next already filters "." and ".." on every platform. */
  while (uv_fs_scandir_next(&req, &ent) != UV_EOF) {
    lua_pushstring(L, ent.name);
    lua_rawseti(L, -2, ++i);
  }
  uv_fs_req_cleanup(&req);
  return 1;
}

/* mkdir -p. Treats an existing *directory* as success but fails if a path
 * component exists as a non-directory. Returns a libuv error code (< 0). */
static int mkdir_one(const char *p) {
  uv_fs_t req;
  int rc = uv_fs_mkdir(NULL, &req, p, 0700, NULL);
  uv_fs_req_cleanup(&req);
  if (rc == 0) return 0;
  if (rc != UV_EEXIST) return rc;
  /* Already there -- fine only if it is a directory. */
  int rs = uv_fs_stat(NULL, &req, p, NULL);
  int isdir = (rs == 0) && BOG_ISDIR(req.statbuf.st_mode);
  uv_fs_req_cleanup(&req);
  if (rs != 0) return rs;
  return isdir ? 0 : UV_ENOTDIR;
}

/* Both separators are treated as separators: Windows accepts '/' in its APIs,
 * but a caller (or a config file) may well hand us backslashes. */
static int is_sep(char c) {
#ifdef _WIN32
  return c == '/' || c == '\\';
#else
  return c == '/';
#endif
}

static int mkdir_p(const char *path) {
  char tmp[4096];
  size_t len = strlen(path);
  if (len == 0) return UV_EINVAL;
  if (len >= sizeof(tmp)) return UV_ENAMETOOLONG;
  memcpy(tmp, path, len + 1);
  while (len > 1 && is_sep(tmp[len - 1])) tmp[--len] = '\0';
  for (char *p = tmp + 1; *p; p++) {
    if (is_sep(*p)) {
      char sep = *p;
      *p = '\0';
      /* Skip a bare drive prefix ("C:") or a UNC/root fragment, which cannot
       * be created and would fail with EEXIST/EACCES on Windows. */
      int skip = (p == tmp + 1 && tmp[0] == '\0');
#ifdef _WIN32
      if (p == tmp + 2 && tmp[1] == ':') skip = 1;
#endif
      if (!skip) {
        int rc = mkdir_one(tmp);
        if (rc != 0) { *p = sep; return rc; }
      }
      *p = sep;
    }
  }
  return mkdir_one(tmp);
}

static int l_mkdir_p(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int rc = mkdir_p(path);
  if (rc != 0) {
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int l_stat(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  uv_fs_t req;
  int rc = uv_fs_stat(NULL, &req, path, NULL);
  if (rc < 0) {
    uv_fs_req_cleanup(&req);
    lua_pushnil(L);
    return 1;
  }
  uint64_t mode = req.statbuf.st_mode;
  uv_fs_req_cleanup(&req);
  if (BOG_ISDIR(mode)) lua_pushstring(L, "dir");
  else if (BOG_ISREG(mode)) lua_pushstring(L, "file");
  else lua_pushstring(L, "other");
  return 1;
}

/* Recursive delete, depth-limited. Replaces the `rm -rf` shell-out that
 * boggart used for `--reset`, which has no Windows equivalent (and quoted a
 * user-supplied path into a shell, which was never a good idea).
 * Returns 0 or a libuv error code. */
#define BOG_RMTREE_MAX_DEPTH 64

static int rmtree(const char *path, int depth) {
  uv_fs_t req;
  if (depth > BOG_RMTREE_MAX_DEPTH) return UV_ELOOP;

  int rc = uv_fs_lstat(NULL, &req, path, NULL);
  if (rc < 0) { uv_fs_req_cleanup(&req); return rc; }
  int isdir = BOG_ISDIR(req.statbuf.st_mode);
  uv_fs_req_cleanup(&req);

  /* lstat, not stat: a symlink to a directory must be unlinked, never
   * descended into, or --reset could walk out of the overlay dir entirely. */
  if (!isdir) {
    rc = uv_fs_unlink(NULL, &req, path, NULL);
    uv_fs_req_cleanup(&req);
    return rc;
  }

  rc = uv_fs_scandir(NULL, &req, path, 0, NULL);
  if (rc < 0) { uv_fs_req_cleanup(&req); return rc; }
  uv_dirent_t ent;
  int err = 0;
  while (uv_fs_scandir_next(&req, &ent) != UV_EOF) {
    char child[4096];
    int n = snprintf(child, sizeof(child), "%s/%s", path, ent.name);
    if (n < 0 || (size_t)n >= sizeof(child)) { err = UV_ENAMETOOLONG; break; }
    int crc = rmtree(child, depth + 1);
    if (crc != 0 && err == 0) err = crc;
  }
  uv_fs_req_cleanup(&req);
  if (err != 0) return err;

  rc = uv_fs_rmdir(NULL, &req, path, NULL);
  uv_fs_req_cleanup(&req);
  return rc;
}

static int l_rmtree(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  /* Refuse the obviously catastrophic targets outright. Callers pass paths
   * built from bog.userdir, but this is a one-line guard against a bug there
   * turning into an unrecoverable afternoon. */
  if (path[0] == '\0' || strcmp(path, "/") == 0 || strcmp(path, ".") == 0 ||
      strcmp(path, "..") == 0) {
    lua_pushnil(L);
    lua_pushstring(L, "refusing to remove a root or relative path");
    return 2;
  }
  int rc = rmtree(path, 0);
  if (rc != 0 && rc != UV_ENOENT) { /* already-absent is success */
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* sys.cwd() -> path. Used to identify the project a tool belongs to. */
static int l_cwd(lua_State *L) {
  char buf[4096];
  size_t len = sizeof(buf);
  if (uv_cwd(buf, &len) == 0) lua_pushlstring(L, buf, len);
  else lua_pushstring(L, ".");
  return 1;
}

/* sys.tmpdir() -> path
 * uv_os_tmpdir consults TMPDIR/TMP/TEMP and the platform defaults in the right
 * order, so Lua never has to guess at environment variables. */
static int l_tmpdir(lua_State *L) {
  char buf[4096];
  size_t len = sizeof(buf);
  if (uv_os_tmpdir(buf, &len) == 0) lua_pushlstring(L, buf, len);
  else lua_pushstring(L, ".");
  return 1;
}

/* sys.caps() -> table of platform capabilities.
 *
 * The point of this table is that the Lua layer never asks "am I on Windows".
 * It asks whether the thing it wants to do is *available* -- can I signal a
 * process, is there a process group to kill, will a symlink work. Those are the
 * questions the code actually has, and phrasing them that way keeps the OS
 * knowledge on this side of the boundary where it belongs. A new platform then
 * means editing this function, not hunting for path-separator tests scattered
 * through the harness. */
static int l_caps(lua_State *L) {
  lua_newtable(L);
#ifdef _WIN32
  lua_pushstring(L, "cmd");   lua_setfield(L, -2, "shell_kind");
  lua_pushstring(L, "\\");    lua_setfield(L, -2, "path_sep");
  lua_pushboolean(L, 0);      lua_setfield(L, -2, "signals");
  lua_pushboolean(L, 0);      lua_setfield(L, -2, "process_groups");
  lua_pushboolean(L, 0);      lua_setfield(L, -2, "symlinks");
  lua_pushstring(L, "windows"); lua_setfield(L, -2, "name");
#else
  lua_pushstring(L, "posix"); lua_setfield(L, -2, "shell_kind");
  lua_pushstring(L, "/");     lua_setfield(L, -2, "path_sep");
  lua_pushboolean(L, 1);      lua_setfield(L, -2, "signals");
  lua_pushboolean(L, 1);      lua_setfield(L, -2, "process_groups");
  lua_pushboolean(L, 1);      lua_setfield(L, -2, "symlinks");
#if defined(__APPLE__)
  lua_pushstring(L, "macos"); lua_setfield(L, -2, "name");
#else
  lua_pushstring(L, "linux"); lua_setfield(L, -2, "name");
#endif
#endif
  /* Signal numbers as plain integers, so callers need no <signal.h> and no
   * per-platform spelling. These two are the same everywhere that has them. */
  lua_pushinteger(L, 15); lua_setfield(L, -2, "SIGTERM");
  lua_pushinteger(L, 9);  lua_setfield(L, -2, "SIGKILL");
  return 1;
}

/* sys.kill_tree(pid, signum) -> true | nil, err
 *
 * Kill a child *and its descendants*. Shell commands routinely leave
 * grandchildren behind, so signalling only the direct child orphans them.
 * On POSIX that means negating the pid to hit the whole process group; on
 * Windows there is no process group to signal and only the named process
 * dies -- doing better needs a Job Object, which libuv does not expose.
 * Either way the caller just says "kill the tree" and this decides how. */
static int l_kill_tree(lua_State *L) {
  int pid = (int)luaL_checkinteger(L, 1);
  int sig = (int)luaL_optinteger(L, 2, 15);
#ifdef _WIN32
  int rc = uv_kill(pid, sig);
#else
  int rc = uv_kill(-pid, sig);
#endif
  if (rc != 0) {
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* sys.pid() -> integer. uv_os_getpid rather than getpid(), which MSVC spells
 * _getpid() in <process.h>. Used to keep temp filenames distinct per process. */
static int l_pid(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)uv_os_getpid());
  return 1;
}

/* sys.shell() -> exe, flag
 * The platform shell, so Lua never hardcodes /bin/sh. prompt.lua uses this to
 * tell the model which shell it is writing commands for -- getting that wrong
 * is a correctness bug (the model will happily emit `ls | grep` into cmd.exe). */
static int l_shell(lua_State *L) {
#ifdef _WIN32
  const char *exe = getenv("COMSPEC");
  lua_pushstring(L, exe && *exe ? exe : "cmd.exe");
  lua_pushstring(L, "/c");
#else
  lua_pushstring(L, "/bin/sh");
  lua_pushstring(L, "-c");
#endif
  return 2;
}

/* sys.uv_version() -> "1.52.1"
 * The first real call into libuv. Beyond diagnostics, this is what proves the
 * vendored static lib is genuinely linked: nothing else references uv_* yet,
 * so the linker would otherwise discard the archive entirely. */
static int l_uv_version(lua_State *L) {
  lua_pushstring(L, uv_version_string());
  return 1;
}

/* uv_os_homedir checks $HOME then falls back to the password database on
 * POSIX, and %USERPROFILE% then the Win32 token API on Windows -- which is
 * exactly the portability the old getenv("HOME") lacked. */
static int l_home(lua_State *L) {
  char buf[4096];
  size_t len = sizeof(buf);
  if (uv_os_homedir(buf, &len) == 0) lua_pushlstring(L, buf, len);
  else lua_pushstring(L, ".");
  return 1;
}

/* Run cmd via /bin/sh -c, capturing stdout+stderr, with an optional wall-clock
 * timeout. Runs in its own process group so a timeout kills the whole tree. */
/* sys.exec used to live here: a fork/execl/pipe/poll/waitpid implementation,
 * ~115 lines of POSIX that had no Windows counterpart and blocked its caller
 * for the whole life of the child. It is gone. lua/proc.lua does the same job
 * on the libuv loop -- portable, and able to yield to the scheduler -- and
 * boot.lua installs it as sys.exec so every existing caller is unchanged.
 *
 * Removing it is what takes the last fork/exec/poll/waitpid out of this file,
 * and with them <unistd.h>, <sys/wait.h>, <poll.h>, <dirent.h>, <fcntl.h>,
 * <signal.h> and <sys/types.h>. */

/* isocline rather than linenoise: linenoise is termios/ioctl throughout with
 * no Windows port, so the REPL had no line editor there at all. isocline
 * carries a console-API backend alongside the POSIX one and keeps history,
 * completion, multi-line editing and UTF-8.
 *
 * NOTE: ic_readline() blocks until the user presses Enter, so the uv loop does
 * not turn while input is being typed. That matches the previous behaviour and
 * is fine while the REPL has nothing to do meanwhile; if it ever needs
 * background work (live agents, a status line), the fix is to run the editor on
 * its own thread and hand the finished line back via uv_async_send -- the same
 * ownership-transfer pattern as src/jwriter.c. */
static int l_readline(lua_State *L) {
  const char *prompt = luaL_optstring(L, 1, "");
  char *line = ic_readline(prompt);
  if (line == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushstring(L, line);
  ic_free(line);
  return 1;
}

/* sys.history_file(path [, max]) -- persist REPL history across sessions.
 * linenoise never had this wired up; isocline gives it for one call. */
static int l_history_file(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  long max = (long)luaL_optinteger(L, 2, 500);
  ic_set_history(path, max);
  return 0;
}

static int l_add_history(lua_State *L) {
  const char *line = luaL_checkstring(L, 1);
  if (line[0]) ic_history_add(line);
  return 0;
}

static const luaL_Reg sys_lib[] = {
  {"listdir", l_listdir},
  {"mkdir_p", l_mkdir_p},
  {"stat", l_stat},
  {"home", l_home},
  {"readline", l_readline},
  {"add_history", l_add_history},
  {"history_file", l_history_file},
  {"rmtree", l_rmtree},
  {"shell", l_shell},
  {"pid", l_pid},
  {"tmpdir", l_tmpdir},
  {"cwd", l_cwd},
  {"caps", l_caps},
  {"kill_tree", l_kill_tree},
  {"uv_version", l_uv_version},
  {NULL, NULL},
};

int luaopen_boggart_sys(lua_State *L) {
  luaL_newlib(L, sys_lib);
  return 1;
}
