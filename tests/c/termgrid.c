#include "termgrid.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(c) do{if(!(c)){fprintf(stderr,"line %d: %s\n",__LINE__,#c);exit(1);}}while(0)
static bool fail_allocation;
static void *capture_calloc(size_t n,size_t size){return fail_allocation ? NULL : calloc(n,size);}
#define calloc capture_calloc
#include "../../studio/src/termgrid.c"
#undef calloc
static void feed(bterm *t,const char *s){CHECK(bterm_feed(t,(const uint8_t *)s,strlen(s)));}
int main(void){
  bterm *t=bterm_create(8,3,4,NULL,NULL);CHECK(t);
  feed(t,"\033[38;2;255;0;0;48;5;17m日é\033[0mX");
  const lpage_screen *screen=bterm_screen(t);tg_row *a=tg_capture(t,lpage_visible(screen,0),8);CHECK(a);
  uint64_t revision=lpage_visible(screen,0)->revision;bterm_ack_damage(t);CHECK(lpage_visible(screen,0)->revision==revision);
  CHECK(a->cells[0].width==2 && a->cells[1].width==0 && !strcmp(tg_text(a,&a->cells[0]),"日"));
  CHECK(!strcmp(tg_text(a,&a->cells[2]),"é") && a->cells[0].style.fg==(LP_COLOR_RGB|0xff0000));
  tg_row *same=tg_capture(t,lpage_visible(screen,0),8);CHECK(tg_equal(a,same));tg_release(same);
  CHECK(tg_retain(a) && a->references==2);tg_release(a);
  fail_allocation=true;CHECK(!tg_capture(t,lpage_visible(screen,0),8));fail_allocation=false;
  CHECK(!tg_capture(t,lpage_visible(screen,0),7));
  feed(t,"\033[HCHANGED");tg_row *changed=tg_capture(t,lpage_visible(screen,0),8);CHECK(changed && !tg_equal(a,changed));
  CHECK(lpage_visible(screen,0)->revision!=revision);
  CHECK(!strcmp(tg_text(a,&a->cells[2]),"é"));tg_release(changed);
  feed(t,"\033[Hq");for(unsigned i=0;i<100;i++)feed(t,"́");
  tg_row *cluster=tg_capture(t,lpage_visible(screen,0),8);CHECK(cluster && cluster->cells[0].length==1+64*2);
  bterm_destroy(t);CHECK(!strcmp(tg_text(a,&a->cells[0]),"日") && tg_text(cluster,&cluster->cells[0])[0]=='q');
  tg_release(a);tg_release(cluster);puts("immutable render rows: full clusters/styles/wide tails, hashes, close/mutation lifetime and OOM pass");return 0;
}
