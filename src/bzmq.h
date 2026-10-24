/* bzmq.h -- the ZeroMQ plumbing shared by src/lzmq.c (the Lua `zmq` module)
 * and src/lstation.c (the LLM Station DEALER). Only meaningful when built with
 * BOGGART_ZMQ (libzmq linked); the declarations are harmless otherwise.
 *
 *   one zmq context per interpreter, in the registry; its __gc runs every
 *   tracked owner's closer before zmq_ctx_term (term blocks until every socket
 *   is closed, and __gc order is undefined -- this keeps lua_close from hanging)
 *
 *   a watch parks a socket's ZMQ_FD on the interpreter's uv loop. ZMQ_FD is
 *   edge-triggered and readiness does not imply a message, so after every wake
 *   the watch calls ready(), then re-checks ZMQ_EVENTS until no POLLIN. A
 *   ready() that returns non-zero (it stopped early to stay fair) is resumed
 *   from a zero-delay timer instead. bzmq_watch_kick() schedules the same
 *   thing: a send can consume the edge for messages already queued, so a
 *   sender that also receives kicks after sending.
 */
#ifndef BOGGART_BZMQ_H
#define BOGGART_BZMQ_H

#include <lua.h>

typedef struct bzmq_watch bzmq_watch;
typedef int (*bzmq_ready_fn)(void *ud);

void *bzmq_context(lua_State *L);   /* NULL if zmq_ctx_new failed */
int  bzmq_track(lua_State *L, void *owner, void (*closer)(void *owner), int tag);
void bzmq_untrack(lua_State *L, void *owner);
int  bzmq_count(lua_State *L, int tag);

/* ref: whether the watch keeps the loop alive. NULL if there is no loop or
 * the fd cannot be polled; callers then fall back to slice polling. */
bzmq_watch *bzmq_watch_start(lua_State *L, void *sock, bzmq_ready_fn ready,
                             void *ud, int ref);
void bzmq_watch_stop(bzmq_watch *w);
void bzmq_watch_kick(bzmq_watch *w);
void bzmq_watch_ref(bzmq_watch *w, int ref);

/* Neutralise every watch's raw uv handles before lua_close (the
 * boggart_http_shutdown doctrine). Idempotent. */
void boggart_zmq_shutdown(lua_State *L);

#define BZMQ_TAG_LZMQ    1
#define BZMQ_TAG_STATION 2

#endif
