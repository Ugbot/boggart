/* lsys.c -- small OS bindings boggart needs that the Lua stdlib lacks.
 *
 *   sys.listdir(path)            -> { name, ... }        | nil, err
 *   sys.mkdir_p(path)            -> true                  | nil, err
 *   sys.stat(path)               -> "file" | "dir" | nil
 *   sys.home()                   -> $HOME (or ".")
 *   sys.exec(cmd [, timeout_sec])-> { out=string, code=int, timed_out=bool }
 *   sys.readline(prompt)         -> line:string | nil (EOF/^D)
 *   sys.add_history(line)        -> (void)
 *
 * File read/write, os.getenv, os.tmpname, io.popen etc. are already provided by
 * the Lua standard library, so we do not re-bind them.
 */
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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
static int l_exec(lua_State *L) {
  const char *cmd = luaL_checkstring(L, 1);
  double timeout = luaL_optnumber(L, 2, 0); /* 0 => no timeout */

  int pipefd[2];
  if (pipe(pipefd) != 0) return luaL_error(L, "pipe: %s", strerror(errno));

  pid_t pid = fork();
  if (pid < 0) {
    close(pipefd[0]);
    close(pipefd[1]);
    return luaL_error(L, "fork: %s", strerror(errno));
  }

  if (pid == 0) {
    /* child */
    setpgid(0, 0);
    dup2(pipefd[1], STDOUT_FILENO);
    dup2(pipefd[1], STDERR_FILENO);
    close(pipefd[0]);
    close(pipefd[1]);
    int devnull = open("/dev/null", O_RDONLY);
    if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
    execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
    _exit(127);
  }

  /* parent */
  setpgid(pid, pid);
  close(pipefd[1]);
  /* Non-blocking read end: the timeout drain must never block on a child that
   * escaped the process group (setsid/daemon) and holds the pipe open. */
  int fl = fcntl(pipefd[0], F_GETFL, 0);
  if (fl != -1) fcntl(pipefd[0], F_SETFL, fl | O_NONBLOCK);

  luaL_Buffer out;
  luaL_buffinit(L, &out);

  const size_t MAX_OUTPUT = 16 * 1024 * 1024; /* bound memory on runaway output */
  size_t total = 0;
  struct timespec start;
  clock_gettime(CLOCK_MONOTONIC, &start);
  int timed_out = 0, truncated = 0, done = 0;

  while (!done) {
    struct pollfd pfd = { .fd = pipefd[0], .events = POLLIN };
    int pr = poll(&pfd, 1, 200);
    if (pr > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))) {
      for (;;) {
        char buf[8192];
        ssize_t n = read(pipefd[0], buf, sizeof(buf));
        if (n > 0) {
          if (total < MAX_OUTPUT) {
            size_t take = (total + (size_t)n > MAX_OUTPUT) ? (MAX_OUTPUT - total) : (size_t)n;
            luaL_addlstring(&out, buf, take);
            total += take;
            if (total >= MAX_OUTPUT) { truncated = 1; kill(-pid, SIGKILL); done = 1; break; }
          }
        } else if (n == 0) {
          done = 1; break; /* EOF */
        } else {
          if (errno == EAGAIN || errno == EWOULDBLOCK) break; /* nothing more for now */
          done = 1; break; /* real read error */
        }
      }
      if (pfd.revents & (POLLERR | POLLNVAL)) done = 1;
    }
    if (!done && timeout > 0) {
      struct timespec now;
      clock_gettime(CLOCK_MONOTONIC, &now);
      double elapsed = (now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9;
      if (elapsed >= timeout) {
        timed_out = 1;
        kill(-pid, SIGTERM);
        struct timespec ts = { .tv_sec = 1, .tv_nsec = 0 };
        nanosleep(&ts, NULL);
        kill(-pid, SIGKILL);
        /* drain already-buffered bytes; non-blocking, so this cannot hang even
         * if a daemonized grandchild still holds the pipe open */
        for (;;) {
          char buf[8192];
          ssize_t n = read(pipefd[0], buf, sizeof(buf));
          if (n > 0 && total < MAX_OUTPUT) {
            size_t take = (total + (size_t)n > MAX_OUTPUT) ? (MAX_OUTPUT - total) : (size_t)n;
            luaL_addlstring(&out, buf, take);
            total += take;
          } else {
            break;
          }
        }
        done = 1;
      }
    }
  }
  close(pipefd[0]);

  int status = 0;
  waitpid(pid, &status, 0); /* reaps the direct child (killed on timeout/cap) */
  int code = WIFEXITED(status) ? WEXITSTATUS(status)
             : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
             : -1;

  /* Finalize the buffer FIRST (its boxed userdata must stay on the stack top
   * until pushresult); only then build the result table. */
  luaL_pushresult(&out);          /* [str] */
  lua_newtable(L);                /* [str][tbl] */
  lua_pushvalue(L, -2);           /* [str][tbl][str] */
  lua_setfield(L, -2, "out");     /* [str][tbl] */
  lua_pushinteger(L, code);
  lua_setfield(L, -2, "code");
  lua_pushboolean(L, timed_out);
  lua_setfield(L, -2, "timed_out");
  lua_pushboolean(L, truncated);
  lua_setfield(L, -2, "truncated");
  lua_remove(L, -2);              /* drop the leftover [str] -> [tbl] */
  return 1;
}

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
  {"exec", l_exec},
  {"readline", l_readline},
  {"add_history", l_add_history},
  {"history_file", l_history_file},
  {"rmtree", l_rmtree},
  {"shell", l_shell},
  {"pid", l_pid},
  {"uv_version", l_uv_version},
  {NULL, NULL},
};

int luaopen_boggart_sys(lua_State *L) {
  luaL_newlib(L, sys_lib);
  return 1;
}
