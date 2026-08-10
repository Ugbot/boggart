/* jwriter.h -- the journal writer: a lock-free SPSC ring feeding a dedicated
 * writer thread that owns the only SQLite connection used for journal writes.
 *
 * Why: every swarm send/publish appends a durable journal row. Doing that
 * inline on the Lua thread puts an fsync (and, under contention, a wait for
 * the database write lock) directly in the path of an actor's turn. The
 * journal is append-only and nobody reads their own write back synchronously,
 * which is exactly the shape a producer/consumer ring is for.
 *
 * Threading model -- ownership, not locking:
 *   producer = the Lua thread. Allocates a record, fills it, publishes it.
 *   consumer = the writer thread. Takes ownership, writes it, frees it.
 * One producer, one consumer, a fixed power-of-two ring, and two counting
 * semaphores (free slots / filled slots). No mutex and no atomics: each record
 * belongs to exactly one thread at a time, the head index is touched only by
 * the producer and the tail only by the consumer, and uv_sem_post/uv_sem_wait
 * supplies the happens-before edge that makes the slot contents visible.
 *
 * The writer thread has no uv_loop_t. It has nothing to multiplex -- no
 * sockets, no timers, no child processes -- so it simply blocks on the `items`
 * semaphore, which is cheaper than a loop woken by uv_async and is what lets
 * the design avoid memory-ordering reasoning entirely.
 *
 * It opens its *own* SQLite connection to the same file -- legal because the
 * database is in WAL mode (concurrent reader + writer) and SQLite is built
 * THREADSAFE=2 (safe across threads as long as one connection is not shared).
 *
 * Durability: a record is durable once the writer commits, not when the
 * producer publishes it. jwriter_flush() closes that window and is called
 * before anything reads the journal back (resume/redeliver) and at shutdown.
 */
#ifndef BOGGART_JWRITER_H
#define BOGGART_JWRITER_H

#include <stddef.h>
#include <stdint.h>

/* What the writer should do with a record. Both ride the same ring so that a
 * "processed" stamp can never overtake the insert it refers to -- FIFO order
 * from a single producer is what guarantees that. */
typedef enum {
  JW_INSERT = 0,    /* append a journal row */
  JW_PROCESSED = 1, /* stamp processed_at on an existing row */
  JW_FLUSH = 2,     /* control: acknowledge once everything before it is committed */
  JW_STOP = 3       /* control: last record; the writer thread exits after it */
} jw_kind;

typedef struct {
  jw_kind kind;
  int64_t id;       /* journal row id, allocated by the producer */
  int64_t ts;
  int from_id, to_id, has_to;
  char *topic;      /* owned by the record, or NULL */
  const char *kind_s; /* static literal ("send"/"publish"/...), not owned */
  char *payload;    /* owned by the record, or NULL */
  size_t plen;
  int processed;    /* insert already-processed (audit rows) */
} jw_rec;

/* Start the writer thread against `db_path`. Idempotent. Returns 0, or -1 with
 * the journal left in inline (synchronous) mode -- never fatal. */
int jwriter_start(const char *db_path);

/* Is the writer thread up? When false every caller must write inline. */
int jwriter_running(void);

/* Allocate the next journal row id. Ids are handed out by the producer rather
 * than by SQLite's rowid, so swarm.send() can return one immediately without
 * waiting for the write. Seeded from MAX(id) at startup. */
int64_t jwriter_next_id(void);

/* Publish a record; takes ownership of rec->topic and rec->payload. Returns 0
 * on success, -1 if the writer is not running (caller should write inline). */
int jwriter_push(const jw_rec *rec);

/* Block until every published record has been committed. */
void jwriter_flush(void);

/* Flush, stop the thread, close the writer's connection. Idempotent. */
void jwriter_stop(void);

/* Diagnostics: records published, records committed, times the producer had to
 * wait on a full ring. A non-zero stall count means the writer cannot keep up. */
void jwriter_stats(uint64_t *pushed, uint64_t *written, uint64_t *stalls);

#endif /* BOGGART_JWRITER_H */
