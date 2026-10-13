/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/page.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE. */
#ifndef LPAGE_LAYOUT_H
#define LPAGE_LAYOUT_H
#include <stdbool.h>
#include <stdint.h>

/* Private SDK layout arithmetic, independent of native cell/slab storage.
 * The shape describes the pinned SDK target, not the host C allocator. */
typedef struct { uint32_t page_align, cell_align; unsigned word_bytes; } lp_layout_shape;
typedef struct {
  uint16_t cols, rows, styles, hyperlink_bytes;
  uint32_t grapheme_bytes, string_bytes;
} lp_capacity;
typedef struct {
  uint64_t total_size, rows_size, cells_start, cells_size, meta_start, meta_size;
  uint64_t styles_start, grapheme_alloc_start, grapheme_map_start;
  uint64_t string_alloc_start, hyperlink_set_start, hyperlink_map_start;
} lp_layout;

/* Failures leave outputs untouched. Zero-sized grids/metadata are valid. */
bool lp_capacity_layout(lp_layout_shape shape, lp_capacity cap, lp_layout *out);
bool lp_capacity_adjust(lp_layout_shape shape, lp_capacity cap, uint16_t columns, lp_capacity *out);
bool lp_capacity_initial(lp_layout_shape shape, uint16_t columns, lp_capacity *out);
typedef enum {
  LP_GROW_REHASH, LP_GROW_STYLES, LP_GROW_GRAPHEMES, LP_GROW_HYPERLINKS, LP_GROW_STRINGS
} lp_growth;
/* SDK metadata growth: double (or restore a zero default), saturate at the
 * field limit, then optionally project style/grapheme usage over all rows.
 * used is the living style count or allocated grapheme bytes at the failed
 * allocation; other dimensions ignore it. Invalid input/out-of-space leaves
 * out untouched. Rehash preserves capacity. No allocation or screen mutation. */
bool lp_capacity_grow(lp_layout_shape shape, lp_capacity capacity, lp_growth dimension,
                      uint32_t used, uint16_t used_rows, lp_capacity *out);
#endif
