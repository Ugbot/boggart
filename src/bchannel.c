#include "bchannel.h"
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#define IO_BUDGET (256u * 1024u)
typedef struct frame {
  struct frame *next; size_t length, offset; unsigned char bytes[];
} frame;
struct bchannel {
  uv_loop_t *loop; uv_poll_t poll; struct bchannel *next;
  int fd; bool initialized, released;
  bchannel_status state;
  unsigned char header[4]; size_t header_used;
  frame *partial, *received, *received_tail, *queued, *queued_tail;
  void (*notify)(void *); void *notify_context;
};
static _Thread_local bchannel *registry;
static _Thread_local uv_loop_t *shutdown_loop;
void bchannel_close_fd(int fd){if(fd>=0)close(fd);}
static void frames_free(frame *f){while(f){frame *next=f->next;free(f);f=next;}}
static void maybe_free(bchannel *c) {
  if(!c->released || c->initialized)return;
  bchannel **entry=&registry;while(*entry && *entry!=c)entry=&(*entry)->next;
  if(*entry)*entry=c->next;
  frames_free(c->received);free(c);
}
static void closed(uv_handle_t *h){bchannel *c=h->data;c->initialized=false;maybe_free(c);}
static void fail(bchannel *c,int error) {
  if(c->state.closed)return;
  c->state.closed=true;c->state.error=error;c->state.revision++;
  if(c->initialized){uv_poll_stop(&c->poll);uv_close((uv_handle_t *)&c->poll,closed);}
  bchannel_close_fd(c->fd);c->fd=-1;
  free(c->partial);c->partial=NULL;
  frames_free(c->queued);c->queued=c->queued_tail=NULL;
  c->state.queued_bytes=c->state.queued_frames=0;
  if(c->notify)c->notify(c->notify_context);
}
void bchannel_close(bchannel *c){if(c)fail(c,0);}
void bchannel_destroy(bchannel *c){if(c && !c->released){bchannel_close(c);c->released=true;maybe_free(c);}}
static int refresh(bchannel *c);
static int flush(bchannel *c) {
  size_t budget=IO_BUDGET;
  while(c->queued && budget) {
    frame *f=c->queued;size_t left=f->length-f->offset;if(left>budget)left=budget;
#ifdef MSG_NOSIGNAL
    ssize_t n=send(c->fd,f->bytes+f->offset,left,MSG_NOSIGNAL);
#else
    ssize_t n=send(c->fd,f->bytes+f->offset,left,0);
#endif
    if(n>0) {
      f->offset+=(size_t)n;budget-=(size_t)n;c->state.queued_bytes-=(size_t)n;
      if(f->offset==f->length){c->queued=f->next;if(!c->queued)c->queued_tail=NULL;c->state.queued_frames--;free(f);}
    } else if(n<0 && errno==EINTR)continue;
    else if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK))break;
    else return n<0 ? uv_translate_sys_error(errno) : UV_EPIPE;
  }
  return 0;
}
static int read_frames(bchannel *c) {
  size_t budget=IO_BUDGET;
  while(budget) {
    unsigned char *dst=c->header+c->header_used;size_t left=4-c->header_used;
    if(c->partial){dst=c->partial->bytes+c->partial->offset;left=c->partial->length-c->partial->offset;}
    if(left>budget)left=budget;
    ssize_t n=recv(c->fd,dst,left,0);
    if(n<0 && errno==EINTR)continue;
    if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK))return 0;
    if(n<0)return uv_translate_sys_error(errno);
    if(!n){fail(c,c->header_used || c->partial ? UV_EPROTO : 0);return 0;}
    budget-=(size_t)n;
    if(c->partial) {
      frame *f=c->partial;f->offset+=(size_t)n;
      if(f->offset==f->length) {
        if(c->received_tail)c->received_tail->next=f;else c->received=f;
        c->received_tail=f;c->partial=NULL;c->header_used=0;
        c->state.received_frames++;c->state.received_bytes+=f->length;c->state.revision++;
        if(c->notify)c->notify(c->notify_context);
      }
    } else {
      c->header_used+=(size_t)n;
      if(c->header_used==4) {
        size_t length=((size_t)c->header[0]<<24)|((size_t)c->header[1]<<16)|((size_t)c->header[2]<<8)|c->header[3];
        if(!length || length>BCHANNEL_FRAME_LIMIT)return UV_EMSGSIZE;
        if(c->state.received_frames==BCHANNEL_FRAME_COUNT || length>BCHANNEL_QUEUE_LIMIT-c->state.received_bytes)return UV_ENOBUFS;
        c->partial=malloc(sizeof(frame)+length);if(!c->partial)return UV_ENOMEM;
        *c->partial=(frame){.length=length};
      }
    }
  }
  return 0;
}
static void ready(uv_poll_t *h,int status,int events) {
  bchannel *c=h->data;if(status<0){fail(c,status);return;}
  int error=0;
  if(events&UV_READABLE)error=read_frames(c);
  if(!error && !c->state.closed && (events&UV_WRITABLE))error=flush(c);
  if(!error && !c->state.closed)error=refresh(c);
  if(error)fail(c,error);
}
static int refresh(bchannel *c){return uv_poll_start(&c->poll,UV_READABLE|(c->queued?UV_WRITABLE:0),ready);}
bchannel *bchannel_adopt(uv_loop_t *loop,int fd,int *error_out) {
  int error=UV_EINVAL;bchannel *c=NULL;int type=0;socklen_t type_size=sizeof type;
  if(!loop || loop==shutdown_loop){error=UV_ECANCELED;goto done;}
  if(fd<3 || getsockopt(fd,SOL_SOCKET,SO_TYPE,&type,&type_size) || type!=SOCK_STREAM)goto done;
  if(fcntl(fd,F_SETFD,FD_CLOEXEC)<0){error=uv_translate_sys_error(errno);goto done;}
#ifdef SO_NOSIGPIPE
  int enabled=1;if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof enabled)<0){error=uv_translate_sys_error(errno);goto done;}
