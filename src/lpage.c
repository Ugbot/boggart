/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/page.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/PageList.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Screen.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: portable contiguous row pages, screen-owned style IDs, visible
 * and history pointer rings. Reflow uses shared pools and candidate geometry;
 * tracked selections are separate work.
 */
#include "lpage.h"
#include "lpage_internal.h"
#include "lidmap.h"
#include "lbitmap.h"
#include <stdlib.h>
#include <string.h>
#define PAGE_ROWS 16
#if defined(_MSC_VER)
static __declspec(thread) uint64_t row_serial;
#else
static _Thread_local uint64_t row_serial;
#endif
typedef struct page page;
typedef struct {
  lpage_row view;
  lpage_cell *cells;
  page *owner;
  unsigned slot;
  bool dirty, kept; /* kept is used only during allocation-free transfer */
} row;
static void row_changed(row *r) { r->view.revision=++row_serial; r->dirty=true; }
struct page {
  page *next, *available;
  size_t columns; /* allocated width; a crop may expose fewer columns */
  uint16_t free_bits;
  row rows[PAGE_ROWS];
  lpage_cell cells[];
};
typedef struct {
  lp_capacity capacity; size_t rows;
  lidmap style_refs;
  lidmap grapheme_offsets;
  lbitmap grapheme_bitmap;
  bool styles_dirty, graphemes_dirty;
} logical_page;
struct lpage_screen {
  size_t columns, rows, head, history_limit, history_capacity, history_head, history_count;
  row **visible, **history;
  page *pages, *available;
  size_t page_count;
  bool damage_all;
  bool defer_managed; /* unpublished resize geometry rebuilds caches lazily */
  bool style_tracking;
  bool grapheme_tracking;
  const lpage_cell *grapheme_pending;
  lstyle_pool *styles;
  llink_pool *links;
  lgrapheme_pool *graphemes;
  lpage_screen *borrow_source; /* candidate owns only its separately listed pages */
  logical_page *groups;
  size_t group_head, group_count, group_capacity;
};
static lp_layout_shape group_shape(void) {
#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__))
  return (lp_layout_shape){16384,128,sizeof(void *)};
#else
  return (lp_layout_shape){4096,128,sizeof(void *)};
#endif
}
static logical_page *group_at(const lpage_screen *s,size_t i) {
  return &s->groups[(s->group_head+i)%s->group_capacity];
}
static void group_destroy(logical_page *g) {
  lidmap_free(&g->style_refs); lidmap_free(&g->grapheme_offsets);
  lbitmap_destroy(&g->grapheme_bitmap); memset(g,0,sizeof *g);
}
static void groups_destroy(lpage_screen *s) {
  for (size_t i=0;i<s->group_count;i++) group_destroy(group_at(s,i));
  free(s->groups); s->groups=NULL; s->group_count=s->group_capacity=s->group_head=0;
}
static void styles_dirty(lpage_screen *s) {
  for (size_t i=0;i<s->group_count;i++) group_at(s,i)->styles_dirty=true;
}
static void graphemes_dirty(lpage_screen *s) {
  if (s->grapheme_tracking) for (size_t i=0;i<s->group_count;i++) group_at(s,i)->graphemes_dirty=true;
}
static bool group_reserve(lpage_screen *s) {
  if (s->group_count<s->group_capacity) return true;
  size_t n=s->group_capacity ? s->group_capacity*2 : 2;
  if (n<s->group_capacity || n>SIZE_MAX/sizeof *s->groups) return false;
  logical_page *groups=calloc(n,sizeof *groups); if (!groups) return false;
  for (size_t i=0;i<s->group_count;i++) groups[i]=*group_at(s,i);
  free(s->groups); s->groups=groups; s->group_capacity=n; s->group_head=0; return true;
}
static bool group_can_append(lpage_screen *s) {
  if (s->group_count) {
    logical_page *last=group_at(s,s->group_count-1);
    if (last->rows<last->capacity.rows) return true;
  }
  return group_reserve(s);
}
static bool group_append(lpage_screen *s) {
  if (!group_can_append(s)) return false;
  logical_page *last=s->group_count ? group_at(s,s->group_count-1) : NULL;
  if (!last || last->rows==last->capacity.rows) {
    lp_capacity cap; if (!lp_capacity_initial(group_shape(),(uint16_t)s->columns,&cap)) return false;
    last=group_at(s,s->group_count++); *last=(logical_page){.capacity=cap};
  }
  last->rows++; return true;
}
static void group_drop(lpage_screen *s,size_t n) {
  while (n && s->group_count) {
    logical_page *first=group_at(s,0);
    if (n<first->rows) { first->rows-=n; return; }
    n-=first->rows; group_destroy(first);
    s->group_head=(s->group_head+1)%s->group_capacity; s->group_count--;
  }
}
bool lp_row_group(const lpage_screen *s,size_t y,lp_group_span *out) {
  size_t first=0;
  for (size_t i=0;i<s->group_count;i++) {
    const logical_page *g=group_at(s,i);
    if (y-first<g->rows) { if (out) *out=(lp_group_span){g->capacity,first,g->rows}; return true; }
    first+=g->rows;
  }
  return false;
}
static row *at(const lpage_screen *s, size_t y) { return s->visible[(s->head + y) % s->rows]; }
static void set(lpage_screen *s, size_t y, row *r) { s->visible[(s->head + y) % s->rows] = r; }
void lpage_release_cell(lpage_screen *s, lpage_cell cell) {
  if (cell.style) lstyle_release(s->styles, cell.style);
  if (cell.hyperlink) llink_release(s->links, cell.hyperlink);
  if (cell.flags & LP_CELL_GRAPHEME) lgrapheme_release(s->graphemes, cell.codepoint);
}
static void blank_row(lpage_screen *s,row *r) {
  for (size_t x=0;x<r->owner->columns;x++) r->cells[x]=(lpage_cell){0,0,0,1,0,0};
  r->view.columns=s->columns; r->view.wrapped=false; row_changed(r); r->kept=false;
}
static row *new_row_capacity(lpage_screen *s,size_t capacity) {
  page **available=&s->available;
  if (capacity) while (*available && (*available)->columns!=capacity) available=&(*available)->available;
  page *p = *available;
  if (!p) {
    size_t columns=capacity ? capacity : s->columns;
    size_t bytes = sizeof *p + PAGE_ROWS * columns * sizeof(lpage_cell);
    p = calloc(1, bytes);
    if (!p) return NULL;
    p->columns=columns;
    p->free_bits = UINT16_MAX;
    for (unsigned slot = 0; slot < PAGE_ROWS; slot++) {
      row *r = &p->rows[slot];
      r->cells = &p->cells[slot * columns];
      r->view.cells = r->cells; r->view.columns = s->columns;
      r->owner = p; r->slot = slot;
    }
    p->next = s->pages; s->pages = p; *available = p; s->page_count++;
  }
  unsigned slot = 0;
  while (!(p->free_bits & (1u << slot))) slot++;
  p->free_bits = (uint16_t)(p->free_bits & ~(1u << slot));
  if (!p->free_bits) *available = p->available;
  row *r = &p->rows[slot];
  blank_row(s,r);
  return r;
}
static row *new_row(lpage_screen *s) { return new_row_capacity(s,0); }
static void free_row(lpage_screen *s, row *r) {
  for (size_t x = 0; x < s->columns; x++) {
    lpage_release_cell(s, r->cells[x]); r->cells[x].style = r->cells[x].hyperlink = 0;
  }
  page *p = r->owner;
  if (!p->free_bits) { p->available = s->available; s->available = p; }
  p->free_bits = (uint16_t)(p->free_bits | (1u << r->slot));
}
lpage_screen *lpage_create(size_t columns, size_t rows, size_t history_limit) {
  if (!columns || !rows || columns > 4096 || rows > 4096 || history_limit > SIZE_MAX / sizeof(row *)) return NULL;
  lpage_screen *s = calloc(1, sizeof *s);
  if (!s) return NULL;
  s->columns = columns; s->rows = rows; s->history_limit = history_limit;
  s->styles = lstyle_create(); s->visible = calloc(rows, sizeof *s->visible);
  s->links = llink_create(); s->graphemes = lgrapheme_create();
  if (!s->styles || !s->links || !s->graphemes || !s->visible) { lpage_destroy(s); return NULL; }
  for (size_t y = 0; y < rows; y++) {
    if (!(s->visible[y] = new_row(s)) || !group_append(s)) { lpage_destroy(s); return NULL; }
  }
  s->damage_all = true;
  return s;
}
void lpage_destroy(lpage_screen *s) {
  if (!s) return;
  page *p = s->pages;
  while (p) { page *next = p->next; free(p); p = next; }
  free(s->visible); free(s->history); groups_destroy(s); lstyle_destroy(s->styles); llink_destroy(s->links); lgrapheme_destroy(s->graphemes); free(s);
}
/* Unlike whole-screen destruction, retiring geometry must release each live
 * cell because the pools survive. Unused page slots own no references. */
