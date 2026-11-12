#include "bkey.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static bkey_event e;
static bkey_options o;
static uint8_t output[BKEY_CAPACITY];static size_t length;
static void text(const char *s){e.text=(const uint8_t *)s;e.text_length=strlen(s);}
static void expect(const char *s){CHECK(bkey_encode(&e,&o,output,sizeof output,&length));if(length!=strlen(s)||memcmp(output,s,length)){fprintf(stderr,"encoding key=%s mods=%u flags=%u length=%zu expected=%zu\n",bkey_name(e.key),e.modifiers,o.kitty_flags,length,strlen(s));exit(1);}}
static void empty(void){expect("");}
int main(void){
  e=(bkey_event){.key=BK_UP};expect("\033[A");o.application_cursor=true;expect("\033OA");e.modifiers=BI_SHIFT|BI_CTRL;expect("\033[1;6A");
  e=(bkey_event){.key=BK_F3};expect("\033OR");e.modifiers=BI_ALT;expect("\033[13;3~");e.key=BK_F25;expect("\033[46;3~");
  e=(bkey_event){.key=BK_KP_2};expect("2");o.application_keypad=true;expect("\033Or");e.modifiers=BI_CTRL;expect("\033O5r");o.ignore_keypad_numlock=true;expect("2");
  e=(bkey_event){.key=BK_KP_INSERT};expect("\033[2~");e.key=BK_KP_BEGIN;expect("\033OE");
  e=(bkey_event){.key=BK_BACKSPACE};o=(bkey_options){0};expect("\177");o.backarrow=true;expect("\010");e.modifiers=BI_CTRL;expect("\177");e.modifiers=BI_CTRL|BI_SHIFT;expect("\010");
  o.modify_other_keys_2=true;expect("\033[27;6;127~");e.modifiers=BI_CTRL;expect("\177");
  e=(bkey_event){.key=BK_TAB,.modifiers=BI_SHIFT};o=(bkey_options){0};expect("\033[Z");o.modify_other_keys_2=true;expect("\033[27;2;9~");
  e=(bkey_event){.key=BK_ENTER,.modifiers=BI_SHIFT};o=(bkey_options){0};expect("\033[27;2;13~");
  e=(bkey_event){.key=BK_TEXT,.modifiers=BI_CTRL,.unshifted='c',.base_layout='c'};text("c");expect("\003");e.modifiers|=BI_ALT;expect("\033\003");
  e.modifiers=BI_CTRL|BI_SHIFT;text("C");expect("\033[99;6u");e.modifiers=BI_CTRL;e.unshifted='i';text("i");expect("\033[105;5u");
  e.base_layout='c';e.unshifted=0x441;text("с");expect("\003");e.modifiers=BI_CTRL|BI_SHIFT;text("С");expect("\033[1057;5u");
  e=(bkey_event){.key=BK_TEXT,.modifiers=BI_CTRL,.unshifted='2'};text("2");CHECK(bkey_encode(&e,&o,output,sizeof output,&length) && length==1 && output[0]==0);
  o.modify_other_keys_2=true;expect("\033[27;5;50~");
  e=(bkey_event){.key=BK_TEXT,.modifiers=BI_ALT,.unshifted='x'};text("😀");o=(bkey_options){.alt_prefix=true};expect("\033😀");o.macos=true;expect("😀");o.option_as_alt=BK_OPTION_ALT;expect("\033x");
  e.unshifted=0;text("你好");expect("\033你好");e.unshifted=0x1f600;text("");expect("\033😀");
  e.right_modifiers=BI_ALT;o.option_as_alt=BK_OPTION_LEFT;text("ø");expect("ø");o.option_as_alt=BK_OPTION_RIGHT;expect("\033😀");
  e=(bkey_event){.key=BK_TEXT,.modifiers=BI_SUPER};text("x");o=(bkey_options){.macos=true};empty();o.macos=false;expect("x");
  e=(bkey_event){.key=BK_ENTER};text("漢字");expect("漢字");e.key=BK_BACKSPACE;empty();e.key=BK_ESCAPE;expect("漢字");e.composing=true;empty();e.composing=false;e.action=BK_RELEASE;empty();
  o=(bkey_options){.kitty_flags=BK_DISAMBIGUATE};e=(bkey_event){.key=BK_ESCAPE};expect("\033[27u");e.key=BK_ENTER;expect("\r");e.key=BK_BACKSPACE;expect("\177");
  e=(bkey_event){.key=BK_TEXT,.unshifted='a',.base_layout='a'};text("a");expect("a");e.modifiers=BI_CTRL;expect("\033[97;5u");
  o.kitty_flags=31;e=(bkey_event){.key=BK_TEXT,.unshifted='a',.base_layout='a',.modifiers=BI_SHIFT,.consumed_modifiers=BI_SHIFT};text("A");expect("\033[97:65;2;65u");
  e.action=BK_REPEAT;expect("\033[97:65;2:2;65u");e.action=BK_RELEASE;expect("\033[97:65;2:3u");
  e=(bkey_event){.key=BK_TEXT,.unshifted=0x441,.base_layout='c',.modifiers=BI_CTRL};text("с");expect("\033[1089::99;5u");text("");expect("\033[1089::99;5u");
  e=(bkey_event){.key=BK_TEXT,.unshifted='x'};text("a😀");expect("\033[120;;97:128512u");
  text("\001a\177\xc2\x85");expect("\033[120;;97u");e.action=BK_RELEASE;expect("\033[120;1:3u");
  e=(bkey_event){.key=BK_UP,.action=BK_REPEAT};expect("\033[1;1:2A");e.action=BK_PRESS;expect("\033[1;1:1A");o.kitty_flags=BK_ALL;expect("\033[A");
  e=(bkey_event){.key=BK_LEFT_CTRL,.modifiers=BI_CTRL};expect("\033[57442;5u");e.composing=true;expect("\033[57442;5u");o.kitty_flags=BK_DISAMBIGUATE;empty();
  o.kitty_flags=BK_EVENTS;e=(bkey_event){.key=BK_ENTER,.action=BK_RELEASE};empty();o.kitty_flags|=BK_ALL;expect("\033[13;1:3u");
  o.kitty_flags=BK_DISAMBIGUATE;e=(bkey_event){.key=BK_TEXT,.unshifted='a',.modifiers=BI_SHIFT,.consumed_modifiers=BI_SHIFT};text("A");expect("A");text("");expect("\033[97;2u");
  e=(bkey_event){.key=BK_KP_9};expect("\033[57408u");e.key=BK_RIGHT_SUPER;empty();o.kitty_flags=BK_ALL;expect("\033[57450u");
  o.kitty_flags=BK_ALL|BK_ASSOCIATED;o.macos=true;e=(bkey_event){.key=BK_TEXT,.unshifted='a',.modifiers=BI_ALT};text("å");expect("\033[97;3;229u");o.option_as_alt=BK_OPTION_ALT;expect("\033[97;3u");
  e=(bkey_event){.key=BK_TEXT,.unshifted='x',.modifiers=BI_HYPER};text("x");expect("\033[120;17u");
  memset(output,0xa5,sizeof output);CHECK(!bkey_encode(&e,&o,output,1,&length)&&!length);for(size_t i=0;i<sizeof output;i++)CHECK(output[i]==0xa5);
  e.unshifted=0xd800;CHECK(!bkey_encode(&e,&o,output,sizeof output,&length));e.unshifted='x';text("\xc0\x80");CHECK(!bkey_encode(&e,&o,output,sizeof output,&length));text("\xed\xa0\x80");CHECK(!bkey_encode(&e,&o,output,sizeof output,&length));text("\xf4\x90\x80\x80");CHECK(!bkey_encode(&e,&o,output,sizeof output,&length));
  char large[BKEY_TEXT_LIMIT+1];memset(large,'a',sizeof large);e.text=(uint8_t *)large;e.text_length=sizeof large;CHECK(!bkey_encode(&e,&o,output,sizeof output,&length));e.text_length=BKEY_TEXT_LIMIT;e.modifiers=0;o.kitty_flags=BK_ALL|BK_ASSOCIATED;CHECK(bkey_encode(&e,&o,output,sizeof output,&length)&&length>BKEY_TEXT_LIMIT);
  for(unsigned k=0;k<BK_COUNT;k++){bkey_code v;CHECK(bkey_from_name(bkey_name((bkey_code)k),strlen(bkey_name((bkey_code)k)),&v)&&v==(bkey_code)k);for(unsigned flags=0;flags<32;flags++)for(unsigned mods=0;mods<256;mods++){e=(bkey_event){.key=(bkey_code)k,.modifiers=mods,.unshifted='x',.base_layout='x'};o=(bkey_options){.kitty_flags=flags};CHECK(bkey_encode(&e,&o,output,sizeof output,&length)&&length<=BKEY_CAPACITY);}}
  puts("Keyboard: legacy/application/Kitty/Unicode/IME/Option vectors and atomic bounds passed");return 0;
}
