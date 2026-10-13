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
#include <stdlib.h>
#include <string.h>
#define PAGE_ROWS 16
typedef struct page page;
typedef struct {
  lpage_row view;
  lpage_cell *cells;
  page *owner;
  unsigned slot;
  bool dirty;
} row;
struct page {
  page *next, *available;
  size_t columns; /* allocated width; a crop may expose fewer columns */
  uint16_t free_bits;
  row rows[PAGE_ROWS];
  lpage_cell cells[];
};
struct lpage_screen {
  size_t columns, rows, head, history_limit, history_capacity, history_head, history_count;
  row **visible, **history;
  page *pages, *available;
  size_t page_count;
  bool damage_all;
  lstyle_pool *styles;
  llink_pool *links;
  lgrapheme_pool *graphemes;
};
static row *at(const lpage_screen *s, size_t y) { return s->visible[(s->head + y) % s->rows]; }
static void set(lpage_screen *s, size_t y, row *r) { s->visible[(s->head + y) % s->rows] = r; }
void lpage_release_cell(lpage_screen *s, lpage_cell cell) {
  if (cell.style) lstyle_release(s->styles, cell.style);
  if (cell.hyperlink) llink_release(s->links, cell.hyperlink);
  if (cell.flags & LP_CELL_GRAPHEME) lgrapheme_release(s->graphemes, cell.codepoint);
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
  for (size_t x = 0; x < p->columns; x++) r->cells[x] = (lpage_cell){0, 0, 0, 1, 0, 0};
  r->view.columns=s->columns;
  r->view.wrapped = false; r->dirty = true;
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
    if (!(s->visible[y] = new_row(s))) { lpage_destroy(s); return NULL; }
  }
  s->damage_all = true;
  return s;
}
void lpage_destroy(lpage_screen *s) {
  if (!s) return;
  page *p = s->pages;
  while (p) { page *next = p->next; free(p); p = next; }
  free(s->visible); free(s->history); lstyle_destroy(s->styles); llink_destroy(s->links); lgrapheme_destroy(s->graphemes); free(s);
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
  free(s->visible); free(s->history);
}
lpage_screen *lp_geometry_new(const lpage_screen *source,size_t columns,size_t rows) {
  if (!columns || !rows || columns>4096 || rows>4096) return NULL;
  lpage_screen *s=calloc(1,sizeof *s); if (!s) return NULL;
  s->columns=columns; s->rows=rows; s->history_limit=source->history_limit;
  s->styles=source->styles; s->links=source->links; s->graphemes=source->graphemes;
  s->visible=calloc(rows,sizeof *s->visible);
  if (!s->visible) { free(s); return NULL; }
  s->damage_all=true; return s;
}
bool lp_geometry_row(lpage_screen *s,size_t y,size_t capacity) {
  if (y>=s->rows || (capacity && (capacity<s->columns || capacity>4096))) return false;
  row *old=at(s,y);
  if (old && (!capacity || old->owner->columns==capacity)) return true;
  row *r=new_row_capacity(s,capacity); if (!r) return false;
  if (old) free_row(s,old);
  set(s,y,r); return true;
}
static row *absolute_row(const lpage_screen *s,size_t y) {
  return y<s->history_count ? s->history[(s->history_head+y)%s->history_capacity] : at(s,y-s->history_count);
}
size_t lp_row_capacity(const lpage_screen *s,size_t y) { return absolute_row(s,y)->owner->columns; }
bool lp_row_page_has_head(const lpage_screen *s,size_t y) {
  const page *p=absolute_row(s,y)->owner;
  for (unsigned slot=0;slot<PAGE_ROWS;slot++)
    if (!(p->free_bits&(1u<<slot)) && (p->rows[slot].cells[s->columns-1].flags&LP_CELL_WIDE_HEAD)) return true;
  return false;
}
void lp_geometry_destroy(lpage_screen *s) { if (s) { geometry_free(s); free(s); } }
void lp_geometry_replace(lpage_screen *s,lpage_screen *geometry) {
  geometry_free(s); *s=*geometry; free(geometry);
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
  if ((repair_head && x<=1 && r->cells[0].width==2 && !clear_previous_head(s,y,cell.style))
      || !break_pair(s, r, x, cell.style) || (cell.width == 2 && !break_pair(s, r, x + 1, cell.style))) {
    lpage_release_cell(s, cell); if (cell.width == 2) lpage_release_cell(s, tail); return false;
  }
  lpage_release_cell(s, r->cells[x]); r->cells[x] = cell; r->dirty = true;
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
  lpage_cell cell=*old; uint32_t id;
  if (cell.flags & LP_CELL_GRAPHEME) {
    if (!lgrapheme_append(s->graphemes,cell.codepoint,cp,&id)) return false;
  } else {
    uint32_t cps[]={cell.codepoint,cp};
    if (!lgrapheme_acquire(s->graphemes,cps,2,&id)) return false;
  }
  cell.codepoint=id; cell.flags|=LP_CELL_GRAPHEME; cell.width=(uint8_t)width;
  bool ok=put_cell(s,y,x,cell,width!=old->width); lgrapheme_release(s->graphemes,id); return ok;
}
static bool fill(lpage_screen *s, row *r, size_t x, size_t n, uint32_t style, bool release_old) {
  for (size_t i = x; i < x + n; i++) {
    if (style && !lstyle_retain(s->styles, style)) return false;
    if (release_old) lpage_release_cell(s, r->cells[i]);
    r->cells[i] = (lpage_cell){ 0, style, 0, 1, 0, 0 };
  }
  r->dirty = true;
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
    if (s->history_count == s->history_limit) {
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
  for (size_t i=0;i<s->history_count;i++) free_row(s,s->history[(s->history_head+i)%s->history_capacity]);
  s->history_count=s->history_head=0; lp_geometry_trim(s);
}
void lpage_wrap(lpage_screen *s, size_t y, bool wrapped) {
  if (y < s->rows) {
    row *r = at(s, y); r->view.wrapped = wrapped; r->dirty = true;
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
    + lstyle_bytes(s->styles) + stats.link_bytes + stats.grapheme_bytes;
  for (const page *p=s->pages;p;p=p->next) stats.bytes+=sizeof *p+PAGE_ROWS*p->columns*sizeof(lpage_cell);
  return stats;
}
