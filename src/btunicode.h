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
/* Plain UTF-8 text, not VT cursor/escape interpretation. C0/DEL have no width;
 * malformed bytes each replace with U+FFFD. Mode and retention match printing.
 * Width saturates at INT_MAX. take never cuts an effective cluster. */
int btunicode_text_width(const char *text,size_t length,bool grapheme);
size_t btunicode_text_take(const char *text,size_t length,int columns,bool grapheme,int *used);
#endif
