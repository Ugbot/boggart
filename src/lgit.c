/* lgit.c -- git as a governed C capability, exposed to Lua as `git`.
 *
 * Why C, when boggart deliberately moved subprocess spawning out to Lua
 * (lua/proc.lua, so the agent can rewrite it): git here is the *safety* layer --
 * per-turn checkpoints and undo. The whole value of a safety net is that the
 * thing being kept safe cannot quietly cut it, so this one capability lives
 * below the line the agent can edit, and its policy is fixed in C:
 *
 *   - checkpoints only ever write hidden refs under refs/boggart/, never the
 *     user's branches or HEAD or index;
 *   - a checkpoint is taken through a throwaway index so a brand-new (untracked)
 *     file is captured too -- `git stash create` would silently drop it;
 *   - worktrees are added and removed by us, so an agent cannot leak them.
 *
 * Why uv_spawn and not libgit2: libuv is already linked, so this adds no
 * dependency and keeps the single self-contained binary. git itself must be on
 * PATH -- which any worktree workflow already assumes. Each call runs git
 * synchronously on a private, short-lived loop, so a headless run pays nothing
 * until a git op is actually used and there is no interaction with the agent's
 * own uv loop.
 */
#include <stdlib.h>
#include <string.h>

#include "uv.h"
#include "lua.h"
#include "lauxlib.h"

/* ---- a growable byte buffer the read callbacks append into ---------------- */

typedef struct {
  char  *data;
  size_t len;
  size_t cap;
} gbuf;

static void gbuf_append(gbuf *b, const char *p, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap * 2 : 4096;
    while (cap < b->len + n + 1) cap *= 2;
    b->data = (char *)realloc(b->data, cap);
    b->cap = cap;
  }
  memcpy(b->data + b->len, p, n);
  b->len += n;
  b->data[b->len] = '\0';
}

/* ---- one synchronous git invocation --------------------------------------- */

typedef struct {
  gbuf out;         /* stdout and stderr, merged in arrival order */
  long exit_status; /* git's exit code */
  int  open_pipes;  /* how many capture pipes are still open */
} gitrun;

static void on_alloc(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)h;
  buf->base = (char *)malloc(suggested);
  buf->len = suggested;
}

static void on_read(uv_stream_t *s, ssize_t nread, const uv_buf_t *buf) {
  gitrun *r = (gitrun *)s->data;
  if (nread > 0) {
    gbuf_append(&r->out, buf->base, (size_t)nread);
  } else if (nread < 0) {
    uv_close((uv_handle_t *)s, NULL);
    r->open_pipes--;
  }
  free(buf->base);
}

static void on_git_exit(uv_process_t *proc, int64_t status, int term_signal) {
  gitrun *r = (gitrun *)proc->data;
  (void)term_signal;
  r->exit_status = (long)status;
  uv_close((uv_handle_t *)proc, NULL);
}

/* Run `git <argv...>` in cwd, with an optional single extra environment entry
 * (used for GIT_INDEX_FILE). argv is NULL-terminated and does NOT include the
 * leading "git". On success returns 0 and fills out and code; on spawn failure
 * returns the uv error and leaves a message in out. */