#endif
  c=calloc(1,sizeof *c);if(!c){error=UV_ENOMEM;goto done;}
  c->loop=loop;c->fd=fd;c->next=registry;registry=c;fd=-1;
  if((error=uv_poll_init(loop,&c->poll,c->fd)))goto done;
  c->initialized=true;c->poll.data=c;
  error=refresh(c);
done:
  bchannel_close_fd(fd);
  if(error && c){bchannel_destroy(c);c=NULL;}
  if(error_out)*error_out=error;return c;
}
bchannel *bchannel_pair(uv_loop_t *loop,int *child_fd,int *error) {
  int pair[2];*child_fd=-1;
  if(socketpair(AF_UNIX,SOCK_STREAM,0,pair)<0){if(error)*error=uv_translate_sys_error(errno);return NULL;}
  if(fcntl(pair[1],F_SETFD,FD_CLOEXEC)<0){if(error)*error=uv_translate_sys_error(errno);close(pair[0]);close(pair[1]);return NULL;}
  bchannel *c=bchannel_adopt(loop,pair[0],error);
  if(!c)close(pair[1]);else *child_fd=pair[1];return c;
}
int bchannel_send(bchannel *c,const void *bytes,size_t length) {
  if(!c || c->state.closed)return UV_EPIPE;
  if(!bytes || !length || length>BCHANNEL_FRAME_LIMIT)return UV_EMSGSIZE;
  if(c->state.queued_frames==BCHANNEL_FRAME_COUNT || length+4>BCHANNEL_QUEUE_LIMIT-c->state.queued_bytes)return UV_ENOBUFS;
  frame *f=malloc(sizeof *f+length+4);if(!f)return UV_ENOMEM;
  *f=(frame){.length=length+4};
  f->bytes[0]=(unsigned char)(length>>24);f->bytes[1]=(unsigned char)(length>>16);
  f->bytes[2]=(unsigned char)(length>>8);f->bytes[3]=(unsigned char)length;memcpy(f->bytes+4,bytes,length);
  if(c->queued_tail)c->queued_tail->next=f;else c->queued=f;c->queued_tail=f;
  c->state.queued_frames++;c->state.queued_bytes+=length+4;
  int error=refresh(c);if(error)fail(c,error);return error;
}
size_t bchannel_next_size(const bchannel *c){return c && c->received ? c->received->length : 0;}
size_t bchannel_take(bchannel *c,void *bytes,size_t capacity) {
  if(!c || !c->received || c->received->length>capacity)return 0;
  frame *f=c->received;size_t length=f->length;memcpy(bytes,f->bytes,length);
  c->received=f->next;if(!c->received)c->received_tail=NULL;
  c->state.received_frames--;c->state.received_bytes-=length;free(f);return length;
}
bchannel_status bchannel_state(const bchannel *c){return c ? c->state : (bchannel_status){.closed=true,.error=UV_EPIPE};}
void bchannel_set_notify(bchannel *c,void (*notify)(void *),void *context) {
  if(c){c->notify=notify;c->notify_context=context;}
}
void bchannel_shutdown(uv_loop_t *loop) {
  shutdown_loop=loop;
  for(bchannel *c=registry;c;c=c->next)if(c->loop==loop)bchannel_close(c);
  for(;;) {
    bool pending=false;for(bchannel *c=registry;c;c=c->next)if(c->loop==loop && c->initialized){pending=true;break;}
    if(!pending)break;uv_run(loop,UV_RUN_NOWAIT);
  }
}
#else
struct bchannel{int unused;};
void bchannel_close_fd(int fd){(void)fd;}
bchannel *bchannel_adopt(uv_loop_t *loop,int fd,int *error){(void)loop;(void)fd;if(error)*error=UV_ENOSYS;return NULL;}
bchannel *bchannel_pair(uv_loop_t *loop,int *fd,int *error){(void)loop;*fd=-1;if(error)*error=UV_ENOSYS;return NULL;}
int bchannel_send(bchannel *c,const void *b,size_t n){(void)c;(void)b;(void)n;return UV_ENOSYS;}
size_t bchannel_next_size(const bchannel *c){(void)c;return 0;}
size_t bchannel_take(bchannel *c,void *b,size_t n){(void)c;(void)b;(void)n;return 0;}
bchannel_status bchannel_state(const bchannel *c){(void)c;return (bchannel_status){.closed=true,.error=UV_ENOSYS};}
void bchannel_set_notify(bchannel *c,void (*notify)(void *),void *context){(void)c;(void)notify;(void)context;}
void bchannel_close(bchannel *c){(void)c;}
void bchannel_destroy(bchannel *c){(void)c;}
void bchannel_shutdown(uv_loop_t *loop){(void)loop;}
#endif
