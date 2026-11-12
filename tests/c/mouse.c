#include "bmouse.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static bmouse_options opts={BM_ANY,BM_SGR,1000,1000,1,1};
static bmouse_event e={BM_PRESS,1,0,2,3,true};
static bmouse_motion motion;
static uint8_t bytes[BMOUSE_CAPACITY]; static size_t length;
static void expected(const char *s) { CHECK(bmouse_encode(&e,&opts,&motion,bytes,sizeof bytes,&length)); CHECK(length==strlen(s) && !memcmp(bytes,s,length)); }
static void empty(void) { CHECK(bmouse_encode(&e,&opts,&motion,bytes,sizeof bytes,&length) && !length); }
int main(void) {
  expected("\033[<0;3;4M"); e.button=3; e.action=BM_RELEASE; expected("\033[<2;3;4m");
  e.action=BM_MOTION; e.button=0; e.x=1; e.y=2; expected("\033[<35;2;3M"); empty();
  e.action=BM_PRESS; e.button=1; e.modifiers=BI_SHIFT|BI_ALT|BI_CTRL; e.x=2; e.y=3; opts.format=BM_URXVT; expected("\033[60;3;4M");
  e.modifiers=0; e.action=BM_RELEASE; e.button=3; expected("\033[35;3;4M");
  opts.format=BM_UTF8; e.action=BM_PRESS; e.button=1; e.x=300; e.y=400;
  expected("\033[M \xc5\x8d\xc6\xb1"); e.button=8; e.x=2; e.y=3; expected("\033[M\xc2\xa0#$");
  opts.mode=BM_X10; opts.format=BM_FORMAT_X10; e.button=1; e.x=222; e.y=0;
  expected("\033[M \xff!"); e.x=223; empty(); e.x=0; e.modifiers=7; expected("\033[M !!");
  e.action=BM_RELEASE; empty(); e.action=BM_MOTION; empty(); e.action=BM_PRESS; e.button=4; empty();
  opts.mode=BM_ANY; opts.format=BM_SGR; e.modifiers=0;
  for(unsigned button=4;button<=9;button++) { e.button=button; char s[64]; snprintf(s,sizeof s,"\033[<%u;1;1M",button <= 7 ? button+60 : button+120); expected(s); }
  opts.format=BM_PIXELS; e.button=1; e.x=10; e.y=20; expected("\033[<0;10;20M");
  e.action=BM_RELEASE; e.button=3; expected("\033[<2;10;20m"); e.x=-4; e.y=2000; expected("\033[<2;-4;2000m");
  e.action=BM_MOTION; e.x=10; e.y=20; expected("\033[<34;10;20M"); expected("\033[<34;10;20M");
  opts.format=BM_SGR; e.action=BM_RELEASE; e.x=-5; e.y=2000; expected("\033[<2;1;1000m");
  e.action=BM_PRESS; e.any_button_pressed=false; empty(); e.any_button_pressed=true; expected("\033[<2;1;1000M");
  e.action=BM_MOTION; e.y=2001; empty(); e.x=1100; expected("\033[<34;1000;1000M");
  opts.mode=BM_NORMAL; e.action=BM_PRESS; empty(); e.action=BM_RELEASE; expected("\033[<2;1000;1000m");
  e.action=BM_MOTION; e.x=e.y=0; empty(); opts.mode=BM_BUTTON; e.button=0; empty(); e.button=1; expected("\033[<32;1;1M");
  opts.mode=BM_NONE; e.action=BM_PRESS; empty();
  opts=(bmouse_options){BM_ANY,BM_SGR,80,24,10,20}; e=(bmouse_event){BM_PRESS,1,0,19,39,true}; expected("\033[<0;2;2M");
  e.x=800; e.y=480; expected("\033[<0;80;24M");
  e=(bmouse_event){BM_MOTION,1,0,10,20,true}; motion=(bmouse_motion){false,0,0};
  memset(bytes,0xa5,sizeof bytes); bmouse_motion before=motion;
  CHECK(!bmouse_encode(&e,&opts,&motion,bytes,1,&length) && !length
    && motion.valid==before.valid && motion.column==before.column && motion.row==before.row);
  for(size_t i=0;i<sizeof bytes;i++) CHECK(bytes[i]==0xa5);
  expected("\033[<32;2;2M"); empty();
  opts.cell_width=0; CHECK(!bmouse_encode(&e,&opts,&motion,bytes,sizeof bytes,&length)); opts.cell_width=10;
  e.button=10; CHECK(!bmouse_encode(&e,&opts,&motion,bytes,sizeof bytes,&length)); e.button=0; e.action=BM_PRESS; CHECK(!bmouse_encode(&e,&opts,&motion,bytes,sizeof bytes,&length));
  e.action=BM_MOTION; e.modifiers=8; CHECK(!bmouse_encode(&e,&opts,&motion,bytes,sizeof bytes,&length));
  uint32_t random=71;
  for(size_t i=0;i<100000;i++) {
    random^=random<<13; random^=random>>17; random^=random<<5;
    opts=(bmouse_options){(bmouse_mode)(random%5),(bmouse_format)((random>>3)%5),4096,4096,65535,65535};
    e=(bmouse_event){(bmouse_action)((random>>6)%3),(random>>8)%10,(random>>12)&7,(int32_t)random,(int32_t)(random^UINT32_C(0x80000000)),true};
    bmouse_encode(&e,&opts,&motion,bytes,sizeof bytes,&length); CHECK(length<=sizeof bytes);
  }
  puts("Mouse encoding: exact formats, policies, coordinates, motion and atomic capacity passed"); return 0;
}
