/* lview.c -- lazy file views (BOG-23): open a file of any size instantly, read
 * any line or range without loading the rest.
 *
 * Until now every reader loaded whole files: the `read` tool read the entire
 * file and split every line to return 120 of them (its 16 MiB limit checked
 * only AFTER the read); the studio built a Lua table of every line on the UI
 * thread; imports read transcripts with read("a"). A 500 MB log froze the
 * studio and cost several times its size in RAM.
 *
 * A view maps the file (mmap / CreateFileMapping; a read-into-memory fallback
 * where mapping fails) and builds a LINE INDEX -- the byte offset of each line
 * start -- incrementally:
 *   * small files (< 4 MiB) are indexed at open (it is cheaper than a thread);
 *   * large ones on libuv's threadpool (uv_queue_work), in 8 MiB chunks under a
 *     lock, so the loop and UI never wait for it;
 *   * a lookup beyond what has been indexed scans forward synchronously just
 *     far enough -- so `line(10)` of a 2 GB file is instant, and the background
 *     job continues from wherever the index has got to.
 *
 * Lifetime: the shared state is a refcounted C struct, separate from the Lua
 * userdata. The userdata holds one reference and a background job holds
 * another, so a view collected by the GC mid-index cannot leave a job reading
 * unmapped memory; whichever lets go last unmaps.
 *
 * Truncation: reading a mapped page past a file's new end is SIGBUS. Every
 * read path first checks the file has not shrunk (stat size) and refuses with
 * "file changed since it was opened" instead. (A shrink racing the check can
 * still fault; the crash handler reports it. Rewrite-by-rename -- the normal
 * way editors save -- leaves the old inode mapped and is entirely safe.)
 *
 * Lines are split on "\n" and kept byte-exact ("\r" is part of the line, as
 * the read tool always had it); a final newline does not make an empty last
 * line.
 *
 * Lua (module fileview; sys.view = fileview.open):
 *   v = fileview.open(path) | nil, err
 *   v:size()  v:count() -> n, complete   v:wait() -> n   v:line(i)   v:lines(i, j) -> {…}
 *   v:tail(n) -> {…} (scans back from the end; no index needed)
 *   v:find(needle [, from_line]) -> line, col | nil     v:stale()   v:close()
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include "uv.h"
#include "lua.h"
#include "lauxlib.h"
#include "bogassert.h"

#if defined(_WIN32)
#include <windows.h>
#else
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#endif

extern uv_loop_t *luv_loop(lua_State *L);

#define VIEW_MT "boggart.fileview"
#define SYNC_INDEX_BELOW (4u << 20)
#define CHUNK (8u << 20)

typedef struct {
  const char *base;        /* the bytes (mapped or malloc'd) */
  size_t size;
  int mapped;              /* 1: munmap/UnmapViewOfFile on free; 0: free() */
#if defined(_WIN32)
  HANDLE hfile, hmap;
#endif
  char path[1024];
  int64_t ino, dev;        /* identity at open (POSIX) */
  uv_mutex_t mu;           /* guards everything below */
  size_t *offs;            /* line start offsets */
  size_t nlines, cap;
  size_t scanned;          /* bytes indexed so far */
  int complete;
  int refs;                /* userdata + an in-flight job */
  int job;                 /* a background job is queued or running */
  int closing;             /* stop indexing: the view was closed */
  uv_work_t work;
} vstate;

typedef struct { vstate *st; } vud;

static void vstate_unref(vstate *st) {
  uv_mutex_lock(&st->mu);
  int left = --st->refs;
  uv_mutex_unlock(&st->mu);
  if (left > 0) return;
  if (st->base && st->size) {
    if (st->mapped) {
#if defined(_WIN32)
      UnmapViewOfFile((void *)st->base);
      CloseHandle(st->hmap); CloseHandle(st->hfile);
#else
      munmap((void *)st->base, st->size);
#endif
    } else {
      free((void *)st->base);
    }
  }
  free(st->offs);
  uv_mutex_destroy(&st->mu);
  free(st);
}

/* Index forward under the lock until `want_lines` lines are known, `limit`
 * more bytes have been scanned, or the file is done. Caller holds st->mu. */
