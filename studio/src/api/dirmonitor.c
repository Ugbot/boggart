/* Filesystem change notification for the project file list.
 *
 * The editor core came from rxi's lite, which rescanned the whole project tree
 * on a five-second timer -- one stat() per file, forever, whether or not
 * anything had changed. lite-xl's answer was four hand-written backends
 * (FSEvents, inotify, kqueue, ReadDirectoryChangesW) behind a portable shell.
 * We already link libuv, and uv_fs_event_t *is* those same four backends: on
 * macOS it is FSEvents, on Linux inotify, on the BSDs kqueue, on Windows
 * ReadDirectoryChangesW. Porting them again would put a second per-platform
 * watching stack next to the one already in the binary, so this wraps libuv.
 *
 * lite-xl also runs its watcher on a thread that wakes every millisecond to
 * push an SDL event. That costs more at idle than the polling it replaced. The
 * loop here is pumped from the frame loop instead (uv_run with UV_RUN_NOWAIT),
 * so an idle editor with nothing changing on disk does no work at all beyond
 * one non-blocking poll of a kqueue/epoll fd.
 *
 * The policy lives on this side of the boundary, which is the same split
 * src/lsys.c draws with sys.caps(): C decides what a change *is* (a directory
 * that needs re-reading, never a file that moved), how many of them may be
 * outstanding, and what happens when that bound is hit. Lua only asks what
 * changed and what this platform can do.
 */
#include "dirmonitor.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <uv.h>

#define API_TYPE_DIRMONITOR "Dirmonitor"

/* Recursive watching is not portable and cannot be probed for: libuv's inotify
 * backend silently ignores UV_FS_EVENT_RECURSIVE rather than refusing it, so a
 * runtime check would report success and then never deliver a subdirectory
 * event. Like sys.caps(), this is a table a new platform edits, not something
 * the Lua layer infers from an OS name. */
#if defined(__APPLE__) || defined(_WIN32)
  #define DIRMONITOR_RECURSIVE 1
#else
  #define DIRMONITOR_RECURSIVE 0
#endif

#if defined(__APPLE__)
  #define DIRMONITOR_BACKEND "fsevents"
#elif defined(_WIN32)
  #define DIRMONITOR_BACKEND "win32"
#elif defined(__linux__)
  #define DIRMONITOR_BACKEND "inotify"
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) \
   || defined(__DragonFly__)
  #define DIRMONITOR_BACKEND "kqueue"
#else
  #define DIRMONITOR_BACKEND "none"
#endif

#ifdef _WIN32
  #define DIRMONITOR_SEP '\\'
#else
  #define DIRMONITOR_SEP '/'
#endif

/* An event storm is the normal case, not the edge: a `git checkout`, a branch
 * switch or a build emits thousands of events in a second, and a recursive
 * FSEvents watch reports every one of them. Two bounds keep that from turning
 * into unbounded work.
 *
 * The first is that a change is recorded as the *directory* it happened in, so
 * a thousand files rewritten under src/ collapse into one entry. The second is
 * this cap: past it we stop recording and raise `overflow`, which tells Lua to
 * do one full rescan instead of an unbounded number of directory rescans. A
 * full rescan of a large project costs ~20ms, so overflowing is cheap -- far
 * cheaper than growing this list without limit. */
#define DIRMONITOR_MAX_DIRTY 256

/* Paths are stored, not just counted, so we hold whole ones. PATH_MAX is 4096
 * on Linux and 1024 on macOS; a path longer than this cannot be opened by the
 * editor either, so truncating to "the watch root changed" is the safe answer
 * rather than a failure. */
#define DIRMONITOR_MAX_PATH 4096

struct dirmonitor;

struct dm_watch {
  uv_fs_event_t handle;      /* first member: uv handle data points back here */
  struct dirmonitor *mon;
  char *path;                /* exactly the string Lua asked us to watch */
  size_t path_len;
  int id;                    /* 1-based index into mon->watches */
  int active;
};

