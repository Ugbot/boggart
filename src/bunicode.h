/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/unicode/grapheme.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Width effects follow Ghostty; segmentation is an independent UAX #29 implementation.
 */
#ifndef BOGGART_BUNICODE_H
#define BOGGART_BUNICODE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define BUNICODE_VERSION "16.0.0"
/* Packed table format; kept in sync by tools/genwidth.py. */
#define BU_WIDTH_MASK 3u
#define BU_GCB_SHIFT 2u
#define BU_GCB_MASK 15u
#define BU_INCB_SHIFT 6u
#define BU_INCB_MASK 3u
#define BU_PICTOGRAPHIC (1u << 8)
#define BU_EMOJI_PRESENTATION (1u << 9)
#define BU_EMOJI_VS_BASE (1u << 10)
#define BU_ZERO_IN_GRAPHEME (1u << 11)

enum bunicode_gcb {
  BU_OTHER, BU_CR, BU_LF, BU_CONTROL, BU_EXTEND, BU_ZWJ, BU_RI,
  BU_PREPEND, BU_SPACING_MARK, BU_L, BU_V, BU_T, BU_LV, BU_LVT
};
enum bunicode_incb { BU_INCB_NONE, BU_INCB_CONSONANT, BU_INCB_EXTEND, BU_INCB_LINKER };

/* Zero initialize for start of text; pass each scalar exactly once. Returns
 * whether a boundary precedes cp, including the first scalar. End of text is
 * always a boundary. No buffer, allocation, or limits on cluster length. */
typedef struct {
  uint32_t previous;
  uint16_t properties;
  uint8_t regional_odd, ep_extend, ep_zwj, indic;
  bool started;
} bunicode_grapheme_state;

uint16_t bunicode_properties(uint32_t cp);
/* Scalar width 0/1/2; invalid scalar values measure 1. Ambiguous width is 1. */
int bunicode_width(uint32_t cp);
bool bunicode_grapheme_break(bunicode_grapheme_state *state, uint32_t cp);

typedef enum { BU_WIDTH_IGNORE, BU_WIDTH_UNCHANGED, BU_WIDTH_WIDE, BU_WIDTH_NARROW }
  bunicode_width_effect;
/* Only call after segmentation reports no boundary. Invalid emoji selectors
 * are ignored: a streaming printer must restore its previous break state. */
bunicode_width_effect bunicode_grapheme_width_effect(uint32_t previous, uint32_t cp);
/* First complete cluster in a scalar array; no input mutation. Empty => 0/0.
 * consumes ignored selectors too. This measures terminal cells, not pixels. */
int bunicode_grapheme_width(const uint32_t *cps, size_t length, size_t *consumed);

/* Decode one scalar. end may be NULL for NUL-terminated input. An invalid or
 * truncated encoding yields U+FFFD and consumes exactly one byte. At an empty
 * bounded input (or a NUL terminator without end), returns p and sets cp to 0. */
const char *bunicode_utf8_next(const char *p, const char *end, uint32_t *cp);
/* Encode a scalar into four available bytes; invalid values become U+FFFD.
 * Returns 0 for NULL output, otherwise 1-4. Embedded NUL is one byte. */
size_t bunicode_utf8_put(uint32_t cp,char *out);
/* Compatibility measurement: sum scalar widths, saturating at INT_MAX.
 * These deliberately do not collapse clusters until the renderers do. */
int bunicode_str_width(const char *s, size_t length);
size_t bunicode_str_take(const char *s, size_t length, int columns, int *used);
#endif
