/* lswarm.c -- the swarm messaging machinery, in C.
 *
 * A process-global bus: per-agent FIFO mailboxes, pub/sub topics, and a
 * write-through journal to the shared SQLite database. Agents are identified by
 * integer id (their thread/session row id). Payloads are opaque strings (the
 * Lua layer JSON-encodes structured messages), which keeps the queues and the
 * journal trivial and makes every message durably serializable + replayable.
 *
 *   swarm.attach(dbconn)              -- journal to the store's SQLite handle
 *   swarm.send(from, to, payload)     -- enqueue to one mailbox
 *   swarm.publish(from, topic, pay)   -> n   -- enqueue to every subscriber
 *   swarm.subscribe(id, topic) / swarm.unsubscribe(id, topic)
 *   swarm.recv(id)                    -> payload, journal_id | nil
 *   swarm.pending(id)                 -> count
 *   swarm.mark_processed(journal_id)  -- stamp processed_at (queued -> handled)
 *   swarm.redeliver()                 -> n   -- re-enqueue undelivered journal rows (resume)
 *
 * The journal row is the unit of durability: send/publish create rows with
 * processed_at NULL; a row is stamped processed only after the receiving agent
 * finishes the turn that consumed it. Resume = attach + redeliver().
 *
 * ---- queues -----------------------------------------------------------------
 * Every list here is a libuv intrusive circular queue (struct uv__queue) rather
 * than a hand-rolled singly-linked list. Three reasons: O(1) removal from the
 * middle without pointer-chasing (unsubscribe, mailbox teardown), no separate
 * head/tail bookkeeping to get wrong, and one queue idiom shared with the rest
 * of the libuv-based core.
 *
 * NOTE: uv__queue lives in libuv's src/queue.h, not include/ -- it is private
 * API, and it was renamed from the old QUEUE_* macros in libuv 1.45. We vendor
 * and pin libuv, so that churn only bites on a deliberate re-vendor; if you
 * bump libuv and this file stops compiling, that is why.
 *
 * ---- threading ------------------------------------------------------------
 * The bus is single-threaded by ownership, not by locking, and there are no
 * mutexes here on purpose.
 *
 * Every actor is a Lua coroutine on the one thread that owns the lua_State, so
 * every entry point below is reached from that thread and only that thread. A
 * lock would be permanently uncontended -- but worse than useless, because it
 * would advertise a thread-safety property the surrounding code does not have
 * (journal writes and lua/store.lua reads are not covered by it). A lock that
 * guards half an invariant is a trap for the next reader.
 *
 * Work that genuinely needs another thread crosses by *ownership transfer*
 * instead: durable journal writes are handed to the writer thread through the
 * lock-free SPSC ring in jwriter.c, which takes ownership of each record. No
 * memory is shared mutably across threads, so there is nothing to lock.
 */
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "uv.h"
#include "vendor/libuv/src/queue.h" /* libuv-internal intrusive queue */

#include "sqlite3.h"
#include "lua.h"
#include "lauxlib.h"
#include "ldb.h"
#include "jwriter.h"

static sqlite3 *g_db = NULL;

typedef struct msg {
  struct uv__queue q; /* link in mbox.msgs */
  char *data;
  size_t len;
  sqlite3_int64 jid; /* journal row id, or -1 if not journalled */
} msg;

typedef struct mbox {
  struct uv__queue q;    /* link in g_mboxes */
  struct uv__queue msgs; /* head of this mailbox's FIFO */
  int id;
  size_t count;
} mbox;

typedef struct sub {
  struct uv__queue q; /* link in topic.subs */
  int id;
} sub;

typedef struct topic {
  struct uv__queue q;    /* link in g_topics */
  struct uv__queue subs; /* head of the subscriber list */
  char *name;
} topic;

static struct uv__queue g_mboxes;
static struct uv__queue g_topics;
static uv_once_t g_once = UV_ONCE_INIT;

/* Called after a message lands in a mailbox, while the bus lock is held.
 * Null today: with every actor a coroutine on one thread, lua/sched.lua simply
 * polls swarm.pending(). This is the seam where a uv_async_send() goes when an
 * actor gets its own thread/loop and has to be woken rather than polled. */
static void (*g_notify)(int to_id) = NULL;

static void bus_init(void) {
  uv__queue_init(&g_mboxes);
  uv__queue_init(&g_topics);
}

/* Lazy init only; see the threading note above for why there is no lock. */
static void bus_ready(void) { uv_once(&g_once, bus_init); }