struct dirmonitor {
  uv_loop_t loop;
  int open;                  /* 0 once closed or if the loop never came up */
  struct dm_watch **watches;
  int nwatches;              /* allocated slots, some may be NULL */
  int live;                  /* slots currently watching */
  char *dirty[DIRMONITOR_MAX_DIRTY];
  int ndirty;
  int overflow;
};


/* ---- the dirty set -------------------------------------------------------- */

static void dirty_clear(struct dirmonitor *mon) {
  for (int i = 0; i < mon->ndirty; i++) { free(mon->dirty[i]); mon->dirty[i] = NULL; }
  mon->ndirty = 0;
  mon->overflow = 0;
}


static void dirty_add(struct dirmonitor *mon, const char *path) {
  /* Linear dedup against at most DIRMONITOR_MAX_DIRTY short strings. A hash
   * would be faster in theory and slower in practice at this size, and it
   * would need a growth policy this deliberately does not have. */
  for (int i = 0; i < mon->ndirty; i++) {
    if (strcmp(mon->dirty[i], path) == 0) return;
  }
  if (mon->ndirty >= DIRMONITOR_MAX_DIRTY) { mon->overflow = 1; return; }
  char *copy = malloc(strlen(path) + 1);
  if (!copy) { mon->overflow = 1; return; }
  strcpy(copy, path);
  mon->dirty[mon->ndirty++] = copy;
}


/* Reduce an event to the directory that has to be re-read.
 *
 * Editors do not modify files, they write a temporary and rename over the
 * target, so the interesting event is nearly always a rename on a name we were
 * watching -- and on Linux an inode watch follows the *old* file. Reporting "a
 * file moved" would therefore be a lie half the time. Reporting "this directory
 * changed" is true for create, modify, rename and delete alike, and it is also
 * what makes coalescing possible: the storm collapses to the set of directories
 * touched.
 *
 * The path is rebuilt from the string we were handed at watch time plus the
 * relative name libuv reports, never from an absolute path the backend
 * produced. FSEvents resolves symlinks, so its absolute paths do not
 * necessarily match what the project list calls the same directory. */
static void mark_change(struct dm_watch *w, const char *filename) {
  char buf[DIRMONITOR_MAX_PATH];
  if (w->path_len >= sizeof(buf)) return;
  memcpy(buf, w->path, w->path_len);
  buf[w->path_len] = '\0';

  if (filename && *filename) {
    const char *last = NULL;
    for (const char *p = filename; *p; p++) {
      if (*p == '/' || *p == '\\') last = p;
    }
    /* No separator means the change is a direct child of the watched
     * directory, so the watched directory itself is what needs re-reading.
     * That also covers the case where libuv names the watched directory by its
     * own basename, which is what its FSEvents backend does when the watched
     * path is the thing that changed. */
    if (last) {
      size_t dlen = (size_t)(last - filename);
      if (w->path_len + 1 + dlen < sizeof(buf)) {
        buf[w->path_len] = DIRMONITOR_SEP;
        memcpy(buf + w->path_len + 1, filename, dlen);
        buf[w->path_len + 1 + dlen] = '\0';
      }
    }
  }
  dirty_add(w->mon, buf);
}


static void on_fs_event(uv_fs_event_t *handle, const char *filename,
                        int events, int status) {
  (void) events;
  struct dm_watch *w = handle->data;
  if (!w || !w->mon) return;
  /* A watch that errors out (its directory went away under us) still has to be
   * reported, or the entry it stood for would linger in the file list forever.
   * The watch path itself is what changed, so that is what we mark. */
  mark_change(w, status < 0 ? NULL : filename);
}


/* ---- lifecycle ------------------------------------------------------------ */

static void on_watch_closed(uv_handle_t *handle) {
  struct dm_watch *w = handle->data;
  if (!w) return;
  free(w->path);
  free(w);
}


static void stop_watch(struct dirmonitor *mon, int idx) {
  struct dm_watch *w = mon->watches[idx];
  if (!w) return;
  mon->watches[idx] = NULL;
  if (w->active) { mon->live--; w->active = 0; }
  w->mon = NULL;
  uv_fs_event_stop(&w->handle);
  uv_close((uv_handle_t *)&w->handle, on_watch_closed);
}


