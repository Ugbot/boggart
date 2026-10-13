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
#define LP_CELL_WIDE_TAIL 1
#define LP_CELL_PROTECTED 2
typedef struct {
  uint32_t codepoint, style, hyperlink;
  uint8_t width, flags;
  uint16_t reserved;
} lpage_cell;
typedef struct { const lpage_cell *cells; size_t columns; bool wrapped; } lpage_row;
typedef struct lpage_screen lpage_screen;
typedef struct { size_t pages, row_capacity, history_rows, styles, bytes, links, link_bytes; } lpage_stats;
lpage_screen *lpage_create(size_t columns, size_t rows, size_t history_limit);
void lpage_destroy(lpage_screen *screen);
size_t lpage_columns(const lpage_screen *screen);
size_t lpage_rows(const lpage_screen *screen);
lstyle_pool *lpage_styles(lpage_screen *screen);
llink_pool *lpage_links(lpage_screen *screen);
const llink_value *lpage_link(const lpage_screen *screen, uint32_t id);
/* All rows/cells are borrowed, and may move/recycle on the next mutation. */
const lpage_row *lpage_visible(const lpage_screen *screen, size_t row);
const lpage_cell *lpage_get(const lpage_screen *screen, size_t row, size_t column);
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
