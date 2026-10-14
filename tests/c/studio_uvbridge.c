#include "uvbridge.h"
#include <stdio.h>
#include <stdlib.h>
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"line %d: %s (%s)\n",__LINE__,#c,SDL_GetError()); exit(1); } } while (0)
static SDL_ThreadID owner;
static unsigned callbacks;
static void fired(uv_timer_t *timer) { CHECK(SDL_GetCurrentThreadID()==owner); callbacks++; uv_timer_stop(timer); }
static void asynchronous(uv_async_t *async) { (void)async; CHECK(SDL_GetCurrentThreadID()==owner); callbacks++; }
static int sender(void *context) { SDL_Delay(20); CHECK(!uv_async_send(context)); return 0; }
static void wake(uvbridge *bridge) {
  SDL_Event event; CHECK(SDL_WaitEventTimeout(&event,1000)); CHECK(event.type==uvbridge_event_type(bridge));
}
int main(void) {
  CHECK(SDL_Init(SDL_INIT_EVENTS)); owner=SDL_GetCurrentThreadID(); uv_loop_t loop; CHECK(!uv_loop_init(&loop));
  uv_async_t async; CHECK(!uv_async_init(&loop,&async,asynchronous));
  uvbridge *bridge=uvbridge_create(&loop); CHECK(bridge);
  uv_run(&loop,UV_RUN_NOWAIT); uvbridge_arm(bridge);
  SDL_Delay(30); uvbridge_stats before=uvbridge_get_stats(bridge); SDL_Event event;
  CHECK(!SDL_WaitEventTimeout(&event,100)); uvbridge_stats quiet=uvbridge_get_stats(bridge);
  CHECK(quiet.wakes==0 && quiet.polls==before.polls); /* blocked, not spinning */
  SDL_Thread *thread=SDL_CreateThread(sender,"bridge-test-sender",&async); CHECK(thread);
  wake(bridge); SDL_WaitThread(thread,NULL); CHECK(!callbacks);
  before=uvbridge_get_stats(bridge); SDL_Delay(50); quiet=uvbridge_get_stats(bridge);
  CHECK(before.wakes==1 && quiet.wakes==1 && quiet.polls==before.polls); /* coalesced until dispatch */
  uv_run(&loop,UV_RUN_NOWAIT); CHECK(callbacks==1);
  uv_timer_t timer; CHECK(!uv_timer_init(&loop,&timer)); CHECK(!uv_timer_start(&timer,fired,30,0));
  uv_run(&loop,UV_RUN_NOWAIT); uvbridge_arm(bridge); wake(bridge);
  uv_run(&loop,UV_RUN_NOWAIT); CHECK(callbacks==2);
  uv_close((uv_handle_t *)&timer,NULL); uv_close((uv_handle_t *)&async,NULL); uv_run(&loop,UV_RUN_NOWAIT);
  uvbridge_arm(bridge); SDL_Delay(20); before=uvbridge_get_stats(bridge); SDL_Delay(30); quiet=uvbridge_get_stats(bridge);
  CHECK(!quiet.armed && quiet.wakes==before.wakes); /* empty loop parks too */
  uvbridge_destroy(bridge); CHECK(!uv_loop_close(&loop)); SDL_Quit();
  puts("SDL/libuv waiter: idle blocking, coalesced I/O/timer wakes, main-thread callbacks and joined shutdown pass"); return 0;
}