static void close_monitor(struct dirmonitor *mon) {
  if (!mon->open) return;
  mon->open = 0;
  for (int i = 0; i < mon->nwatches; i++) stop_watch(mon, i);
  /* uv_close is asynchronous even for handles that never became active, so the
   * loop has to be run once more or the close callbacks -- and the memory they
   * free -- never happen. */
  uv_run(&mon->loop, UV_RUN_DEFAULT);
  uv_loop_close(&mon->loop);
  free(mon->watches);
  mon->watches = NULL;
  mon->nwatches = 0;
  mon->live = 0;
  dirty_clear(mon);
}


static struct dirmonitor *check_monitor(lua_State *L) {
  return luaL_checkudata(L, 1, API_TYPE_DIRMONITOR);
}


static int f_dirmonitor_new(lua_State *L) {
  struct dirmonitor *mon = lua_newuserdata(L, sizeof(struct dirmonitor));
  memset(mon, 0, sizeof(*mon));
  luaL_setmetatable(L, API_TYPE_DIRMONITOR);
  int rc = uv_loop_init(&mon->loop);
  if (rc != 0) {
    /* No loop means no watching at all. Say so rather than handing back an
     * object that will accept watches and never report anything: a watcher
     * that silently stops noticing is worse than the polling it replaced. */
    lua_pushnil(L);
    lua_pushstring(L, uv_err_name(rc));
    return 2;
  }
  mon->open = 1;
  return 1;
}


static int f_dirmonitor_gc(lua_State *L) {
  close_monitor(check_monitor(L));
  return 0;
}


static int f_dirmonitor_close(lua_State *L) {
  close_monitor(check_monitor(L));
  return 0;
}


/* ---- watching ------------------------------------------------------------- */

static int f_dirmonitor_watch(lua_State *L) {
  struct dirmonitor *mon = check_monitor(L);
  const char *path = luaL_checkstring(L, 2);
  if (!mon->open) { lua_pushnil(L); lua_pushstring(L, "EBADF"); return 2; }

  int idx = -1;
  for (int i = 0; i < mon->nwatches; i++) {
    if (!mon->watches[i]) { idx = i; break; }
  }
  if (idx < 0) {
    int cap = mon->nwatches ? mon->nwatches * 2 : 32;
    struct dm_watch **grown = realloc(mon->watches, (size_t)cap * sizeof(*grown));
    if (!grown) { lua_pushnil(L); lua_pushstring(L, "ENOMEM"); return 2; }
    mon->watches = grown;
    for (int i = mon->nwatches; i < cap; i++) mon->watches[i] = NULL;
    idx = mon->nwatches;
    mon->nwatches = cap;
  }

  struct dm_watch *w = calloc(1, sizeof(*w));
  if (!w) { lua_pushnil(L); lua_pushstring(L, "ENOMEM"); return 2; }
  w->path_len = strlen(path);
  w->path = malloc(w->path_len + 1);
  if (!w->path) { free(w); lua_pushnil(L); lua_pushstring(L, "ENOMEM"); return 2; }
  memcpy(w->path, path, w->path_len + 1);
  w->mon = mon;
  w->id = idx + 1;

  int rc = uv_fs_event_init(&mon->loop, &w->handle);
  if (rc != 0) {
    free(w->path); free(w);
    lua_pushnil(L); lua_pushstring(L, uv_err_name(rc));
    return 2;
  }
  w->handle.data = w;

  /* UV_FS_EVENT_RECURSIVE is honoured by FSEvents and ReadDirectoryChangesW and
   * ignored by inotify, so asking for it where it does not exist would give a
   * watcher that reports nothing below the top level. Ask only where the caps
   * table says it means something; elsewhere Lua registers one watch per
   * directory, which is what inotify has always required. */
  rc = uv_fs_event_start(&w->handle, on_fs_event, path,
                         DIRMONITOR_RECURSIVE ? UV_FS_EVENT_RECURSIVE : 0);
  if (rc != 0) {
    /* ENOSPC here is inotify's per-user watch limit
     * (fs.inotify.max_user_watches), shared across the whole session and
     * routinely 8192. Hitting it is expected on a large tree, and the caller
     * has to be told so it can fall back rather than quietly go blind. */
    w->mon = NULL;
    uv_close((uv_handle_t *)&w->handle, on_watch_closed);
    lua_pushnil(L);
    lua_pushstring(L, uv_err_name(rc));
    return 2;
  }

  mon->watches[idx] = w;
  w->active = 1;
  mon->live++;
  lua_pushinteger(L, w->id);
  return 1;
}


