#include "btunicode.h"
#include "bterm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#define CHECK(c) do{if(!(c)){fprintf(stderr,"line %d: %s\n",__LINE__,#c);exit(1);}}while(0)
static int cell_width(const char *s,size_t n,bool grapheme,size_t split) {
  bterm *t=bterm_create(128,1,0,NULL,NULL);CHECK(t);
  if(!grapheme)CHECK(bterm_feed(t,(const uint8_t *)"\033[?2027l",8));
  CHECK(bterm_feed(t,(const uint8_t *)s,split) && bterm_feed(t,(const uint8_t *)s+split,n-split) && bterm_finish(t));
  const lpage_screen *screen=bterm_screen(t);int width=0;
  for(size_t x=0;x<128;x++){const lpage_cell *c=lpage_get(screen,0,x);if(lpage_codepoint(screen,c))width+=c->width;}
  bterm_destroy(t);return width;
}
static void vector(const char *s,size_t n,bool grapheme) {
  int expected=cell_width(s,n,grapheme,n);CHECK(btunicode_text_width(s,n,grapheme)==expected);
  bterm *t=bterm_create(128,1,0,NULL,NULL);CHECK(t);
  if(!grapheme)CHECK(bterm_feed(t,(const uint8_t *)"\033[?2027l",8));
  CHECK(bterm_feed(t,(const uint8_t *)s,n));size_t position=0,column=0;
  const lpage_screen *screen=bterm_screen(t);
  while(position<n) {
    btunicode_text_cluster cluster;size_t bytes=btunicode_text_next(s+position,n-position,grapheme,&cluster);
    CHECK(bytes && bytes<=n-position && cluster.length<=sizeof cluster.text);position+=bytes;
    if(!cluster.width){CHECK(!cluster.length);continue;}
    const lpage_cell *cell=lpage_get(screen,0,column);CHECK(cell && cell->width==cluster.width);
    lgrapheme_value value=lpage_grapheme(screen,cell);char encoded[LG_LIMIT*4];size_t length=0;
    for(size_t i=0;i<value.length;i++)length+=bunicode_utf8_put(value.codepoints[i],encoded+length);
    CHECK(length==cluster.length && !memcmp(encoded,cluster.text,length));column+=cluster.width;
  }
  CHECK(column==(size_t)expected);bterm_destroy(t);
  for(size_t cut=0;cut<=n;cut++)CHECK(cell_width(s,n,grapheme,cut)==expected);
  size_t previous=0;
  for(int budget=0;budget<=expected+2;budget++) {
    int used=-1;size_t taken=btunicode_text_take(s,n,budget,grapheme,&used);
    CHECK(taken>=previous && taken<=n && used<=budget);
    CHECK(btunicode_text_width(s,taken,grapheme)==used && cell_width(s,taken,grapheme,taken)==used);
    if(taken<n){int next_used;size_t next=btunicode_text_take(s,n,used+1,grapheme,&next_used);CHECK(next>=taken);}
    previous=taken;
  }
  CHECK(previous==n);
}
int main(void) {
  const char *cases[]={"abc日éΩ","👩‍💻X","🇬🇧🇺🇸X","❤️⌚︎X","क्क👍🏿X","각X",
    "a️️X","\u05c6\u0301\u05c8\u05c9Z","\u0995\u1cf5\u0995X","́a","a‍b","\xc2\x80\xc2\xa0"};
  for(unsigned mode=0;mode<2;mode++) {
    for(size_t i=0;i<sizeof cases/sizeof *cases;i++)vector(cases[i],strlen(cases[i]),mode!=0);
    const char nul[]={'a',0,'b'};vector(nul,sizeof nul,mode!=0);
    const char heart_nul[]={0xe2,0x9d,0xa4,0,0xef,0xb8,0x8f};vector(heart_nul,sizeof heart_nul,mode!=0);
    char capped[512]="e";size_t length=1;
    for(unsigned i=0;i<100;i++){memcpy(capped+length,"́",2);length+=2;}capped[length++]='X';vector(capped,length,mode!=0);
  }
  CHECK(btunicode_text_width("👩‍💻",strlen("👩‍💻"),true)==2);
  CHECK(btunicode_text_width("👩‍💻",strlen("👩‍💻"),false)==4);
  CHECK(btunicode_text_width("\x80\xe2\x82",3,true)==3);
  int used=99;
  CHECK(btunicode_text_take("👩‍💻X",strlen("👩‍💻X"),2,true,&used)==strlen("👩‍💻") && used==2);
  CHECK(btunicode_text_take("🇬🇧X",strlen("🇬🇧X"),1,true,&used)==0 && used==0);
  CHECK(btunicode_text_take("⌚︎X",strlen("⌚︎X"),1,true,&used)==strlen("⌚︎") && used==1);
  CHECK(btunicode_text_take("❤️X",strlen("❤️X"),1,true,&used)==0 && used==0);
  CHECK(btunicode_text_take("éX",4,1,true,&used)==3 && used==1);
  CHECK(btunicode_text_take("\x80\xe2\x82",3,2,true,&used)==2 && used==2);
  CHECK(btunicode_text_take(NULL,0,0,true,&used)==0 && used==0);
  CHECK(btunicode_text_take("X",1,-1,true,&used)==0 && used==0);
  CHECK(btunicode_text_take("a日b",5,INT_MAX,true,&used)==5 && used==4);
  btunicode_text_cluster empty;CHECK(!btunicode_text_next(NULL,0,true,&empty) && !empty.width && !empty.length);
  char encoded[4];CHECK(!bunicode_utf8_put('A',NULL));
  CHECK(bunicode_utf8_put(0,encoded)==1 && !encoded[0]);
  CHECK(bunicode_utf8_put(0xd800,encoded)==3 && !memcmp(encoded,"\xef\xbf\xbd",3));
  CHECK(bunicode_utf8_put(0x110000,encoded)==3 && !memcmp(encoded,"\xef\xbf\xbd",3));
  puts("terminal text: native cell/mode parity, all byte splits and prefix budgets, selectors/caps/profile and bounded UTF-8 pass");return 0;
}