static void index_locked(vstate *st, size_t want_lines, size_t limit) {
  if (st->complete) return;
  if (st->nlines == 0 && st->scanned == 0 && st->size > 0) {
    if (st->cap == 0) { st->cap = 1024; st->offs = (size_t *)malloc(st->cap * sizeof(size_t)); }
    if (!st->offs) return;
    st->offs[0] = 0;
    st->nlines = 1;
  }
  size_t end = st->size;
  if (limit && st->scanned + limit < end) end = st->scanned + limit;
  const char *p = st->base + st->scanned;
  const char *stop = st->base + end;
  while (p < stop && st->nlines < want_lines + 1) {
    const char *nl = (const char *)memchr(p, '\n', (size_t)(stop - p));
    if (!nl) { p = stop; break; }
    size_t next = (size_t)(nl - st->base) + 1;
    if (next < st->size) {           /* a newline at EOF does not start a line */
      if (st->nlines == st->cap) {
        size_t nc = st->cap * 2;
        size_t *no = (size_t *)realloc(st->offs, nc * sizeof(size_t));
        if (!no) { st->complete = 1; return; }
        st->offs = no; st->cap = nc;
      }
      st->offs[st->nlines++] = next;
    }
    p = nl + 1;
  }
  st->scanned = (size_t)(p - st->base);
  if (st->scanned >= st->size) st->complete = 1;
}

/* ---- background indexing on the libuv threadpool ---------------------------------------- */
static void work_cb(uv_work_t *w) {
  vstate *st = (vstate *)w->data;
  for (;;) {
    uv_mutex_lock(&st->mu);
    int done = st->complete || st->closing;
    if (!done) index_locked(st, (size_t)-2, CHUNK);
    uv_mutex_unlock(&st->mu);
    if (done) break;
  }
}
static void after_work_cb(uv_work_t *w, int status) {
  (void)status;
  vstate *st = (vstate *)w->data;
  uv_mutex_lock(&st->mu);
  st->job = 0;
  uv_mutex_unlock(&st->mu);
  vstate_unref(st);      /* the job's reference */
}

