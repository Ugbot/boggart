/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/unicode/grapheme.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Width effects follow Ghostty; segmentation is an independent UAX #29 implementation.
 */
#include "bunicode.h"
#include "bunicode_data.h"
#include <limits.h>

static bool valid(uint32_t cp) {
  return cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff);
}

uint16_t bunicode_properties(uint32_t cp) {
  if (!valid(cp)) return 1;
  return bunicode_pages[bunicode_page_index[cp >> 8]][cp & 255];
}

int bunicode_width(uint32_t cp) {
  if (cp >= 0x20 && cp < 0x7f) return 1;
  return (int)(bunicode_properties(cp) & BU_WIDTH_MASK);
}

static unsigned gcb(uint16_t props) { return (props >> BU_GCB_SHIFT) & BU_GCB_MASK; }
static unsigned incb(uint16_t props) { return (props >> BU_INCB_SHIFT) & BU_INCB_MASK; }
static bool control(unsigned gb) { return gb == BU_CR || gb == BU_LF || gb == BU_CONTROL; }

bool bunicode_grapheme_break(bunicode_grapheme_state *s, uint32_t cp) {
  uint16_t props = bunicode_properties(cp);
  unsigned a = gcb(s->properties), b = gcb(props), in = incb(props);
  bool boundary = true;
  if (s->started && valid(s->previous) && valid(cp)) {
    if (a == BU_CR && b == BU_LF) boundary = false; /* GB3 */
    else if (control(a) || control(b)) boundary = true; /* GB4/5 */
    else if (a == BU_L && (b == BU_L || b == BU_V || b == BU_LV || b == BU_LVT)) boundary = false; /* GB6 */
    else if ((a == BU_LV || a == BU_V) && (b == BU_V || b == BU_T)) boundary = false; /* GB7 */
    else if ((a == BU_LVT || a == BU_T) && b == BU_T) boundary = false; /* GB8 */
    else if (b == BU_EXTEND || b == BU_ZWJ || b == BU_SPACING_MARK) boundary = false; /* GB9/9a */
    else if (a == BU_PREPEND) boundary = false; /* GB9b */
    else if (s->indic == 2 && in == BU_INCB_CONSONANT) boundary = false; /* GB9c */
    else if (s->ep_zwj && (props & BU_PICTOGRAPHIC)) boundary = false; /* GB11 */
    else if (a == BU_RI && b == BU_RI && s->regional_odd) boundary = false; /* GB12/13 */
  }
  if (boundary) {
    s->regional_odd = s->ep_extend = s->ep_zwj = s->indic = 0;
  }
  s->regional_odd = b == BU_RI ? (uint8_t)!s->regional_odd : 0;
  s->ep_zwj = (uint8_t)(b == BU_ZWJ && s->ep_extend);
  if (props & BU_PICTOGRAPHIC) s->ep_extend = 1;
  else if (b != BU_EXTEND) s->ep_extend = 0;
  if (in == BU_INCB_CONSONANT) s->indic = 1;
  else if (in == BU_INCB_LINKER) { if (s->indic) s->indic = 2; }
  else if (in != BU_INCB_EXTEND) s->indic = 0;
  s->started = true; s->previous = cp; s->properties = props;
  return boundary;
}

bunicode_width_effect bunicode_grapheme_width_effect(uint32_t previous, uint32_t cp) {
  if (cp == 0xfe0e || cp == 0xfe0f) {
    if (!(bunicode_properties(previous) & BU_EMOJI_VS_BASE)) return BU_WIDTH_IGNORE;
    return cp == 0xfe0f ? BU_WIDTH_WIDE : BU_WIDTH_NARROW;
  }
  if (!(bunicode_properties(cp) & BU_ZERO_IN_GRAPHEME)) return BU_WIDTH_WIDE;
  return BU_WIDTH_UNCHANGED;
}

int bunicode_grapheme_width(const uint32_t *cps, size_t length, size_t *consumed) {
  if (consumed) *consumed = 0;
  if (!length) return 0;
  if (!valid(cps[0])) { if (consumed) *consumed = 1; return 1; }
  int width = bunicode_width(cps[0]);
  bunicode_grapheme_state state = {0};
  (void)bunicode_grapheme_break(&state, cps[0]);
  uint32_t previous = cps[0]; size_t n = 1;
  for (; n < length; n++) {
    bunicode_grapheme_state before = state;
    if (bunicode_grapheme_break(&state, cps[n])) break;
    switch (bunicode_grapheme_width_effect(previous, cps[n])) {
      case BU_WIDTH_IGNORE: state = before; break;
      case BU_WIDTH_UNCHANGED: previous = cps[n]; break;
      case BU_WIDTH_WIDE: width = 2; previous = cps[n]; break;
      case BU_WIDTH_NARROW: width = 1; previous = cps[n]; break;
    }
  }
  if (consumed) *consumed = n;
  return width;
}

const char *bunicode_utf8_next(const char *p, const char *end, uint32_t *cp) {
  *cp = 0;
  if ((end && p == end) || (!end && !*p)) return p;
  uint8_t first = (uint8_t)*p;
  if (first < 0x80) { *cp = first; return p + 1; }
  unsigned length;
  uint32_t value, minimum;
  if (first >= 0xc2 && first <= 0xdf) { length = 2; value = first & 0x1f; minimum = 0x80; }
  else if (first >= 0xe0 && first <= 0xef) { length = 3; value = first & 0x0f; minimum = 0x800; }
  else if (first >= 0xf0 && first <= 0xf4) { length = 4; value = first & 7; minimum = 0x10000; }
  else goto invalid;
  for (unsigned i = 1; i < length; i++) {
    if (end && (size_t)(end - p) <= i) goto invalid;
    uint8_t next = (uint8_t)p[i];
    if ((next & 0xc0) != 0x80) goto invalid;
    value = (value << 6) | (next & 0x3f);
  }
  if (value < minimum || !valid(value)) goto invalid;
  *cp = value; return p + length;
invalid:
  *cp = 0xfffd; return p + 1;
}

int bunicode_str_width(const char *s, size_t length) {
  if (!length) return 0;
  const char *p = s, *end = s + length; int width = 0;
  while (p < end) {
    uint32_t cp; p = bunicode_utf8_next(p, end, &cp);
    int cells = bunicode_width(cp);
    if (width > INT_MAX - cells) return INT_MAX;
    width += cells;
  }
  return width;
}

size_t bunicode_str_take(const char *s, size_t length, int columns, int *used) {
  if (used) *used = 0;
  if (!length || columns < 0) return 0;
  const char *p = s, *end = s + length; int width = 0;
  while (p < end) {
    uint32_t cp; const char *next = bunicode_utf8_next(p, end, &cp);
    int cells = bunicode_width(cp);
    if (cells > columns - width) break;
    width += cells; p = next;
  }
  if (used) *used = width;
  return (size_t)(p - s);
}
