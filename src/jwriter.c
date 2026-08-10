/* jwriter.c -- see jwriter.h for the design. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "uv.h"
#include "sqlite3.h"
#include "jwriter.h"

/* ---- why there are no atomics here ----------------------------------------
 * This is a bounded SPSC buffer, and the two counting semaphores provide all
 * the memory ordering it needs: uv_sem_post/uv_sem_wait is a happens-before
 * edge, so everything the producer wrote into a slot before posting `items` is
 * visible to the consumer after it waits on `items`, and vice versa for
 * `space`. Nothing else is shared.
 *
 * The lock-free alternative -- publishing a head index with a release store --
 * would need real acquire/release atomics: on a weakly ordered machine (arm64,
 * i.e. this one, and Windows-on-ARM) the index update can otherwise become
 * visible before the slot contents it publishes, which is the classic bug that
 * looks fine on x86 and corrupts on ARM. It would also need a portable atomics
 * shim, because MSVC's <stdatomic.h> support is version- and flag-dependent.
 *
 * Semaphores cost a (usually uncontended, userspace-fast-path) call per record
 * instead of a store. At journal rates that is not measurable, and it buys a
 * design with no memory-ordering reasoning in it at all.
 *
 * g_head is touched only by the producer, g_tail only by the consumer, so
 * neither is shared and neither needs protecting.
 */

#define JW_CAP  8192u          /* power of two: the wrap is a mask */
#define JW_MASK (JW_CAP - 1u)
#define JW_BATCH 4096u         /* max records per transaction */

static jw_rec *g_slots = NULL;
static uint32_t g_head = 0;    /* producer only */
static uint32_t g_tail = 0;    /* consumer only */

static uv_sem_t g_space;       /* free slots; producer waits */
static uv_sem_t g_items;       /* filled slots; consumer waits */
static uv_sem_t g_flush_done;  /* consumer posts when a JW_FLUSH is committed */
static uv_thread_t g_thread;

static sqlite3 *g_wdb = NULL;  /* the writer thread's own connection */
static char g_path[4096];
static int g_running = 0;

/* Diagnostics only. Each is written by exactly one thread; reading the other's
 * counter is a benign race and never used for control flow. */
static uint64_t g_pushed = 0;  /* producer */
static uint64_t g_written = 0; /* consumer */
static uint64_t g_stalls = 0;  /* producer: times the ring was full */

static int64_t g_next_id = 0;  /* producer-only: no atomic needed */

/* ---- producer side (the Lua thread) ---------------------------------------- */

int jwriter_running(void) { return g_running; }

int64_t jwriter_next_id(void) { return ++g_next_id; }

int jwriter_push(const jw_rec *rec) {
  if (!g_running || !g_slots) return -1;

  /* Reserve a slot. A full ring means the writer is more than JW_CAP records
   * behind; block rather than drop, because a dropped record is a lost journal
   * row and the journal is the durability story. g_stalls records that it
   * happened at all. */
  if (uv_sem_trywait(&g_space) != 0) {
    g_stalls++;
    uv_sem_wait(&g_space);
  }

  g_slots[g_head & JW_MASK] = *rec; /* ownership of topic/payload moves here */
  g_head++;
  /* Data records only. Counting the FLUSH/STOP sentinels here would make
   * `pushed` and `written` permanently disagree by however many flushes have
   * happened, which is exactly the sort of counter nobody can then trust. */
  if (rec->kind == JW_INSERT || rec->kind == JW_PROCESSED) g_pushed++;
  uv_sem_post(&g_items); /* publishes the slot write to the consumer */
  return 0;
}

/* ---- consumer side (the writer thread) ------------------------------------- */

static void rec_free(jw_rec *r) {
  free(r->topic);
  free(r->payload);
  r->topic = NULL;
  r->payload = NULL;
}

/* Take everything currently available (up to JW_BATCH) and commit it in one
 * transaction. Batching is the point: one commit per burst rather than one per
 * message is where most of the win over inline writing comes from. */
static void drain_batch(int *saw_stop, int *saw_flush) {
  uint32_t n = 1; /* the caller already consumed one from g_items */
  while (n < JW_BATCH && uv_sem_trywait(&g_items) == 0) n++;

  sqlite3_stmt *ins = NULL, *upd = NULL;
  if (g_wdb) {
    sqlite3_prepare_v2(g_wdb,
      "INSERT OR REPLACE INTO journal(id,ts,from_id,to_id,topic,kind,payload,processed_at) "
      "VALUES(?,?,?,?,?,?,?,?)", -1, &ins, NULL);
    sqlite3_prepare_v2(g_wdb,
      "UPDATE journal SET processed_at=? WHERE id=?", -1, &upd, NULL);
    sqlite3_exec(g_wdb, "BEGIN IMMEDIATE", NULL, NULL, NULL);
  }

  for (uint32_t i = 0; i < n; i++) {
    jw_rec *r = &g_slots[g_tail & JW_MASK];

    if (r->kind == JW_STOP) {
      *saw_stop = 1;
    } else if (r->kind == JW_FLUSH) {
      *saw_flush = 1;
    } else if (g_wdb && ins && upd) {
      if (r->kind == JW_INSERT) {
        sqlite3_reset(ins);
        sqlite3_bind_int64(ins, 1, r->id);
        sqlite3_bind_int64(ins, 2, r->ts);
        sqlite3_bind_int(ins, 3, r->from_id);
        if (r->has_to) sqlite3_bind_int(ins, 4, r->to_id); else sqlite3_bind_null(ins, 4);
        if (r->topic) sqlite3_bind_text(ins, 5, r->topic, -1, SQLITE_TRANSIENT);
        else sqlite3_bind_null(ins, 5);
        sqlite3_bind_text(ins, 6, r->kind_s ? r->kind_s : "", -1, SQLITE_STATIC);
        if (r->payload) sqlite3_bind_text(ins, 7, r->payload, (int)r->plen, SQLITE_TRANSIENT);
        else sqlite3_bind_null(ins, 7);
        if (r->processed) sqlite3_bind_int64(ins, 8, r->ts); else sqlite3_bind_null(ins, 8);
        sqlite3_step(ins);
      } else { /* JW_PROCESSED */
        sqlite3_reset(upd);
        sqlite3_bind_int64(upd, 1, r->ts);
        sqlite3_bind_int64(upd, 2, r->id);
        sqlite3_step(upd);
      }
      g_written++;
    }

    rec_free(r);
    g_tail++;
    uv_sem_post(&g_space); /* the slot is reusable */
  }

  if (g_wdb) {
    sqlite3_exec(g_wdb, "COMMIT", NULL, NULL, NULL);
    sqlite3_finalize(ins);
    sqlite3_finalize(upd);
  }
}