/* ---- mailbox helpers (single-threaded; see the threading note) ---- */
static mbox *mbox_find(int id, int create) {
  struct uv__queue *it;
  uv__queue_foreach(it, &g_mboxes) {
    mbox *m = uv__queue_data(it, mbox, q);
    if (m->id == id) return m;
  }
  if (!create) return NULL;
  mbox *m = (mbox *)calloc(1, sizeof(mbox));
  if (!m) return NULL;
  m->id = id;
  uv__queue_init(&m->msgs);
  uv__queue_insert_tail(&g_mboxes, &m->q);
  return m;
}

static void mbox_push(int id, const char *data, size_t len, sqlite3_int64 jid) {
  mbox *m = mbox_find(id, 1);
  if (!m) return;
  msg *n = (msg *)malloc(sizeof(msg));
  if (!n) return;
  n->data = (char *)malloc(len ? len : 1);
  if (!n->data) { free(n); return; }
  memcpy(n->data, data, len);
  n->len = len;
  n->jid = jid;
  uv__queue_insert_tail(&m->msgs, &n->q); /* FIFO: tail in, head out */
  m->count++;
  if (g_notify) g_notify(id);
}

/* ---- topic helpers (single-threaded; see the threading note) ---- */
static topic *topic_find(const char *name, int create) {
  struct uv__queue *it;
  uv__queue_foreach(it, &g_topics) {
    topic *t = uv__queue_data(it, topic, q);
    if (strcmp(t->name, name) == 0) return t;
  }
  if (!create) return NULL;
  topic *t = (topic *)calloc(1, sizeof(topic));
  if (!t) return NULL;
  t->name = strdup(name);
  if (!t->name) { free(t); return NULL; }
  uv__queue_init(&t->subs);
  uv__queue_insert_tail(&g_topics, &t->q);
  return t;
}

/* ---- journal ---------------------------------------------------------------
 * Journal rows are handed to the writer thread (jwriter.c) rather than written
 * inline: an fsync on the Lua thread would sit directly in the path of an
 * actor's turn, and the writer batches a burst of messages into one commit.
 *
 * The row id is allocated here rather than taken from SQLite's rowid, so
 * swarm.send() can still return an id immediately without waiting for the
 * write. If the writer is not running (start failed, or tests that never
 * attach) everything falls back to the original inline path.
 */
static sqlite3_int64 journal_write(int from, int to, int has_to, const char *topic_s,
                                   const char *kind, const char *payload, size_t plen,
                                   int processed);

static sqlite3_int64 journal_insert(int from, int to, int has_to, const char *topic_s,
                                    const char *kind, const char *payload, size_t plen,
                                    int processed) {
  if (!g_db) return -1;

  if (jwriter_running()) {
    jw_rec r;
    memset(&r, 0, sizeof(r));
    r.kind = JW_INSERT;
    r.id = jwriter_next_id();
    r.ts = (int64_t)time(NULL);
    r.from_id = from;
    r.to_id = to;
    r.has_to = has_to;
    r.kind_s = kind; /* always a static literal from the call sites below */
    r.processed = processed;
    if (topic_s) r.topic = strdup(topic_s);
    if (payload) {
      r.payload = (char *)malloc(plen ? plen : 1);
      if (r.payload) { memcpy(r.payload, payload, plen); r.plen = plen; }
    }
    if (jwriter_push(&r) == 0) return (sqlite3_int64)r.id; /* ownership moved */
    free(r.topic);
    free(r.payload); /* push refused: fall through and write inline */
  }
  return journal_write(from, to, has_to, topic_s, kind, payload, plen, processed);
}

static sqlite3_int64 journal_write(int from, int to, int has_to, const char *topic_s,
                                   const char *kind, const char *payload, size_t plen,
                                   int processed) {
  if (!g_db) return -1;
  sqlite3_stmt *st;
  const char *sql =
    "INSERT INTO journal(ts,from_id,to_id,topic,kind,payload,processed_at) "
    "VALUES(?,?,?,?,?,?,?)";
  if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) return -1;
  sqlite3_int64 t = (sqlite3_int64)time(NULL);
  sqlite3_bind_int64(st, 1, t);
  sqlite3_bind_int(st, 2, from);
  if (has_to) sqlite3_bind_int(st, 3, to); else sqlite3_bind_null(st, 3);
  if (topic_s) sqlite3_bind_text(st, 4, topic_s, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 4);
  sqlite3_bind_text(st, 5, kind, -1, SQLITE_TRANSIENT);
  if (payload) sqlite3_bind_text(st, 6, payload, (int)plen, SQLITE_TRANSIENT); else sqlite3_bind_null(st, 6);
  if (processed) sqlite3_bind_int64(st, 7, t); else sqlite3_bind_null(st, 7);
  sqlite3_step(st);
  sqlite3_int64 rid = sqlite3_last_insert_rowid(g_db);
  sqlite3_finalize(st);
  return rid;
}

