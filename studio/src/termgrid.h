#ifndef BOGGART_TERMGRID_H
#define BOGGART_TERMGRID_H
#include "bterm.h"
typedef struct {
  lpage_style style;
  uint32_t text;
  uint16_t length;
  uint8_t width,flags;
} tg_cell;
/* Immutable resolved render row, loop-thread-owned. No pool IDs or borrowed
 * strings survive capture. Frame commands retain separately from row caches. */
typedef struct tg_row {
  uint32_t references,columns,bytes;
  uint64_t hash;
  tg_cell cells[];
} tg_row;
tg_row *tg_capture(const bterm *term,const lpage_row *row,size_t columns);
typedef struct { lpage_style style;const char *text;size_t length;uint8_t width,flags; } tg_value;
/* Resolved immutable values, copied synchronously. No terminal/parser owner. */
tg_row *tg_capture_values(const tg_value *values,size_t columns);
bool tg_retain(tg_row *row);
void tg_release(tg_row *row);
bool tg_equal(const tg_row *a,const tg_row *b);
const char *tg_text(const tg_row *row,const tg_cell *cell);
#endif
