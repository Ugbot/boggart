/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/page.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/PageList.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Screen.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: portable contiguous row pages, screen-owned style IDs, visible
 * and history pointer rings. Reflow and tracked selections are separate work.
 */
#include "lpage.h"
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
};
static row *at(const lpage_screen *s, size_t y) { return s->visible[(s->head + y) % s->rows]; }
static void set(lpage_screen *s, size_t y, row *r) { s->visible[(s->head + y) % s->rows] = r; }
static row *new_row(lpage_screen *s) {
  page *p = s->available;
  if (!p) {
    size_t bytes = sizeof *p + PAGE_ROWS * s->columns * sizeof(lpage_cell);
    p = calloc(1, bytes);
    if (!p) return NULL;
    p->free_bits = UINT16_MAX;
    for (unsigned slot = 0; slot < PAGE_ROWS; slot++) {
      row *r = &p->rows[slot];
      r->cells = &p->cells[slot * s->columns];
      r->view.cells = r->cells; r->view.columns = s->columns;
      r->owner = p; r->slot = slot;
    }
    p->next = s->pages; s->pages = p; s->available = p; s->page_count++;
  }
  unsigned slot = 0;
  while (!(p->free_bits & (1u << slot))) slot++;
  p->free_bits = (uint16_t)(p->free_bits & ~(1u << slot));
  if (!p->free_bits) s->available = p->available;
  row *r = &p->rows[slot];
  for (size_t x = 0; x < s->columns; x++) r->cells[x] = (lpage_cell){0, 0, 0, 1, 0, 0};
  r->view.wrapped = false; r->dirty = true;
  return r;
}
static void free_row(lpage_screen *s, row *r) {
  for (size_t x = 0; x < s->columns; x++) {
    lstyle_release(s->styles, r->cells[x].style); r->cells[x].style = 0;
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
  if (!s->styles || !s->visible) { lpage_destroy(s); return NULL; }
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
  free(s->visible); free(s->history); lstyle_destroy(s->styles); free(s);
}
size_t lpage_columns(const lpage_screen *s) { return s->columns; }
size_t lpage_rows(const lpage_screen *s) { return s->rows; }
lstyle_pool *lpage_styles(lpage_screen *s) { return s->styles; }
const lpage_row *lpage_visible(const lpage_screen *s, size_t y) { return y < s->rows ? &at(s, y)->view : NULL; }
const lpage_cell *lpage_get(const lpage_screen *s, size_t y, size_t x) {
  return y < s->rows && x < s->columns ? &at(s, y)->cells[x] : NULL;
}
bool lpage_put(lpage_screen *s, size_t y, size_t x, lpage_cell cell) {
  if (y >= s->rows || x >= s->columns || cell.width > 2 || !lstyle_retain(s->styles, cell.style)) return false;
  row *r = at(s, y);
  lstyle_release(s->styles, r->cells[x].style); r->cells[x] = cell; r->dirty = true;
  return true;
}
static bool fill(lpage_screen *s, row *r, size_t x, size_t n, uint32_t style, bool release_old) {
  for (size_t i = x; i < x + n; i++) {
    if (!lstyle_retain(s->styles, style)) return false;
    if (release_old) lstyle_release(s->styles, r->cells[i].style);
    r->cells[i] = (lpage_cell){ 0, style, 0, 1, 0, 0 };
  }
  r->dirty = true;
  return true;
}
bool lpage_erase(lpage_screen *s, size_t y, size_t x, size_t n, uint32_t style) {
  if (y >= s->rows || x > s->columns || !lstyle_retain(s->styles, style)) return false;
  if (n > s->columns - x) n = s->columns - x;
  row *r = at(s, y);
  bool ok = fill(s, r, x, n, style, true);
  if (x == 0 && n == s->columns) r->view.wrapped = false;
  lstyle_release(s->styles, style); return ok;
}
static bool edit(lpage_screen *s, size_t y, size_t x, size_t n, uint32_t style, bool insert) {
  if (y >= s->rows || x > s->columns || !lstyle_retain(s->styles, style)) return false;
  if (n > s->columns - x) n = s->columns - x;
  row *r = at(s, y);
  size_t discard = insert ? s->columns - n : x;
  for (size_t i = discard; i < discard + n; i++) lstyle_release(s->styles, r->cells[i].style);
  size_t tail = s->columns - x - n;
  if (insert) memmove(r->cells + x + n, r->cells + x, tail * sizeof(lpage_cell));
  else memmove(r->cells + x, r->cells + x + n, tail * sizeof(lpage_cell));
  bool ok = fill(s, r, insert ? x : s->columns - n, n, style, false);
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
void lpage_clear_history(lpage_screen *s) {
  for (size_t i = 0; i < s->history_count; i++) free_row(s, s->history[(s->history_head + i) % s->history_capacity]);
  s->history_count = s->history_head = 0;
  /* Rebuild availability while removing empty pages; this is a history-clear
   * operation, never a per-line scan of the page list on the scrolling path. */
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
void lpage_wrap(lpage_screen *s, size_t y, bool wrapped) {
  if (y < s->rows) { row *r = at(s, y); r->view.wrapped = wrapped; r->dirty = true; }
}
bool lpage_dirty(const lpage_screen *s, size_t y) { return y < s->rows && (s->damage_all || at(s, y)->dirty); }
void lpage_damage_all(lpage_screen *s) { s->damage_all = true; }
void lpage_ack_damage(lpage_screen *s) {
  s->damage_all = false; for (size_t y = 0; y < s->rows; y++) at(s, y)->dirty = false;
}
lpage_stats lpage_usage(const lpage_screen *s) {
  lpage_stats stats = { s->page_count, s->page_count * PAGE_ROWS, s->history_count, lstyle_count(s->styles), 0 };
  stats.bytes = sizeof *s + (s->rows + s->history_capacity) * sizeof(row *)
    + s->page_count * (sizeof(page) + PAGE_ROWS * s->columns * sizeof(lpage_cell)) + lstyle_bytes(s->styles);
  return stats;
}
