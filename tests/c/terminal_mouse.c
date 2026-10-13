#include "bterm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static void feed(bterm *t,const char *s) { CHECK(bterm_feed(t,(const uint8_t *)s,strlen(s))); }
static void expect(bterm *t,bmouse_event event,uint32_t w,uint32_t h,const char *expected) {
  uint8_t output[BMOUSE_CAPACITY]; size_t n;
  CHECK(bterm_mouse(t,&event,w,h,output,sizeof output,&n));
  CHECK(n==strlen(expected) && !memcmp(output,expected,n));
}
int main(void) {
  bterm *t=bterm_create(80,24,0,NULL,NULL); CHECK(t);
  bmouse_event event={BM_PRESS,1,0,10,20,true};
  expect(t,event,10,20,"");
  feed(t,"\033[?1000;1006h"); expect(t,event,10,20,"\033[<0;2;2M");
  event.action=BM_MOTION; expect(t,event,10,20,"");
  feed(t,"\033[?1002h"); expect(t,event,10,20,"\033[<32;2;2M"); expect(t,event,10,20,"");
  expect(t,event,5,10,"\033[<32;3;3M"); expect(t,event,5,10,"");
  feed(t,"\033[?1003h"); event.button=0; expect(t,event,10,20,"\033[<35;2;2M");
  feed(t,"\033[?1005h"); event.action=BM_PRESS; event.button=8; event.x=20; event.y=40;
  expect(t,event,10,20,"\033[M\xc2\xa0##");
  feed(t,"\033[?1015h"); expect(t,event,10,20,"\033[160;3;3M");
  feed(t,"\033[?1016h"); expect(t,event,10,20,"\033[<128;20;40M");
  feed(t,"\033[?1006l"); CHECK(bterm_input_state(t).mouse_format==BM_FORMAT_X10);
  feed(t,"\033[?9h"); CHECK(bterm_input_state(t).mouse_mode==BM_X10); expect(t,event,10,20,"");
  event.button=1; event.modifiers=7; expect(t,event,10,20,"\033[M ##");
  feed(t,"\033[?1003h\033[?1000l"); CHECK(bterm_input_state(t).mouse_mode==BM_NONE);
  feed(t,"\033[?1003;1006h"); event=(bmouse_event){BM_MOTION,1,0,10,20,true}; expect(t,event,10,20,"\033[<32;2;2M");
  feed(t,"\033[?1049h"); expect(t,event,10,20,"\033[<32;2;2M"); expect(t,event,10,20,"");
  feed(t,"\033[?1049h"); expect(t,event,10,20,"");
  feed(t,"\033[?1049l"); expect(t,event,10,20,"\033[<32;2;2M");
  feed(t,"\033c"); CHECK(bterm_input_state(t).mouse_mode==BM_NONE && bterm_input_state(t).mouse_format==BM_FORMAT_X10); expect(t,event,10,20,"");
  feed(t,"\033[?1003;1006h"); uint8_t output[64]; size_t n;
  CHECK(!bterm_mouse(t,&event,10,20,output,1,&n)); expect(t,event,10,20,"\033[<32;2;2M");
  CHECK(bterm_reset(t)); expect(t,event,10,20,""); bterm_destroy(t);
  const char *stream="\033[?1000h\033[?1005h\033[?1002;1006h\033[?1016h\033[?1003h";
  for(size_t chunk=1;chunk<=17;chunk++) {
    t=bterm_create(80,24,0,NULL,NULL); CHECK(t);
    for(size_t off=0,nbytes=strlen(stream);off<nbytes;) { size_t k=nbytes-off<chunk ? nbytes-off:chunk; CHECK(bterm_feed(t,(const uint8_t *)stream+off,k)); off+=k; }
    CHECK(bterm_input_state(t).mouse_mode==BM_ANY && bterm_input_state(t).mouse_format==BM_PIXELS);
    expect(t,event,10,20,"\033[<32;10;20M"); bterm_destroy(t);
  }
  puts("Terminal mouse: fragmented negotiation, dimensions, modes, screen transitions and RIS passed"); return 0;
}
