/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/key_encode.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/function_keys.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/key.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/key_mods.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * Function mappings based on Foot: Copyright (c) 2019 Daniel Eklöf.
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE and foot-LICENSE.
 * Adaptation: explicit host options, strict UTF-8, two-pass atomic output.
 * Kitty functional numbers derive from the primary keyboard protocol, rather
 * than Ghostty's Foot-derived kitty.zig table; see docs/terminal-core.md.
 */
#include "bkey.h"
#include <string.h>
typedef struct { uint8_t *bytes; size_t length; } writer;
static void put(writer *w, uint8_t b) { if (w->bytes) w->bytes[w->length]=b; w->length++; }
static void bytes(writer *w,const uint8_t *s,size_t n) { if (w->bytes && n) memcpy(w->bytes+w->length,s,n); w->length+=n; }
static void number(writer *w,uint32_t n) { uint8_t b[10]; size_t k=0; do { b[k++]=(uint8_t)('0'+n%10);n/=10; } while(n); while(k)put(w,b[--k]); }
static bool scalar(uint32_t cp) { return cp<=0x10ffff && !(cp>=0xd800 && cp<=0xdfff); }
static bool control(uint32_t cp) { return cp<32 || cp==127; }
static bool next(const uint8_t *s,size_t n,size_t *i,uint32_t *cp) {
  uint8_t c=s[(*i)++]; unsigned k; uint32_t min;
  if(c<128){*cp=c;return true;}
  if(c>=0xc2 && c<=0xdf){k=1;min=128;*cp=c&31;}
  else if(c>=0xe0 && c<=0xef){k=2;min=2048;*cp=c&15;}
  else if(c>=0xf0 && c<=0xf4){k=3;min=65536;*cp=c&7;}
  else return false;
  if(k>n-*i)return false;
  while(k--){c=s[(*i)++];if((c&0xc0)!=0x80)return false;*cp=(*cp<<6)|(c&63);}
  return *cp>=min && scalar(*cp);
}
static void codepoint(writer *w,uint32_t cp) {
  if(cp<128)put(w,(uint8_t)cp);
  else if(cp<2048){put(w,(uint8_t)(0xc0|(cp>>6)));put(w,(uint8_t)(0x80|(cp&63)));}
  else if(cp<65536){put(w,(uint8_t)(0xe0|(cp>>12)));put(w,(uint8_t)(0x80|((cp>>6)&63)));put(w,(uint8_t)(0x80|(cp&63)));}
  else {put(w,(uint8_t)(0xf0|(cp>>18)));put(w,(uint8_t)(0x80|((cp>>12)&63)));put(w,(uint8_t)(0x80|((cp>>6)&63)));put(w,(uint8_t)(0x80|(cp&63)));}
}
static const char *const names[BK_COUNT]={
  "text","escape","enter","tab","backspace","insert","delete","left","right","up","down","page_up","page_down","home","end",
  "caps_lock","scroll_lock","num_lock","print_screen","pause",
  "f1","f2","f3","f4","f5","f6","f7","f8","f9","f10","f11","f12","f13","f14","f15","f16","f17","f18","f19","f20","f21","f22","f23","f24","f25",
  "kp_0","kp_1","kp_2","kp_3","kp_4","kp_5","kp_6","kp_7","kp_8","kp_9","kp_decimal","kp_divide","kp_multiply","kp_subtract","kp_add","kp_enter","kp_equal","kp_separator",
  "kp_left","kp_right","kp_up","kp_down","kp_page_up","kp_page_down","kp_home","kp_end","kp_insert","kp_delete","kp_begin",
  "left_shift","left_ctrl","left_alt","left_super","right_shift","right_ctrl","right_alt","right_super","help","menu"
};
const char *bkey_name(bkey_code k){return (unsigned)k<BK_COUNT ? names[k]:NULL;}
bool bkey_from_name(const char *s,size_t n,bkey_code *key){for(unsigned k=0;k<BK_COUNT;k++)if(strlen(names[k])==n && !memcmp(s,names[k],n)){*key=(bkey_code)k;return true;}return false;}
static void csi(writer *w){put(w,27);put(w,'[');}
static void modify(writer *w,unsigned mods,uint32_t cp){csi(w);number(w,27);put(w,';');number(w,mods+1);put(w,';');number(w,cp);put(w,'~');}
static bool option_alt(const bkey_event *e,const bkey_options *o){return !o->macos || o->option_as_alt==BK_OPTION_ALT || (o->option_as_alt==BK_OPTION_LEFT && !(e->right_modifiers&BI_ALT)) || (o->option_as_alt==BK_OPTION_RIGHT && (e->right_modifiers&BI_ALT));}
/* Protocol-defined numbers, grouped into contiguous ranges. */
static bool functional(bkey_code k,uint32_t *cp,uint8_t *final,bool *modifier){
  *modifier=false;*final='u';
  if(k>=BK_ESCAPE && k<=BK_BACKSPACE){static const unsigned values[]={27,13,9,127};*cp=values[k-BK_ESCAPE];}
  else if(k==BK_INSERT || k==BK_DELETE){*cp=k==BK_INSERT?2:3;*final='~';}
  else if(k>=BK_LEFT && k<=BK_DOWN){*cp=1;*final=(uint8_t)"DCAB"[k-BK_LEFT];}
  else if(k==BK_PAGE_UP || k==BK_PAGE_DOWN){*cp=k==BK_PAGE_UP?5:6;*final='~';}
  else if(k==BK_HOME || k==BK_END){*cp=1;*final=k==BK_HOME?'H':'F';}
  else if(k>=BK_CAPS_LOCK && k<=BK_PAUSE){*cp=57358+(k-BK_CAPS_LOCK);*modifier=k==BK_CAPS_LOCK || k==BK_NUM_LOCK;}
  else if(k>=BK_F1 && k<=BK_F12){static const unsigned values[]={1,1,13,1,15,17,18,19,20,21,23,24};*cp=values[k-BK_F1];*final=k==BK_F1?'P':k==BK_F2?'Q':k==BK_F4?'S':'~';}
  else if(k>=BK_F13 && k<=BK_F25)*cp=57376+(k-BK_F13);
  else if(k>=BK_KP_0 && k<=BK_KP_BEGIN)*cp=57399+(k-BK_KP_0);
  else if(k>=BK_LEFT_SHIFT && k<=BK_RIGHT_SUPER){*cp=(k<=BK_LEFT_SUPER?57441:57447)+(k<=BK_LEFT_SUPER?k-BK_LEFT_SHIFT:k-BK_RIGHT_SHIFT);*modifier=true;}
  else return false;
  return true;
}
static bool pc(writer *w,const bkey_event *e,const bkey_options *o){
  unsigned m=e->modifiers&63; bool modified=m>0 && m<16; bkey_code k=e->key;
  if(k>=BK_KP_LEFT && k<=BK_KP_DELETE){static const bkey_code mapped[]={BK_LEFT,BK_RIGHT,BK_UP,BK_DOWN,BK_PAGE_UP,BK_PAGE_DOWN,BK_HOME,BK_END,BK_INSERT,BK_DELETE};k=mapped[k-BK_KP_LEFT];}
  uint8_t final=0; unsigned value=1;
  if(k>=BK_LEFT && k<=BK_DOWN)final=(uint8_t)"DCAB"[k-BK_LEFT];
  else if(k==BK_HOME || k==BK_END)final=k==BK_HOME?'H':'F';
  else if(k==BK_KP_BEGIN)final='E';
  else if(k==BK_INSERT || k==BK_DELETE){value=k==BK_INSERT?2:3;final='~';}
  else if(k==BK_PAGE_UP || k==BK_PAGE_DOWN){value=k==BK_PAGE_UP?5:6;final='~';}
  else if(k==BK_HELP || k==BK_MENU){value=k==BK_HELP?28:29;final='~';}
  else if(k>=BK_F1 && k<=BK_F25){
    static const unsigned values[]={1,1,13,1,15,17,18,19,20,21,23,24,25,26,28,29,31,32,33,34,42,43,44,45,46};
    value=values[k-BK_F1];final=k==BK_F1?'P':k==BK_F2?'Q':k==BK_F4?'S':'~';
    if(!modified && k<=BK_F4){put(w,27);put(w,'O');put(w,(uint8_t)"PQRS"[k-BK_F1]);return true;}
  }
  if(final){
    if(modified){csi(w);number(w,value);put(w,';');number(w,m+1);put(w,final);}
    else if(final!='~'){put(w,27);put(w,o->application_cursor?'O':'[');put(w,final);}
    else {csi(w);number(w,value);put(w,final);}return true;
  }
  if(k>=BK_KP_0 && k<=BK_KP_ENTER){
    static const uint8_t suffix[]="pqrstuvwxynojmkM",normal[]="0123456789./*-+\r";unsigned i=k-BK_KP_0;
    if(o->application_keypad && !o->ignore_keypad_numlock && (!m || modified)){put(w,27);put(w,'O');if(modified)number(w,m+1);put(w,suffix[i]);return true;}
    if(!o->application_keypad || o->ignore_keypad_numlock){put(w,normal[i]);return true;}return false;
  }
  if(k>=BK_ESCAPE && k<=BK_BACKSPACE){
    unsigned cp=k==BK_ESCAPE?27:k==BK_ENTER?13:k==BK_TAB?9:127;
    if(k==BK_BACKSPACE){
      if(m==BI_CTRL){put(w,o->backarrow?127:8);return true;}
      if(modified && o->modify_other_keys_2){modify(w,m,127);return true;}
      if(modified && (m&BI_ALT))put(w,27);
      put(w,modified && (m&BI_CTRL)?8:o->backarrow && !modified?8:127);return true;
    }
    if(modified){
      if(k==BK_TAB && m==BI_SHIFT && !o->modify_other_keys_2){csi(w);put(w,'Z');}
      else if(m==BI_ALT && !o->modify_other_keys_2){put(w,27);put(w,(uint8_t)cp);}
      else modify(w,m,cp);
    }else put(w,(uint8_t)cp);return true;
  }
  return false;
}
static int ctrl(const bkey_event *e){
  unsigned m=(e->modifiers&63)&~BI_ALT;uint32_t cp;
  if(!(m&BI_CTRL))return -1;
  if(e->text_length==1)cp=e->text[0];
  else if(e->base_layout && e->base_layout<=255 && m==BI_CTRL)cp=e->base_layout;
  else return -1;
  if((m&BI_SHIFT) && (cp<'A' || cp>'Z') && cp!='@')m&=~BI_SHIFT;
  if(cp>='A' && cp<='Z' && e->unshifted && e->unshifted<=255)cp=e->unshifted;
  if(m!=BI_CTRL)return -1;
  if(cp>='a' && cp<='z' && cp!='i' && cp!='m')return (int)(cp-'a'+1);
  switch(cp){case ' ':case '@':case '2':return 0;case '/':case '_':case '7':return 31;case '3':return 27;case '\\':case '4':return 28;case ']':case '5':return 29;case '^':case '~':case '6':return 30;case '?':case '8':return 127;case '0':case '1':case '9':return (int)cp;default:return -1;}
}
static bool alt(writer *w,const bkey_event *e,const bkey_options *o,unsigned binding){
  if(!(binding&BI_ALT) || !o->alt_prefix || !option_alt(e,o))return false;
  if(e->text_length==1){put(w,27);bytes(w,e->text,1);}
  else if(e->unshifted && (o->macos || !e->text_length)){put(w,27);codepoint(w,e->unshifted);}
  else if(e->text_length){put(w,27);bytes(w,e->text,e->text_length);}
  else return false;return true;
}
static void legacy(writer *w,const bkey_event *e,const bkey_options *o,unsigned binding,uint32_t first,size_t count){
  if(e->action==BK_RELEASE || e->composing)return;
  bool ime=e->text_length && !(e->text_length==1 && control(first));
  if(ime && e->key==BK_BACKSPACE)return;
  if(!(ime && (e->key==BK_ENTER || e->key==BK_ESCAPE)) && pc(w,e,o))return;
  unsigned m=e->modifiers&63;if(o->macos && !option_alt(e,o))m&=~BI_ALT;
  if(o->modify_other_keys_2 && count==1 && m && m<16 && ((first>=64 && first<=127) || (m&~BI_SHIFT) || first==' ')){modify(w,m,first);return;}
  int c=ctrl(e);if(c>=0){if(binding&BI_ALT)put(w,27);put(w,(uint8_t)c);return;}
  if(!e->text_length){alt(w,e,o,binding);return;}
  if((e->modifiers&BI_CTRL) && count==1){unsigned mods=e->modifiers&7;uint32_t cp=first;if(cp>='A' && cp<='Z' && (mods&BI_SHIFT))cp+=32;if(e->unshifted!=cp)mods&=~BI_SHIFT;csi(w);number(w,cp);put(w,';');number(w,mods+1);put(w,'u');return;}
  if(alt(w,e,o,binding))return;
  if(o->macos && (e->modifiers&BI_SUPER))return;
  bytes(w,e->text,e->text_length);
}
static void kitty(writer *w,const bkey_event *e,const bkey_options *o,unsigned binding,uint32_t first,size_t count,bool printable){
  unsigned flags=o->kitty_flags;bool all=(flags&BK_ALL)!=0;
  if(e->action==BK_RELEASE && (!(flags&BK_EVENTS) || (!all && (e->key==BK_ENTER || e->key==BK_TAB || e->key==BK_BACKSPACE))))return;
  uint32_t cp=0;uint8_t final='u';bool modifier=false;bool found=functional(e->key,&cp,&final,&modifier);
  if(!found && e->unshifted){cp=e->unshifted;found=true;}
  if(e->composing && !modifier)return;
  if(e->text_length && !(e->text_length==1 && control(first)) && (e->key==BK_ENTER || e->key==BK_BACKSPACE)){if(e->key==BK_ENTER)bytes(w,e->text,e->text_length);return;}
  if(!all){
    if(!binding && (e->key==BK_ENTER || e->key==BK_TAB || e->key==BK_BACKSPACE)){put(w,e->key==BK_ENTER?13:e->key==BK_TAB?9:127);return;}
    if(e->text_length && !binding && e->action!=BK_RELEASE && printable){bytes(w,e->text,e->text_length);return;}
  }
  if(!found){if(e->action!=BK_RELEASE)bytes(w,e->text,e->text_length);return;}
  if(modifier && !all)return;
  unsigned mods=e->modifiers+1,event=(flags&BK_EVENTS)?e->action+1:0;
  csi(w);
  if(final!='u' && final!='~'){
    if(event || mods>1){number(w,1);put(w,';');number(w,mods);if(event){put(w,':');number(w,event);}}put(w,final);return;
  }
  number(w,cp);
  if((flags&BK_ALTERNATES) && !control(cp)){
    bool shifted=count && first!=cp && (e->modifiers&BI_SHIFT);
    if(shifted){put(w,':');number(w,first);}
    if(e->base_layout && e->base_layout!=cp && (!count || (count==1 && first!=e->base_layout))){put(w,':');if(!shifted)put(w,':');number(w,e->base_layout);}
  }
  bool prior=false;
  if(event>1){put(w,';');number(w,mods);put(w,':');number(w,event);prior=true;}
  else if(mods>1){put(w,';');number(w,mods);prior=true;}
  if((flags&BK_ASSOCIATED) && e->action!=BK_RELEASE && !(e->modifiers&(BI_CTRL|BI_SUPER|BI_HYPER|BI_META)) && (!(e->modifiers&BI_ALT) || !option_alt(e,o))){
    size_t i=0;bool initial=true;while(i<e->text_length){uint32_t t;next(e->text,e->text_length,&i,&t);if(control(t) || (t>=128 && t<=159))continue;if(initial){if(!prior)put(w,';');put(w,';');initial=false;}else put(w,':');number(w,t);}
  }
  put(w,final);
}
bool bkey_encode(const bkey_event *e,const bkey_options *o,uint8_t *output,size_t capacity,size_t *length){
  *length=0;
  if((unsigned)e->key>=BK_COUNT || (unsigned)e->action>BK_RELEASE || e->modifiers>255 || e->consumed_modifiers>255 || e->right_modifiers>15 || !scalar(e->unshifted) || !scalar(e->base_layout) || (unsigned)o->option_as_alt>BK_OPTION_RIGHT || o->kitty_flags>31 || e->text_length>BKEY_TEXT_LIMIT || (!e->text && e->text_length))return false;
  size_t i=0,count=0;uint32_t first=0;bool printable=true;
  while(i<e->text_length){uint32_t cp;if(!next(e->text,e->text_length,&i,&cp))return false;if(!count)first=cp;count++;if(control(cp))printable=false;}
  unsigned binding=(e->modifiers&~(e->text_length?e->consumed_modifiers:0))&63;
  writer w={NULL,0};if(o->kitty_flags)kitty(&w,e,o,binding,first,count,printable);else legacy(&w,e,o,binding,first,count);
  if(w.length>capacity || (w.length && !output))return false;
  size_t n=w.length;w=(writer){output,0};if(o->kitty_flags)kitty(&w,e,o,binding,first,count,printable);else legacy(&w,e,o,binding,first,count);*length=n;return true;
}
