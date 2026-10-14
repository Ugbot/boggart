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
#if defined(_WIN32)
#include <malloc.h>
static void *fault_aligned_alloc(size_t size,size_t alignment) { return fail() ? NULL : _aligned_malloc(size,alignment); }
#define _aligned_malloc fault_aligned_alloc
#else
static void *fault_aligned_alloc(size_t alignment,size_t size) { return fail() ? NULL : aligned_alloc(alignment,size); }
#define aligned_alloc fault_aligned_alloc
#endif
#include "../../src/lidmap.c"
#if defined(_WIN32)
#undef _aligned_malloc
#else
#undef aligned_alloc
#endif
#define malloc fault_malloc
#define calloc fault_calloc
#include "../../src/lbitmap.c"
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
  lpage_stats stats; lpage_screen private_screen; uint64_t page_bytes,group_bytes;
  lpage_cell cells[4096]; size_t capacities[128]; bool wrapped[128],dirty[128];
} image;
static void capture(lpage_screen *s,image *out) {
  memset(out,0,sizeof *out);
  out->columns=lpage_columns(s); out->rows=lpage_rows(s); out->history=lpage_history_count(s);
  out->stats=lpage_usage(s); memcpy(&out->private_screen,s,sizeof *s);
  out->group_bytes=UINT64_C(14695981039346656037);
  const unsigned char *group_data=(const unsigned char *)s->groups;
  for (size_t i=0;i<s->group_capacity*sizeof *s->groups;i++) {
    out->group_bytes^=group_data[i]; out->group_bytes*=UINT64_C(1099511628211);
  }
  for (size_t i=0;i<s->group_count;i++) {
    const logical_page *g=group_at(s,i);
    const lidmap *maps[2]={&g->style_refs,&g->grapheme_offsets};
    for (unsigned kind=0;kind<2;kind++) {
      const lidmap *m=maps[kind];
      for (size_t j=0;m->capacity && j<m->capacity+16;j++) {
        out->group_bytes^=m->ctrl[j]; out->group_bytes*=UINT64_C(1099511628211);
      }
      for (size_t j=0;j<m->capacity;j++) if (m->ctrl[j]<128) {
        const unsigned char *key=(const unsigned char *)&m->keys[j],*value=(const unsigned char *)&m->values[j];
        for (size_t k=0;k<sizeof m->keys[j];k++) { out->group_bytes^=key[k]; out->group_bytes*=UINT64_C(1099511628211); }
        for (size_t k=0;k<sizeof m->values[j];k++) { out->group_bytes^=value[k]; out->group_bytes*=UINT64_C(1099511628211); }
      }
    }
    const unsigned char *bits=(const unsigned char *)g->grapheme_bitmap.bits;
    for (size_t j=0;j<(size_t)g->grapheme_bitmap.words*sizeof *g->grapheme_bitmap.bits;j++) {
      out->group_bytes^=bits[j]; out->group_bytes*=UINT64_C(1099511628211);
    }
  }
  out->page_bytes=UINT64_C(14695981039346656037);
  for (const page *p=s->pages;p;p=p->next) {
    const unsigned char *bytes=(const unsigned char *)p;
    size_t n=sizeof *p+PAGE_ROWS*p->columns*sizeof(lpage_cell);
    for (size_t i=0;i<n;i++) { out->page_bytes^=bytes[i]; out->page_bytes*=UINT64_C(1099511628211); }
  }
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
static void failures(size_t columns,size_t rows,bool alternate,bool wrap,bool cached,unsigned cursor_case) {
  size_t failures=0;
  for (size_t index=1;index<200;index++) {
    fail_at=0; callbacks c={0}; bterm *t=make(&c,alternate);
    if (cached) { t->modes&=~BT_AUTOWRAP; CHECK(bterm_resize(t,4,4)); }
    if (wrap) t->modes|=BT_AUTOWRAP; else t->modes&=~BT_AUTOWRAP;
    if (cursor_case) feed(t,cursor_case==1 ? "\033[?6l\033[H\0337" : "\033[?6l\033[H\0337\033[4;1H");
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
      printf("resize %zux%zu alt=%d wrap=%d cached=%d cursor=%u: %zu allocation failures rolled back\n",columns,rows,alternate,wrap,cached,cursor_case,failures);
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
  fail_at=0;
  r=lpage_resize_prepare(s,(lpage_resize_options){12,7,false,true,{0,0,false},{0,0,false},false}); CHECK(r);
  allocated=allocations; fail_at=allocated+1; lpage_resize_commit(r); CHECK(allocations==allocated);
  fail_at=0; bterm_destroy(t);
  t=bterm_create(6,4,1,reject_reply,NULL); CHECK(t);
  CHECK(!bterm_feed(t,(const uint8_t *)"\033[5n",4) && t->failed);
  CHECK(bterm_resize(t,3,2) && t->failed && !bterm_feed(t,(const uint8_t *)"Z",1));
  CHECK(bterm_reset(t) && bterm_feed(t,(const uint8_t *)"Z",1)); bterm_destroy(t);
}
static void grapheme_cache_failures(void) {
  for (unsigned dirty=0;dirty<2;dirty++) for (size_t point=1;point<=4;point++) {
    fail_at=0; lpage_screen *s=lpage_create(6,4,1); CHECK(s);
    CHECK(lpage_put(s,0,0,(lpage_cell){'x',0,0,1,0,0}));
    if (dirty) {
      CHECK(lpage_append_grapheme(s,0,0,0x301,1));
      CHECK(lpage_erase(s,0,0,1,0));
      CHECK(lpage_put(s,0,0,(lpage_cell){'x',0,0,1,0,0}));
    }
    image before,after; capture(s,&before);
    allocations=0; failed_allocation=false; fail_at=point;
    CHECK(!lpage_append_grapheme(s,0,0,0x301,1) && failed_allocation);
    capture(s,&after); CHECK(!memcmp(&before,&after,sizeof before));
    fail_at=0; CHECK(lpage_append_grapheme(s,0,0,0x302,1));
    CHECK(lpage_grapheme(s,lpage_get(s,0,0)).length==2);
    lpage_destroy(s);
  }
  /* Fail every staged map-growth allocation, then every bitmap/map allocation
   * during arena growth. The pending extent must never leak or retire the old
   * extent when preparation fails. */
  for (unsigned arena=0;arena<2;arena++) for (size_t point=1;point<=(arena ? 4u : 3u);point++) {
    fail_at=0; lpage_screen *s=lpage_create(6,6,1); CHECK(s);
    unsigned count=arena ? 32 : 14;
    bool ready=false; size_t y=14/6,x=14%6,expected=2;
    for (unsigned i=0;i<count && !ready;i++) {
      CHECK(lpage_put(s,i/6,i%6,(lpage_cell){'x',0,0,1,0,0}));
      unsigned suffixes=arena ? 64 : 1;
      for (unsigned j=0;j<suffixes;j++) {
        logical_page *g=group_at(s,0);
        if (arena && g->grapheme_bitmap.words && (j+3)/4!=(j+4)/4) {
          /* Probe a copied bitmap, preserving the live allocator's exact
           * holes and search hint instead of assuming sum-only exhaustion. */
          uint64_t bits[8]; CHECK(g->grapheme_bitmap.words==8);
          memcpy(bits,g->grapheme_bitmap.bits,sizeof bits);
          lbitmap probe=g->grapheme_bitmap; probe.bits=bits; uint32_t offset;
          if (!lbitmap_alloc(&probe,(j+1)*4,&offset)) {
            ready=true; y=i/6; x=i%6; expected=j+2; break;
          }
        }
        CHECK(lpage_append_grapheme(s,i/6,i%6,0x301,1));
      }
    }
    CHECK(!arena || ready);
    if (!arena) CHECK(lpage_put(s,y,x,(lpage_cell){'x',0,0,1,0,0}));
    logical_page *g=group_at(s,0);
    CHECK(!g->graphemes_dirty && g->capacity.grapheme_bytes==8192);
    if (!arena) CHECK(g->grapheme_offsets.count==14 && g->grapheme_offsets.capacity==16);
    image before,after; capture(s,&before);
    allocations=0; failed_allocation=false; fail_at=point;
    CHECK(!lpage_append_grapheme(s,y,x,0x302,1) && failed_allocation);
    capture(s,&after); CHECK(!memcmp(&before,&after,sizeof before));
    fail_at=0; CHECK(lpage_append_grapheme(s,y,x,0x302,1));
    CHECK(lpage_grapheme(s,lpage_get(s,y,x)).length==expected);
    lpage_destroy(s);
  }
  puts("15 GP initialization/map-growth/arena-growth failures preserve deep page state");
}
int main(void) {
  grapheme_cache_failures();
  no_op_and_commit();
  for (unsigned alt=0;alt<2;alt++) for (unsigned wrap=0;wrap<2;wrap++) {
    failures(3,2,alt!=0,wrap!=0,false,0); failures(12,6,alt!=0,wrap!=0,false,0);
    failures(6,4,alt!=0,wrap!=0,true,0);
    /* Force padding past all unused source slots, including cached physical
     * widths: fault every separately owned new-page allocation as well. */
    failures(6,21,alt!=0,wrap!=0,false,1); failures(4,21,alt!=0,wrap!=0,true,1);
    for (unsigned cursor=1;cursor<=2;cursor++) {
      failures(6,2,alt!=0,wrap!=0,false,cursor); failures(6,7,alt!=0,wrap!=0,false,cursor);
      failures(4,2,alt!=0,wrap!=0,true,cursor); failures(4,7,alt!=0,wrap!=0,true,cursor);
    }
  }
  puts("all resize allocations preserve both screens, refs, callbacks and terminal state"); return 0;
}
