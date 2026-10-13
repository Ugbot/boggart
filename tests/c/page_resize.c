#include "lpage.h"
#include "lpage_internal.h"
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static void ownership(void) {
  lpage_screen *s=lpage_create(6,3,17); CHECK(s);
  uint32_t style,link;
  CHECK(lstyle_acquire(lpage_styles(s),&(lpage_style){LP_COLOR_INDEXED|1,0,0,LP_BOLD},&style));
  CHECK(llink_acquire(lpage_links(s),&(llink_value){"key","uri",3,3},&link));
  CHECK(lpage_put(s,0,0,(lpage_cell){'e',style,link,1,0,0}));
  CHECK(lpage_append_grapheme(s,0,0,0x301,1));
  uint32_t gp=lpage_get(s,0,0)->codepoint;
  lpage_cell cell=*lpage_get(s,0,0);
  CHECK(lpage_put(s,2,0,cell));
  CHECK(lpage_scroll(s,0,2,1,true,0));
  lpage_ack_damage(s);
  size_t refs=lstyle_refs(lpage_styles(s),style);
  lpage_resize *r=lpage_resize_prepare(s,(lpage_resize_options){4,2,false,true,{1,1,false},{0,0,false},false});
  CHECK(r && lpage_columns(s)==6 && lpage_rows(s)==3 && !lpage_dirty(s,0));
  CHECK(lstyle_refs(lpage_styles(s),style)==refs+2 && lgrapheme_refs(lpage_graphemes(s),gp)==4);
  lpage_resize_abort(r);
  CHECK(lstyle_refs(lpage_styles(s),style)==refs && lgrapheme_refs(lpage_graphemes(s),gp)==2);
  r=lpage_resize_prepare(s,(lpage_resize_options){4,2,false,true,{1,1,false},{0,0,false},false});
  CHECK(r); lpage_position p=lpage_resize_cursor(r);
  CHECK(p.x==1 && p.y==1);
  lpage_resize_commit(r);
  CHECK(lpage_columns(s)==4 && lpage_rows(s)==2 && lpage_dirty(s,0));
  CHECK(lpage_history_count(s)==1 && lgrapheme_refs(lpage_graphemes(s),gp)==2);
  CHECK(lpage_codepoint(s,&lpage_history(s,0)->cells[0])=='e');
  CHECK(lpage_grapheme(s,lpage_get(s,1,0)).length==2);
  lstyle_release(lpage_styles(s),style); llink_release(lpage_links(s),link);
  lpage_destroy(s);
}
static void cached_capacity(void) {
  lpage_screen *s=lpage_create(6,3,0); CHECK(s);
  for (size_t x=0;x<6;x++) CHECK(lpage_put(s,0,x,(lpage_cell){'a'+(uint32_t)x,0,0,1,0,0}));
  lpage_wrap(s,0,true);
  size_t original_bytes=lpage_usage(s).bytes;
  const size_t widths[]={4,5,3,6,8};
  for (size_t i=0;i<sizeof widths/sizeof *widths;i++) {
    lpage_resize *r=lpage_resize_prepare(s,(lpage_resize_options){widths[i],3,false,true,{0,0,false},{0,0,false},false});
    CHECK(r); lpage_resize_commit(r);
    CHECK(lp_row_capacity(s,0)==(widths[i]<=6 ? 6 : 8));
    CHECK(lpage_visible(s,0)->wrapped==(widths[i]<=6));
    CHECK(lpage_usage(s).bytes==(widths[i]<=6 ? original_bytes : original_bytes+16*2*sizeof(lpage_cell)));
    for (size_t x=(i<2 ? 4 : 3);x<widths[i];x++) CHECK(!lpage_get(s,0,x)->codepoint);
  }
  lpage_destroy(s);
}
static void heads(void) {
  for (unsigned op=0;op<6;op++) {
    lpage_screen *s=lpage_create(4,2,2); CHECK(s);
    lpage_wrap(s,0,true);
    CHECK(lpage_put(s,0,3,(lpage_cell){0,0,0,1,LP_CELL_WIDE_HEAD,0}));
    CHECK(lpage_put(s,1,0,(lpage_cell){0x65e5,0,0,2,0,0}));
    CHECK(lpage_append_grapheme(s,1,0,0x301,2));
    CHECK(lpage_get(s,0,3)->flags&LP_CELL_WIDE_HEAD);
    if (op==0) CHECK(lpage_put(s,1,1,(lpage_cell){'Z',0,0,1,0,0}));
    if (op==1) CHECK(lpage_erase(s,1,1,1,0));
    if (op==2) CHECK(lpage_insert_cells(s,1,1,1,0));
    if (op==3) CHECK(lpage_delete_cells(s,1,1,1,0));
    if (op==4) {
      CHECK(lpage_scroll(s,0,1,1,true,0));
      CHECK(lpage_put(s,0,1,(lpage_cell){'Z',0,0,1,0,0}));
      CHECK(!(lpage_history(s,0)->cells[3].flags&LP_CELL_WIDE_HEAD));
    } else if (op==5) CHECK(lpage_append_grapheme(s,1,0,0xfe0e,1));
    if (op!=4) CHECK(!(lpage_get(s,0,3)->flags&LP_CELL_WIDE_HEAD));
    lpage_destroy(s);
  }
}
static uint32_t seed=0x8a220b61;
static unsigned random_value(void) { seed^=seed<<13; seed^=seed>>17; return seed^=seed<<5; }
static void inspect(lpage_screen *s,uint32_t style,uint32_t link,uint32_t gp,size_t limit) {
  size_t styles=0,links=0,graphemes=0,history=lpage_history_count(s);
  CHECK(history<=limit);
  for (size_t y=0;y<history+lpage_rows(s);y++) {
    const lpage_row *row=y<history ? lpage_history(s,y) : lpage_visible(s,y-history);
    for (size_t x=0;x<row->columns;x++) {
      const lpage_cell *c=&row->cells[x];
      if (c->style==style) styles++;
      if (c->hyperlink==link) links++;
      if (c->flags&LP_CELL_GRAPHEME) { CHECK(c->codepoint==gp); graphemes++; }
      if (c->width==2) CHECK(x+1<row->columns && row->cells[x+1].flags&LP_CELL_WIDE_TAIL);
      if (c->flags&LP_CELL_WIDE_TAIL) CHECK(x && row->cells[x-1].width==2 && !c->codepoint && !c->width);
      if (c->flags&LP_CELL_WIDE_HEAD) CHECK(x+1==row->columns && row->wrapped && !c->codepoint);
    }
  }
  CHECK(lstyle_refs(lpage_styles(s),style)==styles+1);
  CHECK(llink_refs(lpage_links(s),link)==links+1);
  CHECK(lgrapheme_refs(lpage_graphemes(s),gp)==graphemes+1);
}
static void bounded(void) {
  const size_t limits[]={0,1,17};
  for (unsigned index=0;index<3;index++) {
    size_t limit=limits[index]; lpage_screen *s=lpage_create(6,3,limit); CHECK(s);
    uint32_t style,link,gp,cps[]={0x65e5,0x301};
    CHECK(lstyle_acquire(lpage_styles(s),&(lpage_style){LP_COLOR_INDEXED|1,0,0,LP_BOLD},&style));
    CHECK(llink_acquire(lpage_links(s),&(llink_value){"key","uri",3,3},&link));
    CHECK(lgrapheme_acquire(lpage_graphemes(s),cps,2,&gp));
    for (unsigned step=0;step<3000;step++) {
      size_t rows=lpage_rows(s),columns=lpage_columns(s);
      CHECK(lpage_put(s,rows-1,0,(lpage_cell){gp,style,link,columns>1 ? 2 : 1,LP_CELL_GRAPHEME,0}));
      CHECK(lpage_scroll(s,0,rows-1,1,true,0));
      inspect(s,style,link,gp,limit);
      lpage_resize_options opts={1+random_value()%13,1+random_value()%7,(step&1)!=0,(step&2)!=0,
        {0,rows-1,false},{0,0,false},false};
      lpage_resize *r=lpage_resize_prepare(s,opts); CHECK(r);
      if (step%7) lpage_resize_commit(r); else lpage_resize_abort(r);
      inspect(s,style,link,gp,limit);
    }
    lpage_clear_history(s);
    for (size_t y=0;y<lpage_rows(s);y++) CHECK(lpage_erase(s,y,0,lpage_columns(s),0));
    CHECK(lstyle_refs(lpage_styles(s),style)==1 && llink_refs(lpage_links(s),link)==1 && lgrapheme_refs(lpage_graphemes(s),gp)==1);
    lstyle_release(lpage_styles(s),style); llink_release(lpage_links(s),link); lgrapheme_release(lpage_graphemes(s),gp);
    CHECK(lpage_usage(s).styles==1 && !lpage_usage(s).links && !lpage_usage(s).graphemes);
    lpage_destroy(s);
  }
}
int main(void) { ownership(); cached_capacity(); heads(); bounded(); puts("resize ownership, wide heads, bounded history and 9000 mixed resizes passed"); return 0; }
