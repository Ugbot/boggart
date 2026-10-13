#include "bterm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static uint8_t replies[64];static size_t used;static bool fail_reply;
static bool reply(void *ctx,const uint8_t *data,size_t n){(void)ctx;if(fail_reply)return false;CHECK(n<=sizeof replies-used);memcpy(replies+used,data,n);used+=n;return true;}
static void feed(bterm *t,const char *s){CHECK(bterm_feed(t,(const uint8_t *)s,strlen(s)));}
static void paste(bterm *t,const char *text,const char *expected){uint8_t out[128];size_t n;CHECK(bterm_paste(t,(const uint8_t *)text,strlen(text),out,sizeof out,&n));CHECK(n==strlen(expected)&&!memcmp(out,expected,n));}
static void focus(bterm *t,bool focused,const char *expected){uint8_t out[3];size_t n;CHECK(bterm_focus(t,focused,out,sizeof out,&n));CHECK(n==strlen(expected)&&!memcmp(out,expected,n)&&bterm_input_state(t).focused==focused);}
int main(void) {
  bterm *t=bterm_create(80,24,0,reply,NULL);CHECK(t);
  CHECK(bterm_input_state(t).focused&&!bterm_input_state(t).focus_reporting&&!bterm_input_state(t).bracketed_paste);
  focus(t,false,"");paste(t,"hello\nworld","hello\rworld");CHECK(!bterm_paste_safe(t,(const uint8_t *)"a\nb",3));
  feed(t,"\033[?2004;1004h");CHECK(used==3&&!memcmp(replies,"\033[O",3));used=0;
  CHECK(bterm_input_state(t).focus_reporting&&bterm_input_state(t).bracketed_paste);
  paste(t,"hello\nworld","\033[200~hello\nworld\033[201~");paste(t,"","");CHECK(!used);
  CHECK(bterm_paste_safe(t,(const uint8_t *)"a\nb",3));CHECK(!bterm_paste_safe(t,(const uint8_t *)"\033[201~",6));
  focus(t,true,"\033[I");focus(t,true,"\033[I");focus(t,false,"\033[O");CHECK(!used);
  uint8_t tiny[2]={0xa5,0xa5};size_t n;
  CHECK(!bterm_focus(t,true,tiny,sizeof tiny,&n)&&!n&&!bterm_input_state(t).focused&&tiny[0]==0xa5&&tiny[1]==0xa5);
  CHECK(!bterm_paste(t,(const uint8_t *)"x",1,tiny,sizeof tiny,&n)&&!n&&tiny[0]==0xa5&&tiny[1]==0xa5);
  feed(t,"\033[?1049h");paste(t,"x","\033[200~x\033[201~");focus(t,true,"\033[I");feed(t,"\033[?1049l");
  feed(t,"\033[?1004l");focus(t,false,"");CHECK(!used);
  CHECK(bterm_reset(t));CHECK(!bterm_input_state(t).focused&&!bterm_input_state(t).bracketed_paste&&!bterm_input_state(t).focus_reporting);
  paste(t,"x\n","x\r");feed(t,"\033[?1004h");CHECK(used==3&&!memcmp(replies,"\033[O",3));used=0;
  fail_reply=true;CHECK(!bterm_feed(t,(const uint8_t *)"\033[?1004h",8));CHECK(!bterm_feed(t,(const uint8_t *)"x",1));fail_reply=false;CHECK(bterm_reset(t));
  bterm_destroy(t);
  const char *s="\033[?2004;1004h\033[?2004l\033[?2004h";
  for(size_t chunk=1;chunk<=17;chunk++) {
    used=0;t=bterm_create(80,24,0,reply,NULL);CHECK(t);focus(t,false,"");
    for(size_t off=0,total=strlen(s);off<total;){size_t k=total-off<chunk?total-off:chunk;CHECK(bterm_feed(t,(const uint8_t *)s+off,k));off+=k;}
    CHECK(used==3&&!memcmp(replies,"\033[O",3));paste(t,"line\n","\033[200~line\n\033[201~");focus(t,true,"\033[I");bterm_destroy(t);
  }
  puts("Terminal paste/focus: negotiated modes/replies/fragmentation/RIS/atomic failure passed");return 0;
}
