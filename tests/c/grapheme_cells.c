#include "lpage.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static void content(lpage_screen *s, size_t x, const uint32_t *cps, size_t length) {
  const lpage_cell *c=lpage_get(s,0,x); lgrapheme_value v=lpage_grapheme(s,c);
  CHECK(v.length==length && (!length || !memcmp(v.codepoints,cps,length*sizeof *cps)));
  CHECK(lpage_codepoint(s,c)==(length ? cps[0] : 0));
}
static void pool(void) {
  lgrapheme_pool *p=lgrapheme_create(); CHECK(p);
  uint32_t original, copy, next; const uint32_t cps[]={'e',0x301};
  CHECK(lgrapheme_acquire(p,cps,2,&original));
  CHECK(lgrapheme_retain(p,original)); copy=original;
  CHECK(lgrapheme_append(p,original,0x300,&next) && next!=original);
  CHECK(lgrapheme_get(p,original).length==2 && lgrapheme_get(p,next).length==3);
  lgrapheme_release(p,copy); lgrapheme_release(p,original);
  CHECK(!lgrapheme_get(p,original).length && lgrapheme_count(p)==1);
  original=next;
  CHECK(lgrapheme_append(p,original,0x302,&next) && next==original);
  CHECK(lgrapheme_refs(p,next)==2 && lgrapheme_get(p,next).length==4);
  lgrapheme_release(p,original);
  for (unsigned i=0;i<1000;i++) {
    CHECK(lgrapheme_append(p,next,0x301,&original)); lgrapheme_release(p,next); next=original;
  }
  CHECK(lgrapheme_get(p,next).length==LG_LIMIT);
  lgrapheme_release(p,next); CHECK(!lgrapheme_count(p));
  size_t warm=lgrapheme_bytes(p);
  for (unsigned i=0;i<10000;i++) {
    CHECK(lgrapheme_acquire(p,cps,2,&next)); lgrapheme_release(p,next);
  }
  CHECK(lgrapheme_bytes(p)==warm);
  CHECK(!lgrapheme_acquire(p,NULL,0,&next));
  const uint32_t invalid[]={0xd800}; CHECK(!lgrapheme_acquire(p,invalid,1,&next));
  lgrapheme_destroy(p);
}
static void cells(void) {
  lpage_screen *s=lpage_create(6,1,2); CHECK(s && sizeof(lpage_cell)==16);
  CHECK(lpage_put(s,0,0,(lpage_cell){'e',0,0,1,0,0}));
  CHECK(lpage_append_grapheme(s,0,0,0x301,1));
  const uint32_t first[]={'e',0x301}, second[]={'e',0x301,0x300};
  content(s,0,first,2);
  lpage_cell copy=*lpage_get(s,0,0); uint32_t original=copy.codepoint;
  CHECK(lpage_put(s,0,2,copy));
  CHECK(lgrapheme_refs(lpage_graphemes(s),original)==2);
  CHECK(lpage_append_grapheme(s,0,0,0x300,2)); content(s,0,second,3); content(s,2,first,2);
  CHECK(lpage_get(s,0,1)->flags==LP_CELL_WIDE_TAIL);
  CHECK(lgrapheme_refs(lpage_graphemes(s),original)==1);
  CHECK(lpage_append_grapheme(s,0,0,0x302,1));
  CHECK(lpage_get(s,0,1)->width==1 && !lpage_get(s,0,1)->codepoint);
  CHECK(lpage_insert_cells(s,0,0,1,0)); content(s,3,first,2);
  CHECK(lpage_delete_cells(s,0,0,1,0)); content(s,2,first,2);
  CHECK(lpage_erase(s,0,2,1,0)); CHECK(!lgrapheme_get(lpage_graphemes(s),original).length);
  CHECK(lpage_append_grapheme(s,0,0,0x303,2));
  CHECK(lpage_erase(s,0,1,1,0)); CHECK(!lgrapheme_count(lpage_graphemes(s)));
  CHECK(!lpage_append_grapheme(s,0,0,0x301,1));
  CHECK(lpage_put(s,0,5,(lpage_cell){'x',0,0,1,0,0}));
  CHECK(!lpage_append_grapheme(s,0,5,0xfe0f,2)); content(s,5,(const uint32_t[]){'x'},1);
  CHECK(!lpage_put(s,0,0,(lpage_cell){99999,0,0,1,LP_CELL_GRAPHEME,0}));
  lpage_destroy(s);
}
static void history(void) {
  lpage_screen *s=lpage_create(8,2,3); CHECK(s);
  for (unsigned i=0;i<10000;i++) {
    CHECK(lpage_put(s,1,0,(lpage_cell){0x1f469,0,0,2,0,0}));
    CHECK(lpage_append_grapheme(s,1,0,0x200d,2)); CHECK(lpage_append_grapheme(s,1,0,0x1f4bb,2));
    CHECK(lpage_scroll(s,0,1,1,true,0));
    size_t expected=lpage_history_count(s)+1;
    if(i+1<expected) expected=i+1;
    CHECK(lgrapheme_count(lpage_graphemes(s))==expected);
    for(size_t y=0;y<lpage_history_count(s);y++) {
      lgrapheme_value v=lpage_grapheme(s,&lpage_history(s,y)->cells[0]);
      if(v.length) CHECK(v.length==3 && v.codepoints[2]==0x1f4bb);
    }
    if(i==100) {
      size_t bytes=lpage_usage(s).bytes;
      for(unsigned j=0;j<1000;j++) {
        CHECK(lpage_put(s,1,0,(lpage_cell){0x1f469,0,0,2,0,0}));
        CHECK(lpage_append_grapheme(s,1,0,0x200d,2)); CHECK(lpage_append_grapheme(s,1,0,0x1f4bb,2));
        CHECK(lpage_scroll(s,0,1,1,true,0)); CHECK(lpage_usage(s).bytes==bytes);
      }
    }
  }
  lpage_clear_history(s); CHECK(lgrapheme_count(lpage_graphemes(s))==1);
  CHECK(lpage_erase(s,0,0,8,0)); CHECK(!lgrapheme_count(lpage_graphemes(s)));
  lpage_destroy(s);
}
int main(void) { pool(); cells(); history(); puts("grapheme copy-on-write, bounds and history ownership passed"); return 0; }
