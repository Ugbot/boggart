#ifndef BOGGART_BCHANNEL_H
#define BOGGART_BCHANNEL_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "uv.h"
#define BCHANNEL_FRAME_LIMIT 65536u
#define BCHANNEL_QUEUE_LIMIT (1024u * 1024u)
#define BCHANNEL_FRAME_COUNT 128u
typedef struct bchannel bchannel;
typedef struct {
  bool closed; int error; uint64_t revision;
  size_t received_frames, received_bytes, queued_frames, queued_bytes;
} bchannel_status;
/* Single owning loop thread. adopt consumes fd, including on failure. */
bchannel *bchannel_adopt(uv_loop_t *loop,int fd,int *error);
bchannel *bchannel_pair(uv_loop_t *loop,int *child_fd,int *error);
void bchannel_close_fd(int fd);
int bchannel_send(bchannel *channel,const void *bytes,size_t length);
size_t bchannel_next_size(const bchannel *channel);
size_t bchannel_take(bchannel *channel,void *bytes,size_t capacity);
bchannel_status bchannel_state(const bchannel *channel);
/* Owning-thread readiness hook: complete inbound frames and closure only.
 * Callback must only schedule work; it must not destroy/reenter the channel.
 * Installing/replacing a hook does not call it. NULL removes observation. */
void bchannel_set_notify(bchannel *channel,void (*notify)(void *),void *context);
void bchannel_close(bchannel *channel);
void bchannel_destroy(bchannel *channel);
void bchannel_shutdown(uv_loop_t *loop);
#endif