static void geometry_free(lpage_screen *s) {
  page *p=s->pages;
  while (p) {
    page *next=p->next;
    for (unsigned slot=0;slot<PAGE_ROWS;slot++) if (!(p->free_bits & (1u<<slot)))
      for (size_t x=0;x<s->columns;x++) lpage_release_cell(s,p->rows[slot].cells[x]);
    free(p); p=next;
  }
  free(s->visible); free(s->history); groups_destroy(s);
}
lpage_screen *lp_geometry_new(const lpage_screen *source,size_t columns,size_t rows) {
  if (!columns || !rows || columns>4096 || rows>4096) return NULL;
  lpage_screen *s=calloc(1,sizeof *s); if (!s) return NULL;
  s->columns=columns; s->rows=rows; s->history_limit=source->history_limit;
  s->defer_managed=true;
  s->styles=source->styles; s->links=source->links; s->graphemes=source->graphemes;
  s->visible=calloc(rows,sizeof *s->visible);
  if (!s->visible) { free(s); return NULL; }
  s->damage_all=true; return s;
}
bool lp_geometry_row(lpage_screen *s,size_t y,size_t capacity) {
  if (y>=s->rows || (capacity && (capacity<s->columns || capacity>4096))) return false;
  row *old=at(s,y);
  if (old && (!capacity || old->owner->columns==capacity)) return true;
  if (!old && !group_can_append(s)) return false;
  row *r=new_row_capacity(s,capacity); if (!r) return false;
  if (!old && !group_append(s)) { free_row(s,r); return false; }
  if (old) free_row(s,old);
  set(s,y,r); return true;
}
static row *absolute_row(const lpage_screen *s,size_t y) {
  return y<s->history_count ? s->history[(s->history_head+y)%s->history_capacity] : at(s,y-s->history_count);
}
static size_t style_limit(uint32_t requested) {
  if (!requested) return 0;
  size_t table=1; while (table<requested) table*=2;
  size_t items=table*13/16; return items ? items-1 : 0;
}
static bool style_grow(lp_capacity *cap,size_t count,size_t rows) {
  while (count>style_limit(cap->styles)) {
    lp_capacity next;
    /* A set rejects the pending unique style before increasing capacity. */
    if (!lp_capacity_grow(group_shape(),*cap,LP_GROW_STYLES,(uint32_t)(count-1),(uint16_t)rows,&next)) return false;
    *cap=next;
  }
  return true;
}
static bool style_map_add(lidmap *map,uint32_t id) {
  if (!id) return true;
  uint32_t *refs=lidmap_value(map,id);
  if (refs) { if (*refs==UINT32_MAX) return false; (*refs)++; return true; }
  return lidmap_insert(map,id,1);
}
static bool style_prepare(lpage_screen *s,logical_page *g,size_t first,uint32_t incoming,uint32_t **refs_out) {
  *refs_out=NULL;
  bool rebuild=!g->style_refs.capacity || g->styles_dirty;
  uint32_t *existing=incoming && g->style_refs.capacity ? lidmap_value(&g->style_refs,incoming) : NULL;
  bool fresh=incoming && !existing;
  if (!rebuild && !fresh) { *refs_out=existing; return true; }
  lp_capacity cap=g->capacity;
  if (!rebuild && !style_grow(&cap,g->style_refs.count+1,g->rows)) return false;
  if (!rebuild && cap.styles==g->capacity.styles) return true;
  uint32_t hint=cap.styles ? cap.styles : 16;
  for (;;) {
    /* Venus doubles its hint before rounding. The SDK's 13/16 item limit
     * fits the Swiss map's 7/8 limit at the same bucket count. */
    uint32_t buckets=16; while (buckets<hint) buckets*=2;
    lidmap candidate={0}; if (!lidmap_init(&candidate,buckets/2)) return false;
    bool ok=true;
    for (size_t y=first;y<first+g->rows && ok;y++) {
      row *r=absolute_row(s,y);
      for (size_t x=0;x<s->columns && ok;x++) ok=style_map_add(&candidate,r->cells[x].style);
    }
    bool pending=incoming && !lidmap_find(&candidate,incoming,NULL);
    size_t count=candidate.count+(pending ? 1 : 0);
    if (ok && !style_grow(&cap,count,g->rows)) { lidmap_free(&candidate); return false; }
    if (ok && hint>=cap.styles) {
      if (g->capacity.styles!=cap.styles && g->grapheme_bitmap.chunk_bytes) g->graphemes_dirty=true;
      lidmap_free(&g->style_refs); g->style_refs=candidate; g->capacity=cap; g->styles_dirty=false; s->style_tracking=true;
      *refs_out=incoming ? lidmap_value(&g->style_refs,incoming) : NULL; return true;
    }
    lidmap_free(&candidate);
    if (hint>=65536) return false;
    hint=cap.styles>hint ? cap.styles : hint*2;
  }
}
static logical_page *style_group(lpage_screen *s,size_t y,size_t *first_out) {
  size_t first=0;
  for (size_t i=0;i<s->group_count;i++) {
    logical_page *g=group_at(s,i);
    if (y-first<g->rows) { *first_out=first; return g; }
    first+=g->rows;
  }
  return NULL;
}
static void styles_dirty_row(lpage_screen *s,const row *r) {
  if (s->defer_managed) return;
  size_t first=0;
  for (size_t i=0;i<s->group_count;i++) {
    logical_page *g=group_at(s,i);
    for (size_t y=first;y<first+g->rows;y++) if (absolute_row(s,y)==r) { g->styles_dirty=true; return; }
    first+=g->rows;
  }
  /* A newly allocated padding row joins its destination after fill. */
  styles_dirty(s);
}
static void graphemes_dirty_row(lpage_screen *s,const row *r) {
  if (!s->grapheme_tracking || s->defer_managed) return;
  size_t first=0;
  for (size_t i=0;i<s->group_count;i++) {
    logical_page *g=group_at(s,i);
    for (size_t y=first;y<first+g->rows;y++) if (absolute_row(s,y)==r) { g->graphemes_dirty=true; return; }
    first+=g->rows;
  }
  graphemes_dirty(s);
}
static uint32_t grapheme_cell_bytes(const lpage_screen *s,const lpage_cell *cell) {
  if (!(cell->flags&LP_CELL_GRAPHEME)) return 0;
  lgrapheme_value v=lgrapheme_get(s->graphemes,cell->codepoint);
  return v.length>1 ? (uint32_t)(v.length-1)*4 : 0;
}
static uint64_t grapheme_key(const lpage_cell *cell) { return (uint64_t)(uintptr_t)cell; }
static bool grapheme_rebuild(lpage_screen *s,logical_page *g,size_t first,lp_capacity cap) {
  /* Staged metadata only: payloads remain owned by the shared GP pool.
   * Moving/erasing cells invalidates pointer keys; the next append reconciles
   * them. Resize preparation must never reconcile published source caches. */
  size_t count=0;
  for (size_t y=first;y<first+g->rows;y++) {
    row *r=absolute_row(s,y);
    for (size_t x=0;x<s->columns;x++) if (grapheme_cell_bytes(s,&r->cells[x])) count++;
  }
  if (count>=UINT32_C(1073741824)) return false;
  for (;;) {
    lbitmap bitmap={0}; lidmap offsets={0};
    if (!lbitmap_init(&bitmap,cap.grapheme_bytes,16)) return false;
    if (!lidmap_init(&offsets,(uint32_t)(count ? count+1 : 8))) { lbitmap_destroy(&bitmap); return false; }
    bool ok=true;
    for (size_t y=first;y<first+g->rows && ok;y++) {
      row *r=absolute_row(s,y);
      for (size_t x=0;x<s->columns && ok;x++) {
        uint32_t bytes=grapheme_cell_bytes(s,&r->cells[x]),offset;
        if (bytes) ok=lbitmap_alloc(&bitmap,bytes,&offset)
          && lidmap_insert(&offsets,grapheme_key(&r->cells[x]),offset);
      }
    }
    uint64_t used=lbitmap_used(&bitmap);
    if (ok) {
      lbitmap_destroy(&g->grapheme_bitmap); lidmap_free(&g->grapheme_offsets);
      g->grapheme_bitmap=bitmap; g->grapheme_offsets=offsets; g->capacity=cap;
      g->graphemes_dirty=false; s->grapheme_tracking=true; return true;
    }
    lbitmap_destroy(&bitmap); lidmap_free(&offsets);
    lp_capacity grown;
    if (used>UINT32_MAX || !lp_capacity_grow(group_shape(),cap,LP_GROW_GRAPHEMES,(uint32_t)used,(uint16_t)g->rows,&grown)) return false;
    cap=grown;
  }
}
static bool grapheme_map_room(lidmap *map) {
  if (map->count<map->capacity*7/8) return true;
  lidmap grown={0}; if (!lidmap_init(&grown,map->capacity)) return false;
  for (size_t i=0;i<map->capacity;i++) if (map->ctrl[i]<128) {
    if (!lidmap_insert(&grown,map->keys[i],map->values[i])) { lidmap_free(&grown); return false; }
  }
  lidmap_free(map); *map=grown; return true;
}
typedef struct {
  logical_page *group;
  uint64_t key;
  uint32_t old_offset,old_bytes,new_offset,new_bytes;
  bool allocated;
} grapheme_reservation;
static bool grapheme_reserve(lpage_screen *s,size_t y,size_t x,uint32_t old_bytes,uint32_t new_bytes,
                             grapheme_reservation *out) {
  memset(out,0,sizeof *out);
  if (s->defer_managed) return true;
  size_t first; logical_page *g=style_group(s,s->history_count+y,&first);
  if (!g) return false;
  if ((!g->grapheme_bitmap.chunk_bytes || g->graphemes_dirty)
    && !grapheme_rebuild(s,g,first,g->capacity)) return false;
  uint64_t key=grapheme_key(&at(s,y)->cells[x]);
  uint32_t old_offset=0;
  if (old_bytes && !lidmap_find(&g->grapheme_offsets,key,&old_offset)) return false;
  if ((old_bytes+15)/16==(new_bytes+15)/16) {
    *out=(grapheme_reservation){g,key,old_offset,old_bytes,old_offset,new_bytes,false}; return true;
  }
  uint32_t offset;
  while (!lbitmap_alloc(&g->grapheme_bitmap,new_bytes,&offset)) {
    uint64_t used=lbitmap_used(&g->grapheme_bitmap); lp_capacity grown;
    if (used>UINT32_MAX || !lp_capacity_grow(group_shape(),g->capacity,LP_GROW_GRAPHEMES,(uint32_t)used,(uint16_t)g->rows,&grown)
      || !grapheme_rebuild(s,g,first,grown)) return false;
    if (old_bytes && !lidmap_find(&g->grapheme_offsets,key,&old_offset)) return false;
  }
  if (!old_bytes && !grapheme_map_room(&g->grapheme_offsets)) {
    (void)lbitmap_free(&g->grapheme_bitmap,offset,new_bytes); return false;
  }
  *out=(grapheme_reservation){g,key,old_offset,old_bytes,offset,new_bytes,true}; return true;
}
static void grapheme_finish(grapheme_reservation *r,bool commit) {
  if (!r->group) return;
  logical_page *g=r->group;
  if (!commit) {
    if (r->allocated) (void)lbitmap_free(&g->grapheme_bitmap,r->new_offset,r->new_bytes);
    g->graphemes_dirty=true; return;
  }
  if (!r->allocated) return;
  if (r->old_bytes && !lbitmap_free(&g->grapheme_bitmap,r->old_offset,r->old_bytes)) g->graphemes_dirty=true;
  /* Reservation ensured map room before publishing the cell. If metadata
   * ever becomes inconsistent, retain the payload and reconcile on append. */
  if (!lidmap_insert(&g->grapheme_offsets,r->key,r->new_offset)) g->graphemes_dirty=true;
}
static void style_remove(lidmap *map,uint32_t id) {
  if (!id) return;
  uint32_t *refs=lidmap_value(map,id);
  if (refs && *refs>1) (*refs)--; else (void)lidmap_erase(map,id);
}
static row *next_free_row(page **p,unsigned *slot) {
  while (*p) {
    while (*slot<PAGE_ROWS) {
      unsigned index=(*slot)++;
      if ((*p)->free_bits&(1u<<index)) return &(*p)->rows[index];
    }
    *p=(*p)->next; *slot=0;
  }
  return NULL;
}
lpage_screen *lp_geometry_height(lpage_screen *source,size_t rows,size_t end,size_t padding) {
  if (end>source->history_count+source->rows || padding>SIZE_MAX-end || end+padding<rows) return NULL;
  lpage_screen *s=lp_geometry_new(source,source->columns,rows); if (!s) return NULL;
  s->borrow_source=source;
  size_t count=end+padding,history=count-rows;
  if (history>s->history_limit) history=s->history_limit;
  s->history_count=s->history_capacity=history;
  if (history && !(s->history=calloc(history,sizeof *s->history))) goto fail;
  size_t start=count-rows-history;
  page *unused=source->pages; unsigned slot=0;
  for (size_t i=0;i<history+rows;i++) {
    size_t index=start+i;
    row *r=index<end ? absolute_row(source,index) : next_free_row(&unused,&slot);
    if (!r) r=new_row(s);
    if (!r) goto fail;
    if (i<history) s->history[i]=r; else s->visible[i-history]=r;
  }
  if (!lp_geometry_crop_groups(s,source,end,padding)) goto fail;
  return s;
fail:
  lp_geometry_destroy(s); return NULL;
}
size_t lp_row_capacity(const lpage_screen *s,size_t y) {
  lp_group_span g; return lp_row_group(s,y,&g) ? g.capacity.cols : absolute_row(s,y)->owner->columns;
}
bool lp_row_page_has_head(const lpage_screen *s,size_t y) {
  lp_group_span g; if (!lp_row_group(s,y,&g)) return false;
  for (size_t i=g.first;i<g.first+g.rows;i++)
    if (absolute_row(s,i)->cells[s->columns-1].flags&LP_CELL_WIDE_HEAD) return true;
  return false;
}
bool lp_geometry_crop_groups(lpage_screen *dst,const lpage_screen *src,size_t end,size_t padding) {
  for (size_t i=0;i<dst->group_count;i++) group_destroy(group_at(dst,i));
  dst->group_head=dst->group_count=0;
  size_t first=0;
  for (size_t i=0;i<src->group_count && first<end;i++) {
    const logical_page *source=group_at(src,i); lp_capacity cap=source->capacity;
    size_t n=source->rows<end-first ? source->rows : end-first;
    bool rebuild=dst->columns>src->columns && (dst->columns>cap.cols || lp_row_page_has_head(src,first));
    if (rebuild) {
      if (!lp_capacity_adjust(group_shape(),cap,(uint16_t)dst->columns,&cap)) {
        cap.cols=(uint16_t)dst->columns; cap.rows=(uint16_t)(source->rows<cap.rows ? source->rows : cap.rows);
      }
      if (dst->group_count) {
        logical_page *previous=group_at(dst,dst->group_count-1);
        size_t available=previous->capacity.rows-previous->rows,take=n<available ? n : available;
        previous->rows+=take; n-=take;
      }
    }
    while (n) {
      if (!group_reserve(dst)) return false;
      size_t take=n<cap.rows ? n : cap.rows;
      *group_at(dst,dst->group_count++)=(logical_page){.capacity=cap,.rows=take}; n-=take;
    }
    first+=source->rows;
  }
  for (size_t i=0;i<padding;i++) if (!group_append(dst)) return false;
  size_t total=end+padding,retained=dst->history_count+dst->rows;
  if (total>retained) group_drop(dst,total-retained);
  return true;
}
void lp_geometry_destroy(lpage_screen *s) { if (s) { geometry_free(s); free(s); } }
void lp_geometry_replace(lpage_screen *s,lpage_screen *geometry) {
  if (geometry->borrow_source==s) {
    /* No source metadata changes until both screen plans have succeeded. */
    page **tail=&geometry->pages;
    while (*tail) tail=&(*tail)->next;
    *tail=s->pages; geometry->page_count+=s->page_count;
    for (size_t y=0;y<geometry->history_count;y++) geometry->history[y]->kept=true;
    for (size_t y=0;y<geometry->rows;y++) at(geometry,y)->kept=true;
    for (page *p=geometry->pages;p;p=p->next) for (unsigned slot=0;slot<PAGE_ROWS;slot++) {
        row *r=&p->rows[slot];
        if (r->kept) {
          if (p->free_bits&(1u<<slot)) {
            /* Reserved source slots own no holds, even if stale cell flags
             * remain. Initialize only now, after preparation has succeeded. */
            p->free_bits=(uint16_t)(p->free_bits&~(1u<<slot)); blank_row(geometry,r);
          }
          r->kept=false;
        } else if (!(p->free_bits&(1u<<slot))) free_row(geometry,r);
    }
    lp_geometry_trim(geometry);
    free(s->visible); free(s->history); groups_destroy(s); geometry->borrow_source=NULL;
  } else geometry_free(s);
  geometry->defer_managed=false; *s=*geometry; free(geometry);
}
size_t lpage_columns(const lpage_screen *s) { return s->columns; }
size_t lpage_rows(const lpage_screen *s) { return s->rows; }
lstyle_pool *lpage_styles(lpage_screen *s) { return s->styles; }
llink_pool *lpage_links(lpage_screen *s) { return s->links; }
lgrapheme_pool *lpage_graphemes(lpage_screen *s) { return s->graphemes; }
lgrapheme_value lpage_grapheme(const lpage_screen *s, const lpage_cell *cell) {
  if (!cell) return (lgrapheme_value){0};
  if (cell->flags & LP_CELL_GRAPHEME) return lgrapheme_get(s->graphemes, cell->codepoint);
  return cell->codepoint ? (lgrapheme_value){&cell->codepoint,1} : (lgrapheme_value){0};
}
uint32_t lpage_codepoint(const lpage_screen *s, const lpage_cell *cell) {
  lgrapheme_value v=lpage_grapheme(s,cell); return v.length ? v.codepoints[0] : 0;
}
const llink_value *lpage_link(const lpage_screen *s, uint32_t id) { return llink_get(s->links, id); }
const lpage_row *lpage_visible(const lpage_screen *s, size_t y) { return y < s->rows ? &at(s, y)->view : NULL; }
const lpage_cell *lpage_get(const lpage_screen *s, size_t y, size_t x) {
  return y < s->rows && x < s->columns ? &at(s, y)->cells[x] : NULL;
}
static bool fill(lpage_screen *s, row *r, size_t x, size_t n, uint32_t style, bool release_old);
static bool clear_previous_head(lpage_screen *s,size_t y,uint32_t style) {
  row *previous=y ? at(s,y-1) : s->history_count
    ? s->history[(s->history_head+s->history_count-1)%s->history_capacity] : NULL;
  if (previous && (previous->cells[s->columns-1].flags&LP_CELL_WIDE_HEAD))
    return fill(s,previous,s->columns-1,1,style,true);
  return true;
}
static bool break_pair(lpage_screen *s, row *r,size_t x, uint32_t style) {
  if (r->cells[x].flags & LP_CELL_WIDE_TAIL) return fill(s, r, x - 1, 2, style, true);
  if (r->cells[x].width == 2) return fill(s, r, x, 2, style, true);
  return true;
}
bool lpage_retain_cell(lpage_screen *s, lpage_cell cell) {
  /* ID 0 is immortal; keep default-cell writes out of the style pool. */
  if (cell.style && !lstyle_retain(s->styles, cell.style)) return false;
  if (cell.hyperlink && !llink_retain(s->links, cell.hyperlink)) {
    if (cell.style) lstyle_release(s->styles, cell.style);
    return false;
  }
  if ((cell.flags & LP_CELL_GRAPHEME) && !lgrapheme_retain(s->graphemes,cell.codepoint)) {
    lstyle_release(s->styles,cell.style);
    if (cell.hyperlink) llink_release(s->links,cell.hyperlink);
    return false;
  }
  return true;
}
static bool put_cell(lpage_screen *s, size_t y, size_t x, lpage_cell cell,bool repair_head) {
  if (y >= s->rows || x >= s->columns || cell.width < 1 || cell.width > 2
      || (cell.flags & ~(LP_CELL_PROTECTED | LP_CELL_WIDE_HEAD | LP_CELL_GRAPHEME))
      || (cell.width == 2 && x + 1 == s->columns)) return false;
  row *r = at(s, y);
  if ((cell.flags & LP_CELL_WIDE_HEAD) && (cell.width != 1 || cell.codepoint || x + 1 != s->columns || !r->view.wrapped)) return false;
  if (!lpage_retain_cell(s, cell)) return false;
  lpage_cell tail={0,cell.style,cell.hyperlink,0,LP_CELL_WIDE_TAIL | (cell.flags & LP_CELL_PROTECTED),0};
  if (cell.width == 2 && !lpage_retain_cell(s, tail)) { lpage_release_cell(s, cell); return false; }
  bool managed=!s->defer_managed && (cell.style || (s->style_tracking && (r->cells[x].style || (cell.width==2 && r->cells[x+1].style))));
  bool same_styles=!managed || (cell.style==r->cells[x].style && (cell.width!=2 || cell.style==r->cells[x+1].style));
  if (managed && !same_styles && cell.style && (r->cells[x].width==2 || (r->cells[x].flags&LP_CELL_WIDE_TAIL)
    || (cell.width==2 && (r->cells[x+1].width==2 || (r->cells[x+1].flags&LP_CELL_WIDE_TAIL))))) {
    /* Reserve the new unique style while the old wide glyph still exists.
     * Pair repair can retire its last refs before the replacement is written. */
    size_t first; uint32_t *ignored;
    logical_page *before=style_group(s,s->history_count+y,&first);
    if (!before || !style_prepare(s,before,first,cell.style,&ignored)) {
      lpage_release_cell(s,cell); if (cell.width==2) lpage_release_cell(s,tail); return false;
    }
  }
  if ((repair_head && x<=1 && r->cells[0].width==2 && !clear_previous_head(s,y,cell.style))
      || !break_pair(s, r, x, cell.style) || (cell.width == 2 && !break_pair(s, r, x + 1, cell.style))) {
    lpage_release_cell(s, cell); if (cell.width == 2) lpage_release_cell(s, tail); return false;
  }
  logical_page *g=NULL;
  if (managed && !same_styles) {
    size_t first; uint32_t *incoming_refs=NULL;
    g=style_group(s,s->history_count+y,&first);
    if (!g || !style_prepare(s,g,first,cell.style,&incoming_refs)) {
      lpage_release_cell(s,cell); if (cell.width==2) lpage_release_cell(s,tail); return false;
    }
    if (incoming_refs) {
      if (*incoming_refs>UINT32_MAX-cell.width) {
        lpage_release_cell(s,cell); if (cell.width==2) lpage_release_cell(s,tail); return false;
      }
      *incoming_refs+=cell.width;
    } else {
      if (!style_map_add(&g->style_refs,cell.style)) {
        lpage_release_cell(s,cell); if (cell.width==2) lpage_release_cell(s,tail); return false;
      }
      if (cell.width==2 && !style_map_add(&g->style_refs,cell.style)) {
        style_remove(&g->style_refs,cell.style); lpage_release_cell(s,cell); lpage_release_cell(s,tail); return false;
      }
    }
    style_remove(&g->style_refs,r->cells[x].style);
    if (cell.width==2) style_remove(&g->style_refs,r->cells[x+1].style);
  }
  if (!s->defer_managed && (&r->cells[x]!=s->grapheme_pending)
    && ((cell.flags|r->cells[x].flags)&LP_CELL_GRAPHEME)) graphemes_dirty_row(s,r);
  if (cell.width==2 && (r->cells[x+1].flags&LP_CELL_GRAPHEME)) graphemes_dirty_row(s,r);
  lpage_release_cell(s, r->cells[x]); r->cells[x] = cell; row_changed(r);
  if (cell.width == 2) {
    lpage_release_cell(s, r->cells[x + 1]);
    r->cells[x + 1] = tail;
  }
  return true;
}
bool lpage_put(lpage_screen *s,size_t y,size_t x,lpage_cell cell) { return put_cell(s,y,x,cell,true); }
bool lpage_append_grapheme(lpage_screen *s,size_t y,size_t x,uint32_t cp,unsigned width) {
  const lpage_cell *old=lpage_get(s,y,x);
  if (!old || !lpage_codepoint(s,old) || (old->flags & LP_CELL_WIDE_TAIL) || width<1 || width>2
      || (width==2 && x+1==s->columns)) return false;
  size_t length=lpage_grapheme(s,old).length;
  uint32_t old_bytes=grapheme_cell_bytes(s,old),new_bytes=(uint32_t)(length<LG_LIMIT ? length : length-1)*4;
  grapheme_reservation reserved;
  if (!grapheme_reserve(s,y,x,old_bytes,new_bytes,&reserved)) return false;
  lpage_cell cell=*old; uint32_t id;
  if (cell.flags & LP_CELL_GRAPHEME) {
    if (!lgrapheme_append(s->graphemes,cell.codepoint,cp,&id)) { grapheme_finish(&reserved,false); return false; }
  } else {
    uint32_t cps[]={cell.codepoint,cp};
    if (!lgrapheme_acquire(s->graphemes,cps,2,&id)) { grapheme_finish(&reserved,false); return false; }
  }
  cell.codepoint=id; cell.flags|=LP_CELL_GRAPHEME; cell.width=(uint8_t)width;
  s->grapheme_pending=old;
  bool ok=put_cell(s,y,x,cell,width!=old->width); s->grapheme_pending=NULL;
  grapheme_finish(&reserved,ok); lgrapheme_release(s->graphemes,id); return ok;
}
static bool fill(lpage_screen *s, row *r, size_t x, size_t n, uint32_t style, bool release_old) {
  if (s->style_tracking && release_old) {
    for (size_t i=x;i<x+n;i++) if (r->cells[i].style!=style) { styles_dirty_row(s,r); break; }
  }
  if (s->grapheme_tracking && release_old) {
    for (size_t i=x;i<x+n;i++) if ((r->cells[i].flags&LP_CELL_GRAPHEME) && &r->cells[i]!=s->grapheme_pending) {
      graphemes_dirty_row(s,r); break;
    }
  }
  for (size_t i = x; i < x + n; i++) {
    if (style && !lstyle_retain(s->styles, style)) return false;
    if (release_old) lpage_release_cell(s, r->cells[i]);
    r->cells[i] = (lpage_cell){ 0, style, 0, 1, 0, 0 };
  }
  row_changed(r);
  return true;
}
bool lpage_erase(lpage_screen *s, size_t y, size_t x, size_t n, uint32_t style) {
  if (y >= s->rows || x > s->columns || !lstyle_retain(s->styles, style)) return false;
  if (n > s->columns - x) n = s->columns - x;
  row *r = at(s, y);
  if (n) {
    size_t end = x + n;
    if (r->cells[x].flags & LP_CELL_WIDE_TAIL) x--;
    if (end < s->columns && r->cells[end].flags & LP_CELL_WIDE_TAIL) end++;
    n = end - x;
    if (x==0 && r->cells[0].width==2 && !clear_previous_head(s,y,style)) {
      lstyle_release(s->styles,style); return false;
    }
  }
  bool ok = fill(s, r, x, n, style, true);
  if (x == 0 && n == s->columns) r->view.wrapped = false;
  lstyle_release(s->styles, style); return ok;
}
static bool edit(lpage_screen *s, size_t y, size_t x, size_t n, uint32_t style, bool insert) {
  if (y >= s->rows || x > s->columns || !lstyle_retain(s->styles, style)) return false;
  if (n > s->columns - x) n = s->columns - x;
  row *r = at(s, y);
  if (n) { styles_dirty(s); graphemes_dirty(s); }
  /* Splitting a glyph at either cut boundary erases that whole glyph before
   * ownership is transferred by memmove. Internal whole pairs move intact. */
  size_t boundary = insert ? s->columns - n : x + n;
  if (n && ((x<=1 && r->cells[0].width==2 && !clear_previous_head(s,y,style))
       || (x < s->columns && r->cells[x].flags & LP_CELL_WIDE_TAIL && !break_pair(s, r, x, style))
       || (boundary < s->columns && r->cells[boundary].flags & LP_CELL_WIDE_TAIL && !break_pair(s, r, boundary, style)))) {
    lstyle_release(s->styles, style); return false;
  }
  size_t discard = insert ? s->columns - n : x;
  for (size_t i = discard; i < discard + n; i++) lpage_release_cell(s, r->cells[i]);
  size_t tail = s->columns - x - n;
  if (insert) memmove(r->cells + x + n, r->cells + x, tail * sizeof(lpage_cell));
  else memmove(r->cells + x, r->cells + x + n, tail * sizeof(lpage_cell));
  bool ok = fill(s, r, insert ? x : s->columns - n, n, style, false);
  if (!insert && tail) r->cells[s->columns - n - 1].flags &= (uint8_t)~LP_CELL_WIDE_HEAD;
  r->cells[s->columns - 1].flags &= (uint8_t)~LP_CELL_WIDE_HEAD;
  r->view.wrapped = false;
  lstyle_release(s->styles, style); return ok;
}
bool lpage_insert_cells(lpage_screen *s, size_t y, size_t x, size_t n, uint32_t style) { return edit(s, y, x, n, style, true); }
bool lpage_delete_cells(lpage_screen *s, size_t y, size_t x, size_t n, uint32_t style) { return edit(s, y, x, n, style, false); }
static bool reserve_history(lpage_screen *s) {
  if (s->history_count < s->history_capacity) return true;
  size_t capacity = s->history_capacity
    ? (s->history_capacity > s->history_limit / 2 ? s->history_limit : s->history_capacity * 2)
    : 16;
  if (capacity > s->history_limit) capacity = s->history_limit;
  row **history = malloc(capacity * sizeof *history);
  if (!history) return false;
  for (size_t i = 0; i < s->history_count; i++) history[i] = s->history[(s->history_head + i) % s->history_capacity];
  free(s->history); s->history = history; s->history_capacity = capacity; s->history_head = 0;
  return true;
}
static bool scroll_one(lpage_screen *s, size_t top, size_t bottom, bool up, bool history, uint32_t style) {
  row *old = at(s, up ? top : bottom), *blank = old;
  bool allocated = false;
  if (up && history && s->history_limit) {
    if (!group_can_append(s)) return false;
    if (s->history_count == s->history_limit) blank = s->history[s->history_head];
    else {
      if (!reserve_history(s) || !(blank = new_row(s))) return false;
      allocated = true;
    }
  }
  if (!fill(s, blank, 0, s->columns, style, true)) {
    if (allocated) free_row(s, blank);
    return false;
  }
  blank->view.wrapped = false;
  if (up && history && s->history_limit) {
    if (!group_append(s)) return false;
    if (s->history_count == s->history_limit) {
      group_drop(s,1);
      s->history[s->history_head] = old;
      s->history_head = (s->history_head + 1) % s->history_capacity;
    } else s->history[(s->history_head + s->history_count++) % s->history_capacity] = old;
  }
  if (up && top == 0 && bottom + 1 == s->rows) {
    s->head = (s->head + 1) % s->rows; set(s, bottom, blank);
  } else if (up) {
    for (size_t y = top; y < bottom; y++) set(s, y, at(s, y + 1));
    set(s, bottom, blank);
  } else {
    for (size_t y = bottom; y > top; y--) set(s, y, at(s, y - 1));
    set(s, top, blank);
  }
  /* Appending a default blank to history keeps every retained row in its
   * logical group. fill already invalidated changed evicted style counts. */
  if (!(up && history && s->history_limit && !style)) { styles_dirty(s); graphemes_dirty(s); }
  return true;
}
bool lpage_scroll(lpage_screen *s, size_t top, size_t bottom, int count, bool history, uint32_t style) {
  if (top > bottom || bottom >= s->rows || !lstyle_retain(s->styles, style)) return false;
  size_t n = (size_t)(count < 0 ? -(int64_t)count : count);
  if (n > bottom - top + 1) n = bottom - top + 1;
  history = history && top == 0 && bottom + 1 == s->rows;
  bool ok = true;
  for (size_t i = 0; i < n && ok; i++) ok = scroll_one(s, top, bottom, count > 0, history, style);
  if (n) s->damage_all = true;
  lstyle_release(s->styles, style); return ok;
}
size_t lpage_history_count(const lpage_screen *s) { return s->history_count; }
const lpage_row *lpage_history(const lpage_screen *s, size_t i) {
  return i < s->history_count ? &s->history[(s->history_head + i) % s->history_capacity]->view : NULL;
}
void lp_geometry_trim(lpage_screen *s) {
  /* Cold geometry/history cleanup, never a per-line scan while scrolling. */
  s->available = NULL;
  page **link = &s->pages;
  while (*link) {
    page *p = *link;
    if (p->free_bits == UINT16_MAX) { *link = p->next; free(p); s->page_count--; }
    else {
      if (p->free_bits) { p->available = s->available; s->available = p; }
      link = &p->next;
    }
  }
}
void lpage_clear_history(lpage_screen *s) {
  styles_dirty(s);
  graphemes_dirty(s);
  for (size_t i=0;i<s->history_count;i++) free_row(s,s->history[(s->history_head+i)%s->history_capacity]);
  group_drop(s,s->history_count); s->history_count=s->history_head=0; lp_geometry_trim(s);
}
void lpage_wrap(lpage_screen *s, size_t y, bool wrapped) {
  if (y < s->rows) {
    row *r = at(s, y); r->view.wrapped = wrapped; row_changed(r);
    if (!wrapped) r->cells[s->columns - 1].flags &= (uint8_t)~LP_CELL_WIDE_HEAD;
  }
}
bool lpage_dirty(const lpage_screen *s, size_t y) { return y < s->rows && (s->damage_all || at(s, y)->dirty); }
void lpage_damage_all(lpage_screen *s) { s->damage_all = true; }
void lpage_ack_damage(lpage_screen *s) {
  s->damage_all = false; for (size_t y = 0; y < s->rows; y++) at(s, y)->dirty = false;
}
lpage_stats lpage_usage(const lpage_screen *s) {
  lpage_stats stats = { s->page_count, s->page_count * PAGE_ROWS, s->history_count, lstyle_count(s->styles), 0,
    llink_count(s->links), llink_bytes(s->links), lgrapheme_count(s->graphemes), lgrapheme_bytes(s->graphemes) };
  stats.bytes = sizeof *s + (s->rows + s->history_capacity) * sizeof(row *)
    + lstyle_bytes(s->styles) + stats.link_bytes + stats.grapheme_bytes + s->group_capacity*sizeof *s->groups;
  for (const page *p=s->pages;p;p=p->next) stats.bytes+=sizeof *p+PAGE_ROWS*p->columns*sizeof(lpage_cell);
  for (size_t i=0;i<s->group_count;i++) {
    const logical_page *g=group_at(s,i);
    size_t sizes[2]={g->style_refs.capacity,g->grapheme_offsets.capacity};
    for (unsigned j=0;j<2;j++) {
      size_t n=sizes[j];
      if (n) stats.bytes+=((n+16+63)&~(size_t)63)+((n*8+63)&~(size_t)63)+((n*4+63)&~(size_t)63);
    }
    stats.bytes+=(size_t)g->grapheme_bitmap.words*sizeof *g->grapheme_bitmap.bits;
  }
  return stats;
}
