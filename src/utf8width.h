/* Compatibility names for the shared Unicode kernel in bunicode.c.
 * Existing scalar renderers measure scalars; grapheme storage/rendering will
 * switch together under BMUX-19. No shaping or bidi is performed here.
 */
#ifndef BOGGART_UTF8WIDTH_H
#define BOGGART_UTF8WIDTH_H
#include "bunicode.h"

static inline int bog_cp_width(uint32_t cp) {
  return bunicode_width(cp);
}
static inline const char *bog_utf8_next(const char *p, const char *end, uint32_t *cp) {
  return bunicode_utf8_next(p, end, cp);
}
static inline int bog_str_width(const char *s, size_t length) {
  return bunicode_str_width(s, length);
}
static inline size_t bog_str_take(const char *s, size_t length, int columns, int *used) {
  return bunicode_str_take(s, length, columns, used);
}
#endif
