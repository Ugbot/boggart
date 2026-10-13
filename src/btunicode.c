/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/unicode/grapheme.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 */
#include "btunicode.h"
#include "btunicode_data.h"
static bool valid(uint32_t cp) {
  return cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff);
}
static uint16_t properties(uint32_t cp) {
  return btunicode_pages[(size_t)btunicode_index[cp >> 8] * 256 + (cp & 255)];
}
unsigned btunicode_width(uint32_t cp) {
  /* The printer filters controls first and uses this byte-sized fast path. */
  return cp <= 255 || !valid(cp) ? 1 : properties(cp) & 3;
}
bool btunicode_break(btunicode_state *s, uint32_t cp) {
  bool boundary = true;
  if (s->started && valid(s->previous) && valid(cp)) {
    unsigned a = (properties(s->previous) >> 3) & 31;
    unsigned b = (properties(cp) >> 3) & 31;
    unsigned value = btunicode_transitions[s->machine | (a << 3) | (b << 8)];
    boundary = (value & 1) != 0;
    s->machine = (uint8_t)(value >> 1);
  } else s->machine = 0;
  s->previous = cp; s->started = true;
  return boundary;
}
bool btunicode_pictographic(uint32_t cp) {
  return valid(cp) && ((properties(cp) >> 3) & 31) == 11;
}
bunicode_width_effect btunicode_effect(uint32_t previous, uint32_t cp) {
  if (cp == 0xfe0e || cp == 0xfe0f) {
    if (!valid(previous) || !(properties(previous) & 256)) return BU_WIDTH_IGNORE;
    return cp == 0xfe0f ? BU_WIDTH_WIDE : BU_WIDTH_NARROW;
  }
  return valid(cp) && (properties(cp) & 4) ? BU_WIDTH_UNCHANGED : BU_WIDTH_WIDE;
}
