#include "uvbridge.h"
#include <stdlib.h>
#ifndef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
struct uvbridge {
  uv_loop_t *loop;
  SDL_Thread *thread;
  SDL_Mutex *mutex;
  SDL_Condition *condition;
  int control[2],backend,timeout;
  Uint32 event;
  uint64_t generation;
  bool running;
  uvbridge_stats stats;
};
static void interrupt(uvbridge *b) {
  char byte=0; ssize_t n;
  do n=write(b->control[1],&byte,1); while (n<0 && errno==EINTR);
  /* EAGAIN means the pipe already contains a wake; no wake is lost. */
}
static int waiter(void *context) {
  uvbridge *b=context;
  for (;;) {
    SDL_LockMutex(b->mutex);
    while (b->running && !b->stats.armed) SDL_WaitCondition(b->condition,b->mutex);
    if (!b->running) { SDL_UnlockMutex(b->mutex); break; }
    int backend=b->backend,timeout=b->timeout; uint64_t generation=b->generation;
    b->stats.polls++; SDL_UnlockMutex(b->mutex);
    struct pollfd fds[2]={{b->control[0],POLLIN,0},{backend,POLLIN,0}}; int result;
    do result=poll(fds,2,timeout); while (result<0 && errno==EINTR);
    if (fds[0].revents) {
      char bytes[256]; ssize_t n;
      do { n=read(b->control[0],bytes,sizeof bytes); } while (n>0 || (n<0 && errno==EINTR));
      continue;
    }
    SDL_LockMutex(b->mutex);
    if (!b->running) { SDL_UnlockMutex(b->mutex); break; }
    if (generation!=b->generation || !b->stats.armed) { SDL_UnlockMutex(b->mutex); continue; }
    b->stats.armed=false; SDL_UnlockMutex(b->mutex);
    /* One outstanding notification until main dispatch/rearm. A full queue
     * already wakes SDL; retry a filtered/failed push without busy-spinning. */
    for (;;) {
      SDL_Event event={0}; event.type=b->event;
      bool posted=SDL_PushEvent(&event);
      SDL_LockMutex(b->mutex);
      if (posted) b->stats.wakes++; else b->stats.push_failures++;
      bool retry=!posted && b->running && generation==b->generation;
      SDL_UnlockMutex(b->mutex);
      if (!retry) break;
      SDL_Delay(10);
    }
  }
  return 0;
}
void uvbridge_arm(uvbridge *b) {
  if (!b) return;
  uv_update_time(b->loop);
  int backend=uv_backend_fd(b->loop),timeout=uv_backend_timeout(b->loop);
  bool armed=backend>=0 && uv_loop_alive(b->loop);
  SDL_LockMutex(b->mutex);
  b->backend=backend; b->timeout=timeout; b->stats.armed=armed;
  b->stats.rearms++; b->generation++;
  SDL_SignalCondition(b->condition); SDL_UnlockMutex(b->mutex); interrupt(b);
}
uvbridge *uvbridge_create(uv_loop_t *loop) {
  if (!loop || uv_backend_fd(loop)<0) { SDL_SetError("libuv backend descriptor unavailable"); return NULL; }
  uvbridge *b=calloc(1,sizeof *b); if (!b) { SDL_SetError("libuv waiter allocation failed"); return NULL; }
  b->loop=loop; b->control[0]=b->control[1]=-1;
  b->mutex=SDL_CreateMutex(); b->condition=SDL_CreateCondition();
  if (!b->mutex || !b->condition) goto failed;
  b->event=SDL_RegisterEvents(1); if (!b->event) goto failed;
  if (pipe(b->control)<0) { SDL_SetError("libuv waiter pipe failed"); goto failed; }
  for (unsigned i=0;i<2;i++) if (fcntl(b->control[i],F_SETFD,FD_CLOEXEC)<0
      || fcntl(b->control[i],F_SETFL,O_NONBLOCK)<0) { SDL_SetError("libuv waiter pipe flags failed"); goto failed; }
  b->running=true; b->thread=SDL_CreateThread(waiter,"boggart-uv-wait",b);
  if (!b->thread) goto failed;
  uvbridge_arm(b); return b;
failed:
  if (b->control[0]>=0) close(b->control[0]); if (b->control[1]>=0) close(b->control[1]);
  if (b->condition) SDL_DestroyCondition(b->condition); if (b->mutex) SDL_DestroyMutex(b->mutex);
  free(b); return NULL;
}
Uint32 uvbridge_event_type(const uvbridge *b) { return b ? b->event : 0; }
uvbridge_stats uvbridge_get_stats(uvbridge *b) {
  if (!b) return (uvbridge_stats){0};
  SDL_LockMutex(b->mutex); uvbridge_stats stats=b->stats; SDL_UnlockMutex(b->mutex); return stats;
}
void uvbridge_destroy(uvbridge *b) {
  if (!b) return;
  SDL_LockMutex(b->mutex); b->running=false; b->generation++;
  SDL_SignalCondition(b->condition); SDL_UnlockMutex(b->mutex); interrupt(b);
  SDL_WaitThread(b->thread,NULL); SDL_FlushEvent(b->event);
  close(b->control[0]); close(b->control[1]); SDL_DestroyCondition(b->condition); SDL_DestroyMutex(b->mutex); free(b);
}
#else
struct uvbridge { int unused; };
uvbridge *uvbridge_create(uv_loop_t *loop) { (void)loop; SDL_SetError("libuv backend descriptor unavailable"); return NULL; }
void uvbridge_arm(uvbridge *b) { (void)b; }
Uint32 uvbridge_event_type(const uvbridge *b) { (void)b; return 0; }
uvbridge_stats uvbridge_get_stats(uvbridge *b) { (void)b; return (uvbridge_stats){0}; }
void uvbridge_destroy(uvbridge *b) { (void)b; }
#endif