/* ---- open ---------------------------------------------------------------------------------- */
static vstate *vstate_open(const char *path, char *err, size_t errn) {
  vstate *st = (vstate *)calloc(1, sizeof(vstate));
  if (!st) { snprintf(err, errn, "out of memory"); return NULL; }
  uv_mutex_init(&st->mu);
  st->refs = 1;
  snprintf(st->path, sizeof(st->path), "%s", path);
#if defined(_WIN32)
  st->hfile = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (st->hfile == INVALID_HANDLE_VALUE) { snprintf(err, errn, "cannot open %s", path); uv_mutex_destroy(&st->mu); free(st); return NULL; }
  LARGE_INTEGER sz;
  GetFileSizeEx(st->hfile, &sz);
  st->size = (size_t)sz.QuadPart;
  if (st->size) {
    st->hmap = CreateFileMappingA(st->hfile, NULL, PAGE_READONLY, 0, 0, NULL);
    st->base = st->hmap ? (const char *)MapViewOfFile(st->hmap, FILE_MAP_READ, 0, 0, 0) : NULL;
    if (!st->base) { snprintf(err, errn, "cannot map %s", path); CloseHandle(st->hfile); uv_mutex_destroy(&st->mu); free(st); return NULL; }
    st->mapped = 1;
  } else { CloseHandle(st->hfile); }
#else
  int fd = open(path, O_RDONLY);
  if (fd < 0) { snprintf(err, errn, "cannot open %s", path); uv_mutex_destroy(&st->mu); free(st); return NULL; }
  struct stat sb;
  if (fstat(fd, &sb) != 0 || !S_ISREG(sb.st_mode)) {
    snprintf(err, errn, "%s is not a regular file", path);
    close(fd); uv_mutex_destroy(&st->mu); free(st); return NULL;
  }
  st->size = (size_t)sb.st_size;
  st->ino = (int64_t)sb.st_ino; st->dev = (int64_t)sb.st_dev;
  if (st->size) {
    void *m = mmap(NULL, st->size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (m == MAP_FAILED) {
      /* fallback: read it (pipes, odd filesystems) */
      char *buf = (char *)malloc(st->size);
      size_t got = 0;
      while (buf && got < st->size) { ssize_t r = read(fd, buf + got, st->size - got); if (r <= 0) break; got += (size_t)r; }
      if (!buf || got != st->size) { free(buf); snprintf(err, errn, "cannot read %s", path); close(fd); uv_mutex_destroy(&st->mu); free(st); return NULL; }
      st->base = buf; st->mapped = 0;
    } else {
      st->base = (const char *)m; st->mapped = 1;
#if defined(MADV_SEQUENTIAL)
      madvise(m, st->size, MADV_SEQUENTIAL);
#endif
    }
  }
  close(fd);   /* the mapping keeps the file alive */
#endif
  if (st->size == 0) st->complete = 1;
  return st;
}

static vstate *check(lua_State *L) {
  vud *u = (vud *)luaL_checkudata(L, 1, VIEW_MT);
  if (!u->st) luaL_error(L, "fileview: closed");
  return u->st;
}

/* Refuse to touch pages past a shrunk file's end (that is SIGBUS). */
static int shrunk(vstate *st) {
  if (!st->mapped) return 0;
#if defined(_WIN32)
  return 0;   /* a mapped file cannot be truncated while mapped on Windows */
#else
  struct stat sb;
  if (stat(st->path, &sb) != 0) return 0;            /* deleted: the mapping is still valid */
  if ((int64_t)sb.st_ino != st->ino || (int64_t)sb.st_dev != st->dev) return 0;   /* replaced: ours is the old inode */
  return (size_t)sb.st_size < st->size;
#endif
}
static void guard(lua_State *L, vstate *st) {
  if (shrunk(st)) luaL_error(L, "fileview: %s changed since it was opened (it shrank); open it again", st->path);
}

static int l_open(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  char err[1200];
  vstate *st = vstate_open(path, err, sizeof(err));
  if (!st) { lua_pushnil(L); lua_pushstring(L, err); return 2; }
  vud *u = (vud *)lua_newuserdatauv(L, sizeof(vud), 0);
  u->st = st;
  luaL_setmetatable(L, VIEW_MT);
  if (st->size < SYNC_INDEX_BELOW) {
    uv_mutex_lock(&st->mu);
    index_locked(st, (size_t)-2, 0);
    uv_mutex_unlock(&st->mu);
  } else {
    uv_loop_t *loop = luv_loop(L);
    if (loop) {
      uv_mutex_lock(&st->mu);
      st->refs++; st->job = 1;
      uv_mutex_unlock(&st->mu);
      st->work.data = st;
      if (uv_queue_work(loop, &st->work, work_cb, after_work_cb) != 0) {
        uv_mutex_lock(&st->mu); st->refs--; st->job = 0; uv_mutex_unlock(&st->mu);
      }
    }
  }
  return 1;
}

static int l_size(lua_State *L) { lua_pushinteger(L, (lua_Integer)check(L)->size); return 1; }

static int l_count(lua_State *L) {
  vstate *st = check(L);
  uv_mutex_lock(&st->mu);
  size_t n = st->nlines; int c = st->complete;
  uv_mutex_unlock(&st->mu);
  lua_pushinteger(L, (lua_Integer)n);
  lua_pushboolean(L, c);
  return 2;
}

static int l_wait(lua_State *L) {
  vstate *st = check(L);
  guard(L, st);
  uv_mutex_lock(&st->mu);
  index_locked(st, (size_t)-2, 0);
  size_t n = st->nlines;
  uv_mutex_unlock(&st->mu);
  lua_pushinteger(L, (lua_Integer)n);
  return 1;
}

/* the bytes of line i (1-based), or 0 if past the end; caller holds mu */
static int line_span(vstate *st, size_t i, size_t *a, size_t *b) {
  if (i < 1) return 0;
  if (i > st->nlines || (i == st->nlines && !st->complete)) index_locked(st, i, 0);
  if (i > st->nlines) return 0;
  *a = st->offs[i - 1];
  size_t e = (i < st->nlines) ? st->offs[i] - 1 : st->size;   /* exclude the "\n" */
  if (i == st->nlines && e > *a && e == st->size && st->base[e - 1] == '\n') e--;
  *b = e;
  return 1;
}

static int l_line(lua_State *L) {
  vstate *st = check(L);
  lua_Integer i = luaL_checkinteger(L, 2);
  guard(L, st);
  size_t a, b;
  uv_mutex_lock(&st->mu);
  int ok = i >= 1 && line_span(st, (size_t)i, &a, &b);
  uv_mutex_unlock(&st->mu);
  if (!ok) { lua_pushnil(L); return 1; }
  lua_pushlstring(L, st->base + a, b - a);
  return 1;
}

static int l_lines(lua_State *L) {
  vstate *st = check(L);
  lua_Integer i = luaL_checkinteger(L, 2), j = luaL_checkinteger(L, 3);
  if (i < 1) i = 1;
  guard(L, st);
  lua_newtable(L);
  for (lua_Integer k = i, n = 1; k <= j; k++, n++) {
    size_t a, b;
    uv_mutex_lock(&st->mu);
    int ok = line_span(st, (size_t)k, &a, &b);
    uv_mutex_unlock(&st->mu);
    if (!ok) break;
    lua_pushlstring(L, st->base + a, b - a);
    lua_rawseti(L, -2, n);
  }
  return 1;
}

/* last n lines, scanning backwards: no index needed (logs) */
static int l_tail(lua_State *L) {
  vstate *st = check(L);
  lua_Integer n = luaL_checkinteger(L, 2);
  guard(L, st);
  lua_createtable(L, n > 0 && n < 100000 ? (int)n : 0, 0);
  if (n <= 0 || st->size == 0) return 1;
  size_t end = st->size;
  if (st->base[end - 1] == '\n') end--;              /* a final newline ends the last line */
  /* collect starts from the end */
  size_t *starts = (size_t *)malloc((size_t)n * sizeof(size_t));
  size_t *ends = (size_t *)malloc((size_t)n * sizeof(size_t));
  if (!starts || !ends) { free(starts); free(ends); return luaL_error(L, "fileview: out of memory"); }
  lua_Integer got = 0;
  size_t e = end;
  for (;;) {
    size_t s = e;
    while (s > 0 && st->base[s - 1] != '\n') s--;
    starts[got] = s; ends[got] = e; got++;
    if (got == n || s == 0) break;
    e = s - 1;
  }
  for (lua_Integer k = 0; k < got; k++) {
    size_t idx = (size_t)(got - 1 - k);
    lua_pushlstring(L, st->base + starts[idx], ends[idx] - starts[idx]);
    lua_rawseti(L, -2, k + 1);
  }
  free(starts); free(ends);
  return 1;
}

static const char *memfind(const char *h, size_t hn, const char *n, size_t nn) {
  if (nn == 0) return h;
  if (nn > hn) return NULL;
  const char *last = h + hn - nn;
  for (const char *p = h; p <= last; ) {
    const char *q = (const char *)memchr(p, n[0], (size_t)(last - p) + 1);
    if (!q) return NULL;
    if (memcmp(q, n, nn) == 0) return q;
    p = q + 1;
  }
  return NULL;
}

/* -> line, column (1-based) of the first occurrence at or after from_line */
static int l_find(lua_State *L) {
  vstate *st = check(L);
  size_t nn;
  const char *needle = luaL_checklstring(L, 2, &nn);
  lua_Integer from = luaL_optinteger(L, 3, 1);
  guard(L, st);
  size_t start = 0, a, b;
  uv_mutex_lock(&st->mu);
  if (from > 1 && line_span(st, (size_t)from, &a, &b)) start = a;
  uv_mutex_unlock(&st->mu);
  const char *hit = memfind(st->base + start, st->size - start, needle, nn);
  if (!hit) { lua_pushnil(L); return 1; }
  size_t off = (size_t)(hit - st->base);
  /* line number: index up to the hit, then binary search */
  uv_mutex_lock(&st->mu);
  while (!st->complete && st->scanned <= off) index_locked(st, (size_t)-2, CHUNK);
  size_t lo = 0, hi = st->nlines;
  while (hi - lo > 1) { size_t mid = (lo + hi) / 2; if (st->offs[mid] <= off) lo = mid; else hi = mid; }
  size_t col = off - st->offs[lo] + 1;
  uv_mutex_unlock(&st->mu);
  lua_pushinteger(L, (lua_Integer)lo + 1);
  lua_pushinteger(L, (lua_Integer)col);
  return 2;
}

static int l_stale(lua_State *L) { lua_pushboolean(L, shrunk(check(L))); return 1; }

static int l_close(lua_State *L) {
  vud *u = (vud *)luaL_checkudata(L, 1, VIEW_MT);
  if (u->st) {
    vstate *st = u->st;
    u->st = NULL;
    uv_mutex_lock(&st->mu); st->closing = 1; uv_mutex_unlock(&st->mu);
    vstate_unref(st);
  }
  return 0;
}

static int l_tostring(lua_State *L) {
  vud *u = (vud *)luaL_checkudata(L, 1, VIEW_MT);
  if (!u->st) lua_pushliteral(L, "fileview (closed)");
  else lua_pushfstring(L, "fileview %s (%I bytes)", u->st->path, (lua_Integer)u->st->size);
  return 1;
}

int luaopen_boggart_fileview(lua_State *L) {
  static const luaL_Reg m[] = {
    { "size", l_size }, { "count", l_count }, { "wait", l_wait }, { "line", l_line }, { "lines", l_lines },
    { "tail", l_tail }, { "find", l_find }, { "stale", l_stale }, { "close", l_close }, { NULL, NULL } };
  if (luaL_newmetatable(L, VIEW_MT)) {
    luaL_newlib(L, m);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, l_close); lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, l_close); lua_setfield(L, -2, "__close");
    lua_pushcfunction(L, l_tostring); lua_setfield(L, -2, "__tostring");
  }
  lua_pop(L, 1);
  static const luaL_Reg f[] = { { "open", l_open }, { NULL, NULL } };
  luaL_newlib(L, f);
  return 1;
}
