#include "bterm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static char replies[256];static size_t used;
static bool reply(void *ctx,const uint8_t *p,size_t n){(void)ctx;CHECK(n<=sizeof replies-used);memcpy(replies+used,p,n);used+=n;return true;}
static void feed(bterm *t,const char *s){CHECK(bterm_feed(t,(const uint8_t *)s,strlen(s)));}
static void expect(bterm *t,bkey_event e,const char *s){uint8_t out[BKEY_CAPACITY];size_t n;CHECK(bterm_key(t,&e,false,BK_OPTION_TEXT,out,sizeof out,&n));CHECK(n==strlen(s)&&!memcmp(out,s,n));}
int main(void){
  bterm *t=bterm_create(80,24,0,reply,NULL);CHECK(t);bkey_event e={.key=BK_UP};expect(t,e,"\033[A");
  CHECK(bterm_input_state(t).ignore_keypad_numlock && bterm_input_state(t).alt_prefix);
  feed(t,"\033[?1;66h\033[?1035l");expect(t,e,"\033OA");e.key=BK_KP_0;expect(t,e,"\033Op");feed(t,"\033[?1035h");expect(t,e,"0");
  e.key=BK_BACKSPACE;feed(t,"\033[?67h");expect(t,e,"\010");
  feed(t,"\033[>4;2m");e=(bkey_event){.key=BK_TEXT,.unshifted='a',.base_layout='a',.modifiers=BI_CTRL,.text=(const uint8_t *)"a",.text_length=1};expect(t,e,"\033[27;5;97~");feed(t,"\033[>4m");expect(t,e,"\001");
  feed(t,"\033[>1u\033[?u");CHECK(used==5&&!memcmp(replies,"\033[?1u",5));used=0;expect(t,e,"\033[97;5u");
  feed(t,"\033[=2;2u");CHECK(bterm_input_state(t).kitty_flags==3);e.action=BK_RELEASE;expect(t,e,"\033[97;5:3u");
  feed(t,"\033[=1;3u");CHECK(bterm_input_state(t).kitty_flags==2);
  feed(t,"\033[>8u\033[>16u\033[<u");CHECK(bterm_input_state(t).kitty_flags==8);feed(t,"\033[<2u");CHECK(bterm_input_state(t).kitty_flags==0);
  feed(t,"\033[>1u\033[?1049h");CHECK(bterm_input_state(t).kitty_flags==0);feed(t,"\033[>31u\033[?1049l");CHECK(bterm_input_state(t).kitty_flags==1);feed(t,"\033[?1049h");CHECK(bterm_input_state(t).kitty_flags==31);
  feed(t,"\033c");CHECK(!bterm_input_state(t).kitty_flags && !bterm_input_state(t).backarrow && !bterm_input_state(t).modify_other_keys_2);feed(t,"\033[?1049h");CHECK(!bterm_input_state(t).kitty_flags);feed(t,"\033[?1049l");
  feed(t,"\033[=5u\033[>32u\033[=65535u\033[=1;4u\033[=1:2u\033[>1;2u\033[<1;2u\033[?0u");CHECK(bterm_input_state(t).kitty_flags==5 && !used);
  feed(t,"\033[<65535u");CHECK(!bterm_input_state(t).kitty_flags);
  for(unsigned i=1;i<=9;i++){char s[16];snprintf(s,sizeof s,"\033[>%uu",i);feed(t,s);}CHECK(bterm_input_state(t).kitty_flags==9);feed(t,"\033[<7u");CHECK(bterm_input_state(t).kitty_flags==2);feed(t,"\033[<u");CHECK(!bterm_input_state(t).kitty_flags);
  feed(t,"\033[=31u");e=(bkey_event){.key=BK_UP};uint8_t out[1]={0xa5};size_t n;CHECK(!bterm_key(t,&e,false,BK_OPTION_TEXT,out,1,&n)&&!n&&out[0]==0xa5);CHECK(bterm_feed(t,(const uint8_t *)"ok",2));bterm_destroy(t);
  const char *stream="\033[>1u\033[=2;2u\033[>8u\033[<u\033[?u\033[>4;2m\033[?1;67h";
  for(size_t chunk=1;chunk<=17;chunk++){used=0;t=bterm_create(80,24,0,reply,NULL);CHECK(t);for(size_t off=0,total=strlen(stream);off<total;){size_t k=total-off<chunk?total-off:chunk;CHECK(bterm_feed(t,(const uint8_t *)stream+off,k));off+=k;}CHECK(bterm_input_state(t).kitty_flags==3 && bterm_input_state(t).modify_other_keys_2 && bterm_input_state(t).backarrow && used==5&&!memcmp(replies,"\033[?3u",5));bterm_destroy(t);}
  puts("Terminal keyboard: negotiation/query/stack/fragmentation/alt/RIS passed");return 0;
}