static int f_dirmonitor_unwatch(lua_State *L) {
  struct dirmonitor *mon = check_monitor(L);
  int id = (int) luaL_checkinteger(L, 2);
  if (mon->open && id >= 1 && id <= mon->nwatches) stop_watch(mon, id - 1);
  return 0;
}


static int f_dirmonitor_count(lua_State *L) {
  lua_pushinteger(L, check_monitor(L)->live);
  return 1;
}


/* monitor:check() -> { changed dirs }, overflow
 *
 * Pumps the loop without blocking and hands back the coalesced set. Called from
 * the frame loop, so it must never wait: UV_RUN_NOWAIT polls the backend fd once
 * and runs whatever callbacks are already due. */
static int f_dirmonitor_check(lua_State *L) {
  struct dirmonitor *mon = check_monitor(L);
  if (!mon->open) { lua_pushnil(L); return 1; }

  uv_run(&mon->loop, UV_RUN_NOWAIT);

  lua_createtable(L, mon->ndirty, 0);
  for (int i = 0; i < mon->ndirty; i++) {
    lua_pushstring(L, mon->dirty[i]);
    lua_rawseti(L, -2, i + 1);
  }
  lua_pushboolean(L, mon->overflow);
  dirty_clear(mon);
  return 2;
}


/* ---- capabilities --------------------------------------------------------- */

/* The Lua layer never asks "am I on Linux". It asks whether one watch covers a
 * whole tree and how many watches it may reasonably register -- which are the
 * questions the scanner actually has. */
static int f_dirmonitor_caps(lua_State *L) {
  lua_newtable(L);
  lua_pushstring(L, DIRMONITOR_BACKEND); lua_setfield(L, -2, "backend");
  lua_pushboolean(L, DIRMONITOR_RECURSIVE); lua_setfield(L, -2, "recursive");
  lua_pushboolean(L, strcmp(DIRMONITOR_BACKEND, "none") != 0);
  lua_setfield(L, -2, "available");

  /* inotify's limit is a live sysctl and the single most common reason a
   * watcher goes blind, so report it rather than making the user go looking. */
  long limit = 0;
#if defined(__linux__)
  FILE *fp = fopen("/proc/sys/fs/inotify/max_user_watches", "r");
  if (fp) {
    if (fscanf(fp, "%ld", &limit) != 1) limit = 0;
    fclose(fp);
  }
#endif
  if (limit > 0) { lua_pushinteger(L, limit); lua_setfield(L, -2, "max_watches"); }
  lua_pushinteger(L, DIRMONITOR_MAX_DIRTY);
  lua_setfield(L, -2, "coalesce_limit");
  return 1;
}


static const luaL_Reg dirmonitor_methods[] = {
  { "watch",   f_dirmonitor_watch   },
  { "unwatch", f_dirmonitor_unwatch },
  { "check",   f_dirmonitor_check   },
  { "count",   f_dirmonitor_count   },
  { "close",   f_dirmonitor_close   },
  { "__gc",    f_dirmonitor_gc      },
  { NULL, NULL }
};


void dirmonitor_open(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_DIRMONITOR);
  luaL_setfuncs(L, dirmonitor_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  lua_pushcfunction(L, f_dirmonitor_new);
  lua_setfield(L, -2, "dirmonitor");
  lua_pushcfunction(L, f_dirmonitor_caps);
  lua_setfield(L, -2, "dirmonitor_caps");
}