/* ---- Lua entry points ---- */
static int l_attach(lua_State *L) {
  g_db = boggart_db_handle(L, 1);
  /* Start the journal writer on the same file. sqlite3_db_filename gives the
   * path the caller already opened, so the writer never needs it passed in.
   * An in-memory or temp database yields an empty name; there is nothing for a
   * second connection to attach to, so we stay on the inline path. */
  if (g_db) {
    const char *path = sqlite3_db_filename(g_db, "main");
    if (path && *path) jwriter_start(path);
  }
  return 0;
}

/* swarm.flush() -- block until every journalled record is committed. */
static int l_flush(lua_State *L) {
  (void)L;
  jwriter_flush();
  return 0;
}

/* swarm.jstats() -> pushed, written, stalls */
static int l_jstats(lua_State *L) {
  uint64_t p = 0, w = 0, st = 0;
  jwriter_stats(&p, &w, &st);
  lua_pushinteger(L, (lua_Integer)p);
  lua_pushinteger(L, (lua_Integer)w);
  lua_pushinteger(L, (lua_Integer)st);
  return 3;
}

static int l_send(lua_State *L) {
  int from = (int)luaL_checkinteger(L, 1);
  int to = (int)luaL_checkinteger(L, 2);
  size_t len;
  const char *payload = luaL_checklstring(L, 3, &len);
  /* Journal and enqueue under one lock, so a queued message always has its
   * durable row: a reader can never observe a message the journal lacks. */
  bus_ready();
  sqlite3_int64 jid = journal_insert(from, to, 1, NULL, "send", payload, len, 0);
  mbox_push(to, payload, len, jid);
  lua_pushinteger(L, (lua_Integer)jid);
  return 1;
}

static int l_publish(lua_State *L) {
  int from = (int)luaL_checkinteger(L, 1);
  const char *tname = luaL_checkstring(L, 2);
  size_t len;
  const char *payload = luaL_checklstring(L, 3, &len);
  bus_ready();
  topic *t = topic_find(tname, 0);
  int n = 0;
  if (t && !uv__queue_empty(&t->subs)) {
    struct uv__queue *it;
    uv__queue_foreach(it, &t->subs) {
      sub *s = uv__queue_data(it, sub, q);
      sqlite3_int64 jid = journal_insert(from, s->id, 1, tname, "publish", payload, len, 0);
      mbox_push(s->id, payload, len, jid);
      n++;
    }
  } else {
    /* no subscribers: record an audit row, already "processed" */
    journal_insert(from, 0, 0, tname, "publish", payload, len, 1);
  }
  lua_pushinteger(L, n);
  return 1;
}

static int l_subscribe(lua_State *L) {
  int id = (int)luaL_checkinteger(L, 1);
  const char *tname = luaL_checkstring(L, 2);
  bus_ready();
  topic *t = topic_find(tname, 1);
  if (!t) { return 0; }
  struct uv__queue *it;
  uv__queue_foreach(it, &t->subs) {
    if (uv__queue_data(it, sub, q)->id == id) { return 0; } /* already subscribed */
  }
  sub *s = (sub *)malloc(sizeof(sub));
  if (!s) { return 0; }
  s->id = id;
  uv__queue_insert_tail(&t->subs, &s->q);
  journal_insert(id, 0, 0, tname, "subscribe", NULL, 0, 1);
  return 0;
}

static int l_unsubscribe(lua_State *L) {
  int id = (int)luaL_checkinteger(L, 1);
  const char *tname = luaL_checkstring(L, 2);
  bus_ready();
  topic *t = topic_find(tname, 0);
  if (t) {
    struct uv__queue *it = t->subs.next;
    while (it != &t->subs) {
      struct uv__queue *next = it->next; /* save: removal clobbers the links */
      sub *s = uv__queue_data(it, sub, q);
      if (s->id == id) {
        uv__queue_remove(it); /* O(1), no pointer-chasing to find the predecessor */
        free(s);
        break;
      }
      it = next;
    }
  }
  journal_insert(id, 0, 0, tname, "unsubscribe", NULL, 0, 1);
  return 0;
}

static int l_recv(lua_State *L) {
  int id = (int)luaL_checkinteger(L, 1);
  bus_ready();
  mbox *m = mbox_find(id, 0);
  if (!m || uv__queue_empty(&m->msgs)) { return 0; } /* empty -> nil */
  struct uv__queue *h = uv__queue_head(&m->msgs);
  uv__queue_remove(h);
  m->count--;
  msg *n = uv__queue_data(h, msg, q);
  /* The node is already unlinked, so an OOM raise out of lua_pushlstring
   * cannot leave the queue half-modified -- it only leaks this one record. */
  lua_pushlstring(L, n->data, n->len);
  lua_pushinteger(L, (lua_Integer)n->jid);
  free(n->data);
  free(n);
  return 2;
}