static int git_exec(const char *cwd, char *const *argv, const char *extra_env,
                    gbuf *out, long *code) {
  uv_loop_t loop;
  uv_pipe_t outpipe, errpipe;
  uv_process_t proc;
  uv_process_options_t opts;
  uv_stdio_container_t stdio[3];
  gitrun run;
  int r;

  memset(&run, 0, sizeof run);
  uv_loop_init(&loop);
  uv_pipe_init(&loop, &outpipe, 0);
  uv_pipe_init(&loop, &errpipe, 0);
  outpipe.data = &run;
  errpipe.data = &run;
  proc.data = &run;

  /* Build the child environment: inherit ours, optionally add one entry. NULL
   * env means "inherit" in libuv, so we only build a vector when overriding. */
  char **child_env = NULL;
  if (extra_env) {
    extern char **environ;
    size_t n = 0;
    while (environ[n]) n++;
    child_env = (char **)malloc((n + 2) * sizeof(char *));
    for (size_t i = 0; i < n; i++) child_env[i] = environ[i];
    child_env[n] = (char *)extra_env;
    child_env[n + 1] = NULL;
  }

  memset(&opts, 0, sizeof opts);
  opts.file = "git";
  opts.args = (char **)argv;   /* argv[0] must be "git" */
  opts.cwd = cwd;
  opts.env = child_env;
  opts.exit_cb = on_git_exit;
  opts.stdio_count = 3;
  opts.stdio = stdio;
  stdio[0].flags = UV_IGNORE;
  stdio[1].flags = (uv_stdio_flags)(UV_CREATE_PIPE | UV_WRITABLE_PIPE);
  stdio[1].data.stream = (uv_stream_t *)&outpipe;
  stdio[2].flags = (uv_stdio_flags)(UV_CREATE_PIPE | UV_WRITABLE_PIPE);
  stdio[2].data.stream = (uv_stream_t *)&errpipe;

  r = uv_spawn(&loop, &proc, &opts);
  if (r != 0) {
    gbuf_append(&run.out, uv_strerror(r), strlen(uv_strerror(r)));
    uv_close((uv_handle_t *)&outpipe, NULL);
    uv_close((uv_handle_t *)&errpipe, NULL);
    uv_run(&loop, UV_RUN_DEFAULT);
    uv_loop_close(&loop);
    free(child_env);
    *out = run.out;
    return r;
  }

  run.open_pipes = 2;
  uv_read_start((uv_stream_t *)&outpipe, on_alloc, on_read);
  uv_read_start((uv_stream_t *)&errpipe, on_alloc, on_read);
  uv_run(&loop, UV_RUN_DEFAULT);
  uv_loop_close(&loop);
  free(child_env);

  *out = run.out;
  *code = run.exit_status;
  return 0;
}

/* Trim one trailing newline, the common git-output shape. */
static void chomp(gbuf *b) {
  while (b->len > 0 && (b->data[b->len - 1] == '\n' || b->data[b->len - 1] == '\r'))
    b->data[--b->len] = '\0';
}

/* Run git with a fixed argv list; push (output, code) or (nil, message). */
static int run_and_push(lua_State *L, const char *cwd, char *const *argv,
                        const char *extra_env) {
  gbuf out;
  long code = -1;
  memset(&out, 0, sizeof out);
  int r = git_exec(cwd, argv, extra_env, &out, &code);
  if (r != 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "could not run git: %s", out.data ? out.data : "spawn failed");
    free(out.data);
    return 2;
  }
  chomp(&out);
  lua_pushlstring(L, out.data ? out.data : "", out.len);
  lua_pushinteger(L, code);
  free(out.data);
  return 2;
}

/* ---- the argument the C ops share ----------------------------------------- */

static const char *repo_dir(lua_State *L, int idx) {
  return luaL_optstring(L, idx, ".");
}

/* git.run(dir, {args...}) -> output, exit_code | nil, err
 * The escape hatch: any git subcommand, argv-safe (no shell). Compound ops
 * below are built on git_exec directly, with policy baked in. */
