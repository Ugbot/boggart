#include "bterm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static void feed(bterm *t,const char *s) { CHECK(bterm_feed(t,(const uint8_t *)s,strlen(s))); }
static void glyph(bterm *t,size_t y,size_t x,unsigned width,const uint32_t *cps,size_t n) {
  const lpage_screen *s=bterm_screen(t);const lpage_cell *c=lpage_get(s,y,x); CHECK(c && c->width==width);
  lgrapheme_value v=lpage_grapheme(s,c);CHECK(v.length==n && (!n || !memcmp(cps,v.codepoints,n*sizeof *cps)));
  if(width==2) CHECK(lpage_get(s,y,x+1)->flags & LP_CELL_WIDE_TAIL);
}
#define GLYPH(t,y,x,w,...) do { const uint32_t cps[]={__VA_ARGS__}; glyph(t,y,x,w,cps,sizeof cps/sizeof *cps); } while(0)
static void equal_rows(bterm *a,bterm *b,const lpage_row *ra,const lpage_row *rb) {
  CHECK(ra->columns==rb->columns && ra->wrapped==rb->wrapped);
  for(size_t x=0;x<ra->columns;x++) {
    const lpage_cell *ca=&ra->cells[x],*cb=&rb->cells[x];
    CHECK(ca->width==cb->width && ca->flags==cb->flags);
    lgrapheme_value va=lpage_grapheme(bterm_screen(a),ca),vb=lpage_grapheme(bterm_screen(b),cb);
    CHECK(va.length==vb.length && (!va.length || !memcmp(va.codepoints,vb.codepoints,va.length*sizeof(uint32_t))));
    const lpage_style *sa=bterm_style(a,ca->style),*sb=bterm_style(b,cb->style); CHECK(!memcmp(sa,sb,sizeof *sa));
    const llink_value *la=bterm_link(a,ca->hyperlink),*lb=bterm_link(b,cb->hyperlink);
    CHECK((la!=NULL)==(lb!=NULL));
    if(la) CHECK(la->key_length==lb->key_length && la->uri_length==lb->uri_length && !memcmp(la->key,lb->key,la->key_length) && !memcmp(la->uri,lb->uri,la->uri_length));
  }
}
static void equal(bterm *a,bterm *b) {
  bterm_status sa=bterm_state(a),sb=bterm_state(b);
  CHECK(sa.x==sb.x && sa.y==sb.y && sa.pending_wrap==sb.pending_wrap && sa.modes==sb.modes && sa.alternate==sb.alternate);
  const lpage_screen *pa=bterm_screen(a),*pb=bterm_screen(b); CHECK(lpage_history_count(pa)==lpage_history_count(pb));
  for(size_t y=0;y<lpage_rows(pa);y++)equal_rows(a,b,lpage_visible(pa,y),lpage_visible(pb,y));
  for(size_t y=0;y<lpage_history_count(pa);y++)equal_rows(a,b,lpage_history(pa,y),lpage_history(pb,y));
}
static void vectors(void) {
  bterm *t=bterm_create(6,3,2,NULL,NULL); CHECK(t);
  feed(t,"a日b");GLYPH(t,0,1,2,0x65e5); CHECK(bterm_state(t).x==4);
  CHECK(bterm_reset(t));feed(t,"é");GLYPH(t,0,0,1,'e',0x301);CHECK(bterm_state(t).x==1);
  feed(t,"\033[H́");GLYPH(t,0,0,1,'e',0x301); /* no base to the left */
  feed(t,"\033[2G̀");GLYPH(t,0,0,1,'e',0x301,0x300); /* existing cell association */
  CHECK(bterm_reset(t));feed(t,"👩‍💻🇬🇧");GLYPH(t,0,0,2,0x1f469,0x200d,0x1f4bb);GLYPH(t,0,2,2,0x1f1ec,0x1f1e7);
  CHECK(bterm_state(t).x==4 && lpage_usage(bterm_screen(t)).graphemes==2);
  CHECK(bterm_reset(t));feed(t,"❤️⌚︎");GLYPH(t,0,0,2,0x2764,0xfe0f);GLYPH(t,0,2,1,0x231a,0xfe0e);CHECK(bterm_state(t).x==3);
  CHECK(bterm_reset(t));feed(t,"a️️");GLYPH(t,0,0,1,'a');CHECK(!lpage_usage(bterm_screen(t)).graphemes);
  CHECK(bterm_reset(t));feed(t,"abcde日");CHECK(lpage_visible(bterm_screen(t),0)->wrapped);
  CHECK(lpage_get(bterm_screen(t),0,5)->flags==LP_CELL_WIDE_HEAD);GLYPH(t,1,0,2,0x65e5);
  CHECK(bterm_reset(t));feed(t,"abcde❤️");CHECK(lpage_get(bterm_screen(t),0,5)->flags==LP_CELL_WIDE_HEAD);GLYPH(t,1,0,2,0x2764,0xfe0f);
  CHECK(bterm_reset(t));feed(t,"abcd⌚︎");GLYPH(t,0,4,1,0x231a,0xfe0e);CHECK(bterm_state(t).x==5 && !bterm_state(t).pending_wrap);
  CHECK(bterm_reset(t));feed(t,"abcde\033[?7l日");glyph(t,0,5,1,NULL,0);CHECK(bterm_state(t).x==5);
  feed(t,"\033[b");glyph(t,0,5,1,NULL,0); /* REP keeps the ignored wide base */
  feed(t,"❤️");GLYPH(t,0,5,1,0x2764); /* cannot widen at a disabled wrap boundary */
  CHECK(bterm_reset(t));feed(t,"\033[?2027l👩‍💻");GLYPH(t,0,0,2,0x1f469,0x200d);GLYPH(t,0,2,2,0x1f4bb);CHECK(bterm_state(t).x==4);
  CHECK(bterm_reset(t));feed(t,"각क्क");GLYPH(t,0,0,2,0x1100,0x1161,0x11a8);GLYPH(t,0,2,2,0x915,0x94d,0x915);
  CHECK(bterm_reset(t));feed(t,"e\033[31ḿ\033[2b");GLYPH(t,0,0,1,'e',0x301);GLYPH(t,0,1,1,'e');GLYPH(t,0,2,1,'e');
  bterm_destroy(t);
  t=bterm_create(1,1,1,NULL,NULL); CHECK(t);feed(t,"日");glyph(t,0,0,1,NULL,0);CHECK(bterm_state(t).pending_wrap);
  feed(t,"\033[b");CHECK(lpage_history_count(bterm_screen(t))==1);glyph(t,0,0,1,NULL,0);bterm_destroy(t);
  /* The widened cluster must survive recycling its original row, including
   * its existing suffix, style and hyperlink references. */
  t=bterm_create(3,1,0,NULL,NULL);CHECK(t);
  feed(t,"ab\033[31m\033]8;id=wide;https://example.com\a❤‍\033[32m👩");
  GLYPH(t,0,0,2,0x2764,0x200d,0x1f469);
  const lpage_cell *c=lpage_get(bterm_screen(t),0,0);
  CHECK(bterm_style(t,c->style)->fg==(LP_COLOR_INDEXED|1) && bterm_link(t,c->hyperlink));
  CHECK(lpage_usage(bterm_screen(t)).graphemes==1);bterm_destroy(t);
}
static void fragmentation(void) {
  const char *stream="abcde❤️\r\n👩‍💻🇬🇧é각\r\n\033[38;2;1;2;3m⌚︎\033[0m"
    "\033]8;id=unicode;https://example.com\aक्क👍🏿\033]8;;\a\033[?1049h👨‍👩‍👧‍👦\033[?1049l"
    "\033[H\033[2@日\033[2P\033[?2027l👩‍💻\033[?2027hé\xff\xe2"
    "\r\n\u05c6\u0301\u05c8\u05c9Z\u0995\u1cf5\u0995";
  size_t length=strlen(stream); bterm *full=bterm_create(6,3,4,NULL,NULL);CHECK(full);feed(full,stream);CHECK(bterm_finish(full));
  for(size_t cut=0;cut<=length;cut++) {
    bterm *t=bterm_create(6,3,4,NULL,NULL);CHECK(t);
    CHECK(bterm_feed(t,(const uint8_t *)stream,cut) && bterm_feed(t,(const uint8_t *)stream+cut,length-cut) && bterm_finish(t));equal(full,t);bterm_destroy(t);
  }
  bterm *t=bterm_create(6,3,4,NULL,NULL);CHECK(t);
  for(size_t i=0;i<length;i++)CHECK(bterm_feed(t,(const uint8_t *)stream+i,1));CHECK(bterm_finish(t));equal(full,t);bterm_destroy(t);bterm_destroy(full);
}
static void lifetime(void) {
  bterm *t=bterm_create(6,2,3,NULL,NULL);CHECK(t);feed(t,"e");
  for(unsigned i=0;i<10000;i++)feed(t,"́");
  CHECK(lpage_grapheme(bterm_screen(t),lpage_get(bterm_screen(t),0,0)).length==LG_LIMIT);
  CHECK(bterm_state(t).x==1);
  CHECK(bterm_reset(t));
  for(unsigned i=0;i<10000;i++) {
    feed(t,"👩‍💻\r\n");
    if(i>=3)CHECK(lpage_usage(bterm_screen(t)).graphemes==4);
  }
  CHECK(bterm_reset(t));CHECK(!lpage_usage(bterm_screen(t)).graphemes);bterm_destroy(t);
}
int main(void) { vectors();fragmentation();lifetime();puts("terminal Unicode cells, margins, byte splits and lifetime passed");return 0; }
