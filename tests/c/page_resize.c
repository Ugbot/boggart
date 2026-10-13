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
static void height_transfer(void) {
  const size_t limits[]={0,1,17};
  for (unsigned i=0;i<3;i++) {
    lpage_screen *s=lpage_create(6,3,limits[i]); CHECK(s);
    uint32_t style,link,gp,cps[]={'e',0x301};
    CHECK(lstyle_acquire(lpage_styles(s),&(lpage_style){LP_COLOR_INDEXED|2,0,0,LP_BOLD},&style));
    CHECK(llink_acquire(lpage_links(s),&(llink_value){"height","https://height",6,14},&link));
    CHECK(lgrapheme_acquire(lpage_graphemes(s),cps,2,&gp));
    for (unsigned line=0;line<12;line++) {
      CHECK(lpage_put(s,2,0,(lpage_cell){gp,style,link,1,LP_CELL_GRAPHEME,0}));
      CHECK(lpage_scroll(s,0,2,1,true,0));
    }
    const lpage_cell *kept=lpage_visible(s,1)->cells;
    size_t refs=lgrapheme_refs(lpage_graphemes(s),gp);
    lpage_resize_options opts={6,2,false,true,{0,1,false},{0,0,false},true};
    lpage_resize *r=lpage_resize_prepare(s,opts); CHECK(r);
    CHECK(lpage_visible(s,1)->cells==kept && lgrapheme_refs(lpage_graphemes(s),gp)==refs);
    lpage_resize_abort(r); CHECK(lpage_visible(s,1)->cells==kept && lgrapheme_refs(lpage_graphemes(s),gp)==refs);
    r=lpage_resize_prepare(s,opts); CHECK(r); lpage_resize_commit(r);
    CHECK(lpage_visible(s,1)->cells==kept && lpage_get(s,1,0)->codepoint==gp);
    refs=lgrapheme_refs(lpage_graphemes(s),gp); size_t pages=lpage_usage(s).pages;
    r=lpage_resize_prepare(s,(lpage_resize_options){6,4,false,false,{0,1,false},{0,0,false},false}); CHECK(r);
    CHECK(lgrapheme_refs(lpage_graphemes(s),gp)==refs); lpage_resize_commit(r);
    CHECK(lpage_visible(s,1)->cells==kept && !lpage_get(s,2,0)->codepoint && !lpage_get(s,3,0)->codepoint);
    CHECK(lgrapheme_refs(lpage_graphemes(s),gp)==refs && lpage_usage(s).pages==pages);
    /* Width changes still copy independently after the ownership transfer. */
    r=lpage_resize_prepare(s,(lpage_resize_options){4,4,false,true,{0,1,false},{0,0,false},false}); CHECK(r);
    lpage_resize_commit(r); CHECK(lpage_get(s,1,0)->codepoint==gp && lp_row_capacity(s,lpage_history_count(s)+1)==6);
    lpage_clear_history(s);
    for (size_t y=0;y<4;y++) CHECK(lpage_erase(s,y,0,4,0));
    /* Erased/free slots may contain stale grapheme flags; a loan commit must
     * release only live ownership, never those stale values. */
    r=lpage_resize_prepare(s,(lpage_resize_options){4,2,false,true,{0,0,false},{0,0,false},false}); CHECK(r);
    lpage_resize_commit(r);
    CHECK(lgrapheme_refs(lpage_graphemes(s),gp)==1 && lstyle_refs(lpage_styles(s),style)==1 && llink_refs(lpage_links(s),link)==1);
    lgrapheme_release(lpage_graphemes(s),gp); lstyle_release(lpage_styles(s),style); llink_release(lpage_links(s),link);
    lpage_destroy(s);
  }
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
static void group_boundaries(void) {
  lpage_screen *s=lpage_create(215,300,2000); CHECK(s);
  lp_group_span first,second; CHECK(lp_row_group(s,0,&first));
  CHECK(first.first==0 && first.rows==first.capacity.rows && first.capacity.rows>16 && first.capacity.rows<300);
  CHECK(lp_row_group(s,first.rows,&second) && second.first==first.rows && first.rows+second.rows==300);
  size_t boundary=first.rows;
  CHECK(lpage_put(s,0,0,(lpage_cell){'a',0,0,1,0,0})); lpage_wrap(s,0,true);
  CHECK(lpage_put(s,boundary+1,0,(lpage_cell){'b',0,0,1,0,0})); lpage_wrap(s,boundary+1,true);
  lpage_resize *r=lpage_resize_prepare(s,(lpage_resize_options){213,300,false,true,{0,299,false},{0,0,false},false});
  CHECK(r); lpage_resize_commit(r);
  CHECK(lp_row_group(s,0,&first) && first.capacity.cols==215 && first.rows==boundary);
  lpage_wrap(s,boundary, true);
  CHECK(lpage_put(s,boundary,212,(lpage_cell){0,0,0,1,LP_CELL_WIDE_HEAD,0}));
  CHECK(!lp_row_page_has_head(s,0) && lp_row_page_has_head(s,boundary+1));
  r=lpage_resize_prepare(s,(lpage_resize_options){215,300,false,true,{0,299,false},{0,0,false},false});
  CHECK(r); lpage_resize_commit(r);
  CHECK(lpage_visible(s,0)->wrapped && !lpage_visible(s,boundary+1)->wrapped);
  CHECK(lp_row_group(s,boundary,&second) && second.first==boundary);
  /* Partial row shifts preserve page positions; full history growth appends. */
  CHECK(lpage_scroll(s,boundary-1,boundary+2,1,false,0));
  CHECK(lp_row_group(s,boundary,&second) && second.first==boundary);
  for (unsigned i=0;i<25;i++) CHECK(lpage_scroll(s,0,299,1,true,0));
  CHECK(lp_row_group(s,0,&first) && first.rows==boundary);
  CHECK(lp_row_group(s,boundary,&second) && first.rows+second.rows==325);
  lpage_clear_history(s); CHECK(lp_row_group(s,0,&first) && first.rows==boundary-25);
  lpage_destroy(s);
}
static void managed_styles(void) {
  /* The incoming style must be reserved before repairing a wide glyph
   * retires its last style references at the set's exact load limit. */
  lpage_screen *wide=lpage_create(215,300,0); CHECK(wide);
  for (unsigned i=0;i<103;i++) {
    uint32_t id; CHECK(lstyle_acquire(lpage_styles(wide),&(lpage_style){LP_COLOR_RGB|i,0,0,0},&id));
    CHECK(lpage_put(wide,0,i ? i+1 : 0,(lpage_cell){i ? 'x' : 0x65e5,id,0,i ? 1 : 2,0,0})); lstyle_release(lpage_styles(wide),id);
  }
  lp_group_span before; CHECK(lp_row_group(wide,0,&before) && before.capacity.styles==128);
  uint32_t replacement; CHECK(lstyle_acquire(lpage_styles(wide),&(lpage_style){LP_COLOR_RGB|104,0,0,0},&replacement));
  CHECK(lpage_put(wide,0,0,(lpage_cell){'q',replacement,0,1,0,0})); lstyle_release(lpage_styles(wide),replacement);
  CHECK(lp_row_group(wide,0,&before) && before.capacity.styles==256); lpage_destroy(wide);
  lpage_screen *s=lpage_create(215,300,2000); CHECK(s);
  lp_group_span first,second; CHECK(lp_row_group(s,0,&first)); size_t boundary=first.rows;
  for (unsigned i=0;i<768;i++) {
    uint32_t id; CHECK(lstyle_acquire(lpage_styles(s),&(lpage_style){LP_COLOR_RGB|i,0,0,0},&id));
    CHECK(lpage_put(s,i/215,i%215,(lpage_cell){'x',id,0,1,0,0}));
    lstyle_release(lpage_styles(s),id);
  }
  CHECK(lp_row_group(s,0,&first) && first.capacity.styles==1024 && first.rows==boundary);
  CHECK(lp_row_group(s,boundary,&second) && second.capacity.styles==128);
  lpage_resize *r=lpage_resize_prepare(s,(lpage_resize_options){217,300,false,true,{0,299,false},{0,0,false},false});
  CHECK(r); lpage_resize_commit(r); CHECK(lp_row_group(s,0,&first) && first.capacity.styles==1024);
  /* Erase/reuse invalidates cached ID counts. Recycled pool IDs must not
   * keep an old style alive or create fictitious distinct entries. */
  for (size_t y=0;y<300;y++) CHECK(lpage_erase(s,y,0,217,0));
  CHECK(lstyle_count(lpage_styles(s))==1); /* immortal default */
  for (unsigned i=0;i<2000;i++) {
    uint32_t id; CHECK(lstyle_acquire(lpage_styles(s),&(lpage_style){LP_COLOR_RGB|i,0,0,0},&id));
    CHECK(lpage_put(s,0,0,(lpage_cell){'y',id,0,1,0,0})); lstyle_release(lpage_styles(s),id);
    CHECK(lpage_erase(s,0,0,1,0));
  }
  CHECK(lp_row_group(s,0,&first) && first.capacity.styles==1024 && lstyle_count(lpage_styles(s))==1);
  CHECK(lpage_scroll(s,0,299,25,true,0)); lpage_clear_history(s);
  uint32_t id; CHECK(lstyle_acquire(lpage_styles(s),&(lpage_style){LP_COLOR_INDEXED|3,0,0,0},&id));
  CHECK(lpage_put(s,0,0,(lpage_cell){'z',id,0,1,0,0})); lstyle_release(lpage_styles(s),id);
  lpage_destroy(s);
}
int main(void) { ownership(); cached_capacity(); height_transfer(); heads(); bounded(); group_boundaries(); managed_styles(); puts("resize ownership, live page style capacities, logical boundaries and 9000 mixed resizes passed"); return 0; }
