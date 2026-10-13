/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/page.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/PageList.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/ref_counted_set.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/bitmap_allocator.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/hash_map.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/style.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/hyperlink.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: compute SDK geometry with explicit target shape and uint64_t
 * offsets. No allocations or dependency on native row/cell representations.
 */
#include "lpage_layout.h"
#include <stddef.h>

static bool power2(uint64_t n) { return n && !(n&(n-1)); }
static uint64_t align_up(uint64_t n,uint64_t a) { return (n+a-1)&~(a-1); }
static uint64_t ceil_power2(uint64_t n) { uint64_t p=1; while (p<n) p*=2; return p; }
static bool valid(lp_layout_shape s) {
  return (s.word_bytes==4 || s.word_bytes==8) && power2(s.page_align) && power2(s.cell_align)
    && s.cell_align>=8 && s.page_align>=s.cell_align;
}
static uint64_t set_size(uint64_t count,uint64_t item_size,uint64_t item_align) {
  if (!count) return 0;
  uint64_t table=ceil_power2(count),items=table*13/16;
  return align_up(table*2,item_align)+items*item_size;
}
static uint64_t bitmap_size(uint64_t bytes,uint64_t chunk) {
  uint64_t chunks=align_up((bytes+chunk-1)/chunk,64);
  return chunks/64*8+chunks*chunk;
}
static uint64_t map_size(uint64_t count,unsigned load,uint64_t value_size,uint64_t value_align) {
  uint64_t raw=count ? ceil_power2((count*100+load-1)/load) : 0;
  if (raw>UINT64_C(2147483648)) raw=UINT64_C(2147483648);
  uint64_t keys=align_up(4+raw,4)+raw*4;
  return align_up(align_up(keys,value_align)+raw*value_size,value_align>4 ? value_align : 4);
}
bool lp_capacity_layout(lp_layout_shape s,lp_capacity c,lp_layout *out) {
  if (!out || !valid(s)) return false;
  lp_layout l={0};
  uint64_t word=s.word_bytes,hyper_item=word==8 ? 48 : 28;
  /* Style: three 8-byte tagged colors, u16 flags (28 bytes after alignment),
   * then three u16 set metadata (36-byte item aligned to 4).
   * Hyperlink item: tagged offset slice + URI slice + set metadata, word aligned. */
  uint64_t offset=set_size(c.styles,36,4);
  l.grapheme_alloc_start=align_up(offset,8);
  offset=l.grapheme_alloc_start+bitmap_size(c.grapheme_bytes,16);
  uint64_t graphemes=c.grapheme_bytes ? ceil_power2(((uint64_t)c.grapheme_bytes+15)/16) : 0;
  l.grapheme_map_start=align_up(offset,word);
  offset=l.grapheme_map_start+map_size(graphemes,100,word*2,word);
  l.string_alloc_start=align_up(offset,8);
  offset=l.string_alloc_start+bitmap_size(c.string_bytes,32);
  uint64_t links=c.hyperlink_bytes/hyper_item;
  l.hyperlink_set_start=align_up(offset,word);
  offset=l.hyperlink_set_start+set_size(links,hyper_item,word);
  l.hyperlink_map_start=align_up(offset,4);
  /* Hyperlink IDs are u16; keys are u32 offsets and the map load is 80%. */
  offset=l.hyperlink_map_start+map_size(links*16,80,2,2);
  l.meta_size=offset;
  l.rows_size=(uint64_t)c.rows*8;
  l.cells_start=align_up(l.rows_size,s.cell_align);
  l.cells_size=(uint64_t)c.cols*c.rows*8;
  l.meta_start=align_up(l.cells_start+l.cells_size,8);
  l.total_size=align_up(l.meta_start+l.meta_size,s.page_align);
  l.grapheme_alloc_start+=l.meta_start; l.grapheme_map_start+=l.meta_start;
  l.string_alloc_start+=l.meta_start; l.hyperlink_set_start+=l.meta_start;
  l.hyperlink_map_start+=l.meta_start; l.styles_start=l.meta_start;
  *out=l; return true;
}
bool lp_capacity_adjust(lp_layout_shape s,lp_capacity c,uint16_t columns,lp_capacity *out) {
  lp_layout old,l;
  if (!out || !columns || !lp_capacity_layout(s,c,&old)) return false;
  uint64_t rows=(old.total_size-old.meta_size)/(8+(uint64_t)columns*8);
  /* SDK CellCountInt is u16. Keep oversized geometries outside this private API. */
  if (rows>UINT16_MAX) return false;
  c.cols=columns;
  while (rows) {
    c.rows=(uint16_t)rows;
    if (!lp_capacity_layout(s,c,&l)) return false;
    if (l.total_size<=old.total_size) { *out=c; return true; }
    rows--;
  }
  return false;
}
bool lp_capacity_initial(lp_layout_shape s,uint16_t columns,lp_capacity *out) {
  if (!out || !columns || !valid(s)) return false;
  lp_capacity c={215,215,128,(uint16_t)(4*(s.word_bytes==8 ? 48 : 28)),8192,2048};
  if (lp_capacity_adjust(s,c,columns,out)) return true;
  c.cols=columns; *out=c; return true;
}