static void writer_main(void *arg) {
  (void)arg;
  /* The writer's own connection: legal alongside the Lua thread's because the
   * database is in WAL mode and SQLite is built THREADSAFE=2. */
  if (sqlite3_open(g_path, &g_wdb) != SQLITE_OK) { sqlite3_close(g_wdb); g_wdb = NULL; }
  if (g_wdb) {
    sqlite3_busy_timeout(g_wdb, 5000);
    sqlite3_exec(g_wdb, "PRAGMA journal_mode=WAL", NULL, NULL, NULL);
    sqlite3_exec(g_wdb, "PRAGMA synchronous=NORMAL", NULL, NULL, NULL);
  }

  /* No uv_loop here on purpose: with nothing to multiplex, blocking on a
   * semaphore is both simpler and cheaper than a loop woken by uv_async, and
   * it is what lets the whole thing avoid atomics. */
  for (;;) {
    uv_sem_wait(&g_items);
    int stop = 0, flush = 0;
    drain_batch(&stop, &flush);
    if (flush) uv_sem_post(&g_flush_done);
    if (stop) break;
  }

  if (g_wdb) { sqlite3_close(g_wdb); g_wdb = NULL; }
}

/* ---- lifecycle ------------------------------------------------------------- */

static int push_control(jw_kind k) {
  jw_rec r;
  memset(&r, 0, sizeof(r));
  r.kind = k;
  return jwriter_push(&r);
}

int jwriter_start(const char *db_path) {
  if (g_running) return 0;
  if (!db_path || !*db_path) return -1;
  snprintf(g_path, sizeof(g_path), "%s", db_path);

  g_slots = (jw_rec *)calloc(JW_CAP, sizeof(jw_rec));
  if (!g_slots) return -1;

  /* Seed the id allocator past whatever is on disk so ids stay unique across
   * restarts. Done here, before the writer thread exists. */
  sqlite3 *tmp = NULL;
  if (sqlite3_open(g_path, &tmp) == SQLITE_OK) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(tmp, "SELECT IFNULL(MAX(id),0) FROM journal", -1, &st, NULL) == SQLITE_OK) {
      if (sqlite3_step(st) == SQLITE_ROW) g_next_id = sqlite3_column_int64(st, 0);
      sqlite3_finalize(st);
    }
  }
  sqlite3_close(tmp);

  g_head = g_tail = 0;
  if (uv_sem_init(&g_space, JW_CAP) != 0) { free(g_slots); g_slots = NULL; return -1; }
  if (uv_sem_init(&g_items, 0) != 0) { uv_sem_destroy(&g_space); free(g_slots); g_slots = NULL; return -1; }
  if (uv_sem_init(&g_flush_done, 0) != 0) {
    uv_sem_destroy(&g_space); uv_sem_destroy(&g_items);
    free(g_slots); g_slots = NULL; return -1;
  }

  /* Flush and join on normal exit. Without this, records sitting in the ring
   * when main() returns are silently lost -- which would make the journal's
   * durability guarantee a lie exactly when it matters (a clean shutdown). */
  atexit(jwriter_stop);

  g_running = 1;
  if (uv_thread_create(&g_thread, writer_main, NULL) != 0) {
    g_running = 0;
    uv_sem_destroy(&g_space); uv_sem_destroy(&g_items); uv_sem_destroy(&g_flush_done);
    free(g_slots); g_slots = NULL;
    return -1;
  }
  return 0;
}

void jwriter_flush(void) {
  if (!g_running) return;
  /* A sentinel rather than a counter comparison: FIFO order guarantees every
   * record pushed before it is committed in the same batch or an earlier one,
   * so waiting for its acknowledgement is exactly "everything so far is
   * durable" -- with no cross-thread counters to reason about. */
  if (push_control(JW_FLUSH) != 0) return;
  uv_sem_wait(&g_flush_done);
}

void jwriter_stop(void) {
  if (!g_running) return;
  jwriter_flush();
  push_control(JW_STOP);
  uv_thread_join(&g_thread);
  g_running = 0;
  uv_sem_destroy(&g_space);
  uv_sem_destroy(&g_items);
  uv_sem_destroy(&g_flush_done);
  free(g_slots);
  g_slots = NULL;
}

void jwriter_stats(uint64_t *pushed, uint64_t *written, uint64_t *stalls) {
  if (pushed) *pushed = g_pushed;
  if (written) *written = g_written;
  if (stalls) *stalls = g_stalls;
}