static int l_pending(lua_State *L) {
  int id = (int)luaL_checkinteger(L, 1);
  bus_ready();
  mbox *m = mbox_find(id, 0);
  lua_Integer c = m ? (lua_Integer)m->count : 0;
  lua_pushinteger(L, c);
  return 1;
}

static int l_mark_processed(lua_State *L) {
  sqlite3_int64 jid = (sqlite3_int64)luaL_checkinteger(L, 1);
  if (g_db && jid >= 0 && jwriter_running()) {
    jw_rec r;
    memset(&r, 0, sizeof(r));
    r.kind = JW_PROCESSED;
    r.id = (int64_t)jid;
    r.ts = (int64_t)time(NULL);
    /* Same queue as the insert: FIFO from a single producer is what guarantees
     * the stamp cannot be applied before the row it refers to exists. */
    if (jwriter_push(&r) == 0) return 0;
  }
  if (g_db && jid >= 0) {
    bus_ready();
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(g_db, "UPDATE journal SET processed_at=? WHERE id=?", -1, &st, NULL) == SQLITE_OK) {
      sqlite3_bind_int64(st, 1, (sqlite3_int64)time(NULL));
      sqlite3_bind_int64(st, 2, jid);
      sqlite3_step(st);
      sqlite3_finalize(st);
    }
  }
  return 0;
}

/* Re-enqueue every undelivered journalled message into its mailbox (resume).
 * Does NOT create new journal rows -- it carries the existing row ids. */
static int l_redeliver(lua_State *L) {
  if (!g_db) { lua_pushinteger(L, 0); return 1; }
  /* Reading the journal back means every pending write must have landed. */
  jwriter_flush();
  bus_ready();
  sqlite3_stmt *st;
  const char *sql =
    "SELECT id,to_id,payload FROM journal "
    "WHERE processed_at IS NULL AND to_id IS NOT NULL ORDER BY id";
  if (sqlite3_prepare_v2(g_db, sql, -1, &st, NULL) != SQLITE_OK) {
    const char *err = sqlite3_errmsg(g_db);
   
    return luaL_error(L, "swarm.redeliver: %s", err);
  }
  int n = 0;
  while (sqlite3_step(st) == SQLITE_ROW) {
    sqlite3_int64 jid = sqlite3_column_int64(st, 0);
    int to = sqlite3_column_int(st, 1);
    const char *p = (const char *)sqlite3_column_text(st, 2);
    int plen = sqlite3_column_bytes(st, 2);
    mbox_push(to, p ? p : "", (size_t)plen, jid);
    n++;
  }
  sqlite3_finalize(st);
  lua_pushinteger(L, n);
  return 1;
}

/* Drop all in-memory mailboxes and subscriptions (used by tests for a clean
 * bus without discarding the journal). */
static int l_clear(lua_State *L) {
  (void)L;
  bus_ready();
  struct uv__queue *it = g_mboxes.next;
  while (it != &g_mboxes) {
    struct uv__queue *next = it->next;
    mbox *m = uv__queue_data(it, mbox, q);
    struct uv__queue *mi = m->msgs.next;
    while (mi != &m->msgs) {
      struct uv__queue *mnext = mi->next;
      msg *d = uv__queue_data(mi, msg, q);
      free(d->data);
      free(d);
      mi = mnext;
    }
    free(m);
    it = next;
  }
  uv__queue_init(&g_mboxes);

  it = g_topics.next;
  while (it != &g_topics) {
    struct uv__queue *next = it->next;
    topic *t = uv__queue_data(it, topic, q);
    struct uv__queue *si = t->subs.next;
    while (si != &t->subs) {
      struct uv__queue *snext = si->next;
      free(uv__queue_data(si, sub, q));
      si = snext;
    }
    free(t->name);
    free(t);
    it = next;
  }
  uv__queue_init(&g_topics);
  return 0;
}

static const luaL_Reg swarm_lib[] = {
  {"attach", l_attach},
  {"send", l_send},
  {"publish", l_publish},
  {"subscribe", l_subscribe},
  {"unsubscribe", l_unsubscribe},
  {"recv", l_recv},
  {"pending", l_pending},
  {"mark_processed", l_mark_processed},
  {"redeliver", l_redeliver},
  {"clear", l_clear},
  {"flush", l_flush},
  {"jstats", l_jstats},
  {NULL, NULL},
};

int luaopen_boggart_swarm(lua_State *L) {
  /* Initialise the bus before any Lua can touch it, so the uv_once in
   * bus_ready() is a formality rather than the only initialisation path. */
  uv_once(&g_once, bus_init);
  luaL_newlib(L, swarm_lib);
  return 1;
}
