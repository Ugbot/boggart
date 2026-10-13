/* Test-only allocation interception: the real page/resize implementations
 * below replace their archive objects. No fault hook enters either product. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bterm_internal.h"
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static size_t allocations,fail_at;
static bool failed_allocation;
static bool fail(void) {
  allocations++;
  if (fail_at && allocations==fail_at) { failed_allocation=true; return true; }
  return false;
}
static void *fault_malloc(size_t size) { return fail() ? NULL : malloc(size); }
static void *fault_calloc(size_t n,size_t size) { return fail() ? NULL : calloc(n,size); }
#define malloc fault_malloc
#define calloc fault_calloc
#include "../../src/lpage.c"
#include "../../src/lpage_resize.c"
#undef malloc
#undef calloc
typedef struct { uint8_t replies[1024]; size_t length,events; } callbacks;
static bool reply(void *context,const uint8_t *bytes,size_t size) {
  callbacks *c=context; CHECK(size<=sizeof c->replies-c->length);
  memcpy(c->replies+c->length,bytes,size); c->length+=size; return true;
}
static bool reject_reply(void *context,const uint8_t *bytes,size_t size) {
  (void)context; (void)bytes; (void)size; return false;
}
static void event_sink(void *context,const bterm_event *event) { (void)event; ((callbacks *)context)->events++; }
static void feed(bterm *t,const char *text) { CHECK(bterm_feed(t,(const uint8_t *)text,strlen(text))); }
typedef struct {
  size_t columns,rows,history,count,styles[64],links[64],graphemes[64];
  lpage_style style_values[64];
  uint32_t grapheme_values[64][LG_LIMIT]; size_t grapheme_lengths[64],key_lengths[64],uri_lengths[64];
  char keys[64][64],uris[64][64];
  lpage_stats stats;
  lpage_cell cells[4096]; size_t capacities[128]; bool wrapped[128],dirty[128];
} image;
static void capture(lpage_screen *s,image *out) {
  memset(out,0,sizeof *out);
  out->columns=lpage_columns(s); out->rows=lpage_rows(s); out->history=lpage_history_count(s);
  out->stats=lpage_usage(s);
  CHECK(out->rows+out->history<=128);
  for (size_t y=0;y<out->rows+out->history;y++) {
    const lpage_row *r=y<out->history ? lpage_history(s,y) : lpage_visible(s,y-out->history);
    out->capacities[y]=lp_row_capacity(s,y);
    out->wrapped[y]=r->wrapped;
    if (y>=out->history) out->dirty[y]=lpage_dirty(s,y-out->history);
    CHECK(out->count+r->columns<=4096);
    for (size_t x=0;x<r->columns;x++) {
      CHECK(r->cells[x].style<64 && r->cells[x].hyperlink<64);
      if (r->cells[x].flags&LP_CELL_GRAPHEME) CHECK(r->cells[x].codepoint<64);
    }
    memcpy(&out->cells[out->count],r->cells,r->columns*sizeof *r->cells); out->count+=r->columns;
  }
  for (unsigned id=1;id<64;id++) {
    out->styles[id]=lstyle_refs(lpage_styles(s),id);
    out->links[id]=llink_refs(lpage_links(s),id);
    out->graphemes[id]=lgrapheme_refs(lpage_graphemes(s),id);
    const lpage_style *style=lstyle_get(lpage_styles(s),id);
    if (style) out->style_values[id]=*style;
    lgrapheme_value g=lgrapheme_get(lpage_graphemes(s),id);
    out->grapheme_lengths[id]=g.length;
    if (g.length) memcpy(out->grapheme_values[id],g.codepoints,g.length*sizeof *g.codepoints);
    const llink_value *link=llink_get(lpage_links(s),id);
    if (link) {
      CHECK(link->key_length<=64 && link->uri_length<=64);
      out->key_lengths[id]=link->key_length; out->uri_lengths[id]=link->uri_length;
      memcpy(out->keys[id],link->key,link->key_length); memcpy(out->uris[id],link->uri,link->uri_length);
    }
  }
}
static bterm *make(callbacks *c,bool alternate) {
  bterm *t=bterm_create(6,4,17,reply,c); CHECK(t);
  bterm_set_event_sink(t,event_sink,c);
  for (unsigned i=0;i<10;i++) feed(t,"\033[31m\033]8;id=fail;https://example.com\a\xe6\x97\xa5\xcc\x81" "e\xcc\x81\r\n");
  feed(t,"\0337\033[2;3r\033[?6;1003;1006;2004;1004h\033[H\033H\033[6n\033]0;kept\a");
  if (alternate) feed(t,"\033[?47h\033]8;id=alt;https://alt.com\a\xe6\x97\xa5\xcc\x81\0337");
  bmouse_event mouse={.action=BM_MOTION,.button=1,.x=0,.y=0};
  uint8_t bytes[128]; size_t length; CHECK(bterm_mouse(t,&mouse,8,16,bytes,sizeof bytes,&length));
  CHECK(t->mouse_motion.valid);
  for (unsigned i=0;i<2;i++) if (t->buffers[i].screen) lpage_ack_damage(t->buffers[i].screen);
  return t;
}
static void failures(size_t columns,size_t rows,bool alternate,bool wrap,bool cached) {
  size_t failures=0;
  for (size_t index=1;index<200;index++) {
    fail_at=0; callbacks c={0}; bterm *t=make(&c,alternate);
    if (cached) { t->modes&=~BT_AUTOWRAP; CHECK(bterm_resize(t,4,4)); }
    if (wrap) t->modes|=BT_AUTOWRAP; else t->modes&=~BT_AUTOWRAP;
    bterm before; memcpy(&before,t,sizeof before); callbacks old_callbacks=c;
    image images[2],after;
    for (unsigned i=0;i<2;i++) if (t->buffers[i].screen) capture(t->buffers[i].screen,&images[i]);
    allocations=0; fail_at=index; failed_allocation=false;
    bool resized=bterm_resize(t,columns,rows); fail_at=0;
    if (!resized) {
      CHECK(failed_allocation && !memcmp(&before,t,sizeof before));
      for (unsigned i=0;i<2;i++) if (t->buffers[i].screen) {
        capture(t->buffers[i].screen,&after); CHECK(!memcmp(&after,&images[i],sizeof after));
      }
      CHECK(!memcmp(&c,&old_callbacks,sizeof c));
      CHECK(!t->failed); feed(t,"Z"); failures++;
    } else {
      CHECK(!failed_allocation && t->columns==columns && t->rows==rows);
      CHECK(t->top==0 && t->bottom==rows-1 && !t->mouse_motion.valid);
      CHECK(!memcmp(&c,&old_callbacks,sizeof c));
      for (unsigned i=0;i<2;i++) if (t->buffers[i].screen) {
        CHECK(lpage_columns(t->buffers[i].screen)==columns && lpage_rows(t->buffers[i].screen)==rows);
        for (size_t y=0;y<rows;y++) CHECK(lpage_dirty(t->buffers[i].screen,y));
      }
      bterm_destroy(t); CHECK(failures>=4);
      printf("resize %zux%zu alt=%d wrap=%d cached=%d: %zu allocation failures rolled back\n",columns,rows,alternate,wrap,cached,failures);
      return;
    }
    bterm_destroy(t);
  }
  CHECK(false);
}
static void no_op_and_commit(void) {
  fail_at=0; callbacks c={0}; bterm *t=make(&c,true); bterm before; memcpy(&before,t,sizeof before);
  allocations=0; fail_at=1;
  CHECK(bterm_resize(t,6,4) && !allocations && !memcmp(&before,t,sizeof before));
  CHECK(!bterm_resize(t,0,4) && !bterm_resize(t,6,4097) && !allocations && !memcmp(&before,t,sizeof before));
  fail_at=0;
  lpage_screen *s=t->buffers[0].screen;
  lpage_resize *r=lpage_resize_prepare(s,(lpage_resize_options){12,6,true,true,{0,0,false},{0,0,false},false}); CHECK(r);
  size_t allocated=allocations; fail_at=allocated+1;
  lpage_resize_commit(r); CHECK(allocations==allocated);
  fail_at=0; bterm_destroy(t);
  t=bterm_create(6,4,1,reject_reply,NULL); CHECK(t);
  CHECK(!bterm_feed(t,(const uint8_t *)"\033[5n",4) && t->failed);
  CHECK(bterm_resize(t,3,2) && t->failed && !bterm_feed(t,(const uint8_t *)"Z",1));
  CHECK(bterm_reset(t) && bterm_feed(t,(const uint8_t *)"Z",1)); bterm_destroy(t);
}
int main(void) {
  no_op_and_commit();
  for (unsigned alt=0;alt<2;alt++) for (unsigned wrap=0;wrap<2;wrap++) {
    failures(3,2,alt!=0,wrap!=0,false); failures(12,6,alt!=0,wrap!=0,false);
    failures(6,4,alt!=0,wrap!=0,true);
  }
  puts("all resize allocations preserve both screens, refs, callbacks and terminal state"); return 0;
}
