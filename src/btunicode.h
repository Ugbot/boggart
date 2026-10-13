/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/unicode/grapheme.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * SDK terminal profile, separate from the Unicode 16 string helper policy.
 */
#ifndef BOGGART_BTUNICODE_H
#define BOGGART_BTUNICODE_H
#include "bunicode.h"
typedef struct {
  uint32_t previous;
  uint8_t machine;
  bool started;
} btunicode_state;
unsigned btunicode_width(uint32_t cp);
bool btunicode_break(btunicode_state *state, uint32_t cp);
bool btunicode_pictographic(uint32_t cp);
bunicode_width_effect btunicode_effect(uint32_t previous, uint32_t cp);
#endif
