/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/page.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/PageList.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Screen.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 */
#ifndef BOGGART_LPAGE_H
#define BOGGART_LPAGE_H
#include "lstyle.h"
#include "llink.h"
#include "lgrapheme.h"
#define LP_CELL_WIDE_TAIL 1
#define LP_CELL_PROTECTED 2
#define LP_CELL_WIDE_HEAD 4
#define LP_CELL_GRAPHEME 8
typedef struct {
  /* codepoint is a pool ID when GRAPHEME is set. Use the accessors below. */
  uint32_t codepoint, style, hyperlink;
  uint8_t width, flags;
  uint16_t reserved;
} lpage_cell;
typedef struct {
  const lpage_cell *cells; size_t columns; bool wrapped;
  /* Content generation is independent of consumable damage flags. Multiple
   * renderers may acknowledge damage without invalidating another's cache. */
  uint64_t revision;
} lpage_row;
typedef struct lpage_screen lpage_screen;
typedef struct { size_t x, y; bool pending_wrap; } lpage_position;
typedef struct {
  size_t columns, rows;
  bool reflow, pull_scrollback;
  lpage_position cursor, saved;
  bool saved_valid;
} lpage_resize_options;
typedef struct lpage_resize lpage_resize;
/* Prepare retains copied cell references, or borrows unchanged-width rows,
 * without publishing geometry or changing source ownership.
 * The source must not mutate before commit/abort. Both consume the candidate;
 * commit cannot allocate. Failure leaves the source and its refs unchanged. */
lpage_resize *lpage_resize_prepare(lpage_screen *screen, lpage_resize_options options);
lpage_position lpage_resize_cursor(const lpage_resize *resize);
lpage_position lpage_resize_saved(const lpage_resize *resize);
void lpage_resize_commit(lpage_resize *resize);
void lpage_resize_abort(lpage_resize *resize);
typedef struct { size_t pages, row_capacity, history_rows, styles, bytes, links, link_bytes, graphemes, grapheme_bytes; } lpage_stats;
lpage_screen *lpage_create(size_t columns, size_t rows, size_t history_limit);
void lpage_destroy(lpage_screen *screen);
size_t lpage_columns(const lpage_screen *screen);
size_t lpage_rows(const lpage_screen *screen);
lstyle_pool *lpage_styles(lpage_screen *screen);
llink_pool *lpage_links(lpage_screen *screen);
lgrapheme_pool *lpage_graphemes(lpage_screen *screen);
uint32_t lpage_codepoint(const lpage_screen *screen, const lpage_cell *cell);
lgrapheme_value lpage_grapheme(const lpage_screen *screen, const lpage_cell *cell);
/* Hold a copied cell across mutations of its screen. Release exactly once
 * after a successful retain. lpage_put retains its own copy, not this hold. */
bool lpage_retain_cell(lpage_screen *screen, lpage_cell cell);
void lpage_release_cell(lpage_screen *screen, lpage_cell cell);
/* Attach one scalar and update the glyph's width; only bases own graphemes. */
bool lpage_append_grapheme(lpage_screen *screen, size_t row, size_t column, uint32_t cp, unsigned width);
const llink_value *lpage_link(const lpage_screen *screen, uint32_t id);
/* All rows/cells are borrowed, and may move/recycle on the next mutation. */
const lpage_row *lpage_visible(const lpage_screen *screen, size_t row);
const lpage_cell *lpage_get(const lpage_screen *screen, size_t row, size_t column);
/* Writes a whole glyph. Width 2 creates its continuation atomically with
 * respect to geometry/ID validation; callers cannot put a tail directly.
 * Overwriting either half clears the old pair. Width 2 must fit the row.
 * WIDE_HEAD is a blank at the last column of a wrapped row, preceding a wide
 * glyph on the next row. Erase/edit repair every pair crossing their bounds. */
bool lpage_put(lpage_screen *screen, size_t row, size_t column, lpage_cell cell);
bool lpage_erase(lpage_screen *screen, size_t row, size_t column, size_t count, uint32_t blank_style);
bool lpage_insert_cells(lpage_screen *screen, size_t row, size_t column, size_t count, uint32_t blank_style);
bool lpage_delete_cells(lpage_screen *screen, size_t row, size_t column, size_t count, uint32_t blank_style);
/* Positive count scrolls up. Only full-screen upward scroll may save history. */
bool lpage_scroll(lpage_screen *screen, size_t top, size_t bottom, int count,
                  bool save_history, uint32_t blank_style);
size_t lpage_history_count(const lpage_screen *screen);
const lpage_row *lpage_history(const lpage_screen *screen, size_t index);
void lpage_clear_history(lpage_screen *screen);
void lpage_wrap(lpage_screen *screen, size_t row, bool wrapped);
bool lpage_dirty(const lpage_screen *screen, size_t row);
void lpage_damage_all(lpage_screen *screen);
void lpage_ack_damage(lpage_screen *screen);
lpage_stats lpage_usage(const lpage_screen *screen);
#endif