static int l_run(lua_State *L) {
  const char *dir = repo_dir(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  int n = (int)luaL_len(L, 2);
  if (n < 1) return luaL_error(L, "git.run needs at least one argument");
  /* argv = "git", <args...>, NULL */
  char **argv = (char **)calloc((size_t)n + 2, sizeof(char *));
  argv[0] = "git";
  for (int i = 1; i <= n; i++) {
    lua_geti(L, 2, i);
    argv[i] = (char *)luaL_checkstring(L, -1);
    lua_pop(L, 1);
  }
  argv[n + 1] = NULL;
  /* Keep the Lua strings alive across the call: they are on the stack via the
   * table, which we do not pop, so the pointers remain valid. */
  int nres = run_and_push(L, dir, argv, NULL);
  free(argv);
  return nres;
}

/* git.is_repo(dir) -> bool */
static int l_is_repo(lua_State *L) {
  const char *dir = repo_dir(L, 1);
  char *argv[] = { "git", "rev-parse", "--is-inside-work-tree", NULL };
  gbuf out; long code = -1; memset(&out, 0, sizeof out);
  int r = git_exec(dir, argv, NULL, &out, &code);
  free(out.data);
  lua_pushboolean(L, r == 0 && code == 0);
  return 1;
}

/* git.current_branch(dir) -> name | nil */
static int l_current_branch(lua_State *L) {
  const char *dir = repo_dir(L, 1);
  char *argv[] = { "git", "branch", "--show-current", NULL };
  gbuf out; long code = -1; memset(&out, 0, sizeof out);
  int r = git_exec(dir, argv, NULL, &out, &code);
  if (r != 0 || code != 0) { lua_pushnil(L); free(out.data); return 1; }
  chomp(&out);
  if (out.len == 0) lua_pushnil(L); else lua_pushlstring(L, out.data, out.len);
  free(out.data);
  return 1;
}

/* git.checkpoint(dir, refname) -> sha | nil, err
 * Snapshot the whole working tree (INCLUDING untracked files) to a hidden ref
 * under refs/boggart/, touching nothing else. Done through a throwaway index so
 * new files are captured, unlike `git stash create`. */
static int l_checkpoint(lua_State *L) {
  const char *dir = repo_dir(L, 1);
  const char *refname = luaL_checkstring(L, 2);
  if (strncmp(refname, "refs/boggart/", 13) != 0)
    return luaL_error(L, "checkpoint ref must live under refs/boggart/");

  /* A temp index path beside the repo's own, via GIT_INDEX_FILE. */
  char idxpath[512];
  const char *tmp = getenv("TMPDIR");
  snprintf(idxpath, sizeof idxpath, "GIT_INDEX_FILE=%s/bog-idx-%d",
           tmp && *tmp ? tmp : "/tmp", (int)uv_os_getpid());

  gbuf out; long code = -1; memset(&out, 0, sizeof out);

  /* 1. stage everything into the throwaway index */
  { char *a[] = { "git", "add", "-A", NULL };
    memset(&out, 0, sizeof out);
    if (git_exec(dir, a, idxpath, &out, &code) != 0 || code != 0) {
      lua_pushnil(L); lua_pushfstring(L, "checkpoint stage failed: %s", out.data ? out.data : "");
      free(out.data); return 2; }
    free(out.data); }

  /* 2. write a tree object from that index */
  char tree[80];
  { char *a[] = { "git", "write-tree", NULL };
    memset(&out, 0, sizeof out);
    if (git_exec(dir, a, idxpath, &out, &code) != 0 || code != 0) {
      lua_pushnil(L); lua_pushfstring(L, "checkpoint write-tree failed: %s", out.data ? out.data : "");
      free(out.data); return 2; }
    chomp(&out);
    snprintf(tree, sizeof tree, "%s", out.data ? out.data : "");
    free(out.data); }

  /* 3. commit that tree with HEAD as parent (best-effort parent) */
  char head[80] = "";
  { char *a[] = { "git", "rev-parse", "HEAD", NULL };
    memset(&out, 0, sizeof out);
    if (git_exec(dir, a, NULL, &out, &code) == 0 && code == 0) {
      chomp(&out); snprintf(head, sizeof head, "%s", out.data ? out.data : ""); }
    free(out.data); }

  char commit[80];
  { char *with_parent[] = { "git", "commit-tree", tree, "-p", head, "-m", "boggart checkpoint", NULL };
    char *no_parent[]   = { "git", "commit-tree", tree, "-m", "boggart checkpoint", NULL };
    char **a = head[0] ? with_parent : no_parent;
    memset(&out, 0, sizeof out);
    if (git_exec(dir, a, NULL, &out, &code) != 0 || code != 0) {
      lua_pushnil(L); lua_pushfstring(L, "checkpoint commit-tree failed: %s", out.data ? out.data : "");
      free(out.data); return 2; }
    chomp(&out);
    snprintf(commit, sizeof commit, "%s", out.data ? out.data : "");
    free(out.data); }

  /* 4. point the hidden ref at it */
  { char *a[] = { "git", "update-ref", (char *)refname, commit, NULL };
    memset(&out, 0, sizeof out);
    if (git_exec(dir, a, NULL, &out, &code) != 0 || code != 0) {
      lua_pushnil(L); lua_pushfstring(L, "checkpoint update-ref failed: %s", out.data ? out.data : "");
      free(out.data); return 2; }
    free(out.data); }

  lua_pushstring(L, commit);
  return 1;
}

/* git.restore(dir, sha_or_ref) -> true | nil, err
 * Reset the working tree and index to a checkpoint, without moving HEAD or the
 * branch -- an undo, not a history rewrite. */
static int l_restore(lua_State *L) {
  const char *dir = repo_dir(L, 1);
  const char *src = luaL_checkstring(L, 2);
  char *argv[] = { "git", "restore", "--source", (char *)src, "--worktree", "--staged", "--", ".", NULL };
  gbuf out; long code = -1; memset(&out, 0, sizeof out);
  if (git_exec(dir, argv, NULL, &out, &code) != 0 || code != 0) {
    lua_pushnil(L); lua_pushfstring(L, "restore failed: %s", out.data ? out.data : "");
    free(out.data); return 2;
  }
  free(out.data);
  lua_pushboolean(L, 1);
  return 1;
}

/* git.diff(dir, sha_or_ref?) -> text | nil, err  (working tree vs ref/HEAD) */
static int l_diff(lua_State *L) {
  const char *dir = repo_dir(L, 1);
  const char *src = luaL_optstring(L, 2, "HEAD");
  char *argv[] = { "git", "--no-pager", "diff", (char *)src, NULL };
  return run_and_push(L, dir, argv, NULL);
}

/* git.worktree_add(dir, path, ref?) -> true | nil, err */
static int l_worktree_add(lua_State *L) {
  const char *dir = repo_dir(L, 1);
  const char *path = luaL_checkstring(L, 2);
  const char *ref = luaL_optstring(L, 3, "HEAD");
  char *argv[] = { "git", "worktree", "add", (char *)path, (char *)ref, NULL };
  gbuf out; long code = -1; memset(&out, 0, sizeof out);
  if (git_exec(dir, argv, NULL, &out, &code) != 0 || code != 0) {
    lua_pushnil(L); lua_pushfstring(L, "worktree add failed: %s", out.data ? out.data : "");
    free(out.data); return 2;
  }
  free(out.data);
  lua_pushboolean(L, 1);
  return 1;
}

/* git.worktree_remove(dir, path) -> true | nil, err  (force, so a dirty scratch
 * worktree still tears down; the checkpoint is the safety net, not the tree) */
static int l_worktree_remove(lua_State *L) {
  const char *dir = repo_dir(L, 1);
  const char *path = luaL_checkstring(L, 2);
  char *argv[] = { "git", "worktree", "remove", "--force", (char *)path, NULL };
  gbuf out; long code = -1; memset(&out, 0, sizeof out);
  if (git_exec(dir, argv, NULL, &out, &code) != 0 || code != 0) {
    lua_pushnil(L); lua_pushfstring(L, "worktree remove failed: %s", out.data ? out.data : "");
    free(out.data); return 2;
  }
  free(out.data);
  lua_pushboolean(L, 1);
  return 1;
}

/* git.worktree_list(dir) -> text | nil, err */
static int l_worktree_list(lua_State *L) {
  const char *dir = repo_dir(L, 1);
  char *argv[] = { "git", "worktree", "list", NULL };
  return run_and_push(L, dir, argv, NULL);
}

static const luaL_Reg git_lib[] = {
  { "run",             l_run },
  { "is_repo",         l_is_repo },
  { "current_branch",  l_current_branch },
  { "checkpoint",      l_checkpoint },
  { "restore",         l_restore },
  { "diff",            l_diff },
  { "worktree_add",    l_worktree_add },
  { "worktree_remove", l_worktree_remove },
  { "worktree_list",   l_worktree_list },
  { NULL, NULL },
};

int luaopen_boggart_git(lua_State *L) {
  luaL_newlib(L, git_lib);
  return 1;
}
