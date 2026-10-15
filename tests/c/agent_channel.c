#include "bchannel.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#define CHECK(v) do{if(!(v)){fprintf(stderr,"channel check failed %s:%d: %s\n",__FILE__,__LINE__,#v);exit(1);}}while(0)
static uv_loop_t loop;
static void tick(void){uv_run(&loop,UV_RUN_NOWAIT);}
static void received(bchannel *c,unsigned count) {
  uint64_t end=uv_hrtime()+UINT64_C(2000000000);
  while(bchannel_state(c).received_frames<count && !bchannel_state(c).closed && uv_hrtime()<end)tick();
  CHECK(bchannel_state(c).received_frames==count);
}
static void until_closed(bchannel *c) {
  uint64_t end=uv_hrtime()+UINT64_C(2000000000);
  while(!bchannel_state(c).closed && uv_hrtime()<end)tick();CHECK(bchannel_state(c).closed);
}
static void destroy(bchannel *c){bchannel_destroy(c);tick();}
int main(void) {
  CHECK(!uv_loop_init(&loop));int fd,error;char bytes[BCHANNEL_FRAME_LIMIT];
  bchannel *a=bchannel_pair(&loop,&fd,&error);CHECK(a && !error);
  bchannel *b=bchannel_adopt(&loop,fd,&error);CHECK(b && !error && (fcntl(fd,F_GETFD)&FD_CLOEXEC));
  CHECK(!bchannel_send(a,"a\0b",3));CHECK(!bchannel_send(a,"next",4));received(b,2);
  CHECK(!bchannel_take(b,bytes,2));CHECK(bchannel_take(b,bytes,sizeof bytes)==3 && !memcmp(bytes,"a\0b",3));
  CHECK(bchannel_take(b,bytes,sizeof bytes)==4 && !memcmp(bytes,"next",4));
  CHECK(bchannel_send(a,bytes,0)==UV_EMSGSIZE && bchannel_send(a,bytes,BCHANNEL_FRAME_LIMIT+1)==UV_EMSGSIZE);
  memset(bytes,'x',sizeof bytes);CHECK(!bchannel_send(b,bytes,sizeof bytes));received(a,1);
  CHECK(bchannel_take(a,bytes,sizeof bytes)==sizeof bytes);
  for(unsigned i=0;i<BCHANNEL_FRAME_COUNT;i++)CHECK(!bchannel_send(a,"x",1));
  CHECK(bchannel_send(a,"overflow",8)==UV_ENOBUFS);received(b,BCHANNEL_FRAME_COUNT);
  CHECK(!bchannel_send(a,"overflow",8));until_closed(b);CHECK(bchannel_state(b).error==UV_ENOBUFS);
  CHECK(bchannel_take(b,bytes,sizeof bytes)==1);destroy(a);destroy(b);

  a=bchannel_pair(&loop,&fd,&error);CHECK(a);
  for(unsigned i=0;i<15;i++)CHECK(!bchannel_send(a,bytes,sizeof bytes));
  CHECK(bchannel_state(a).queued_frames==15 && bchannel_send(a,bytes,sizeof bytes)==UV_ENOBUFS);
  close(fd);destroy(a);
  a=bchannel_pair(&loop,&fd,&error);CHECK(a);b=bchannel_adopt(&loop,fd,&error);CHECK(b);
  for(unsigned i=0;i<15;i++)CHECK(!bchannel_send(b,bytes,sizeof bytes));received(a,15);
  CHECK(!bchannel_send(b,bytes,sizeof bytes));CHECK(!bchannel_send(b,bytes,sizeof bytes));until_closed(a);
  CHECK(bchannel_state(a).error==UV_ENOBUFS && bchannel_state(a).received_bytes==BCHANNEL_QUEUE_LIMIT);
  destroy(a);destroy(b);

  /* Fragmented headers/payloads; EOF preserves completed frames. */
  a=bchannel_pair(&loop,&fd,&error);CHECK(a);
  const unsigned char wire[]={0,0,0,3,'o','k','!'};
  for(size_t i=0;i<sizeof wire;i++){CHECK(write(fd,wire+i,1)==1);tick();if(i+1<sizeof wire)CHECK(!bchannel_next_size(a));}
  received(a,1);close(fd);until_closed(a);CHECK(!bchannel_state(a).error);
  CHECK(bchannel_take(a,bytes,sizeof bytes)==3 && !memcmp(bytes,"ok!",3));destroy(a);
  const unsigned char bad[][4]={{0,0,0,0},{0,1,0,1}};
  for(unsigned i=0;i<2;i++) {
    a=bchannel_pair(&loop,&fd,&error);CHECK(a);CHECK(write(fd,bad[i],4)==4);
    until_closed(a);CHECK(bchannel_state(a).error==UV_EMSGSIZE);close(fd);destroy(a);
  }
  a=bchannel_pair(&loop,&fd,&error);CHECK(a);CHECK(write(fd,wire,5)==5);close(fd);
  until_closed(a);CHECK(bchannel_state(a).error==UV_EPROTO);destroy(a);
  a=bchannel_pair(&loop,&fd,&error);CHECK(a);bchannel_shutdown(&loop);CHECK(bchannel_state(a).closed);
  close(fd);destroy(a);CHECK(!uv_loop_close(&loop));
  puts("agent channel: framed binary/fragmented IO, CLOEXEC, limits, malformed input, EOF drain and shutdown pass");return 0;
}
