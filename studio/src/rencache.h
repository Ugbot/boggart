#ifndef RENCACHE_H
#define RENCACHE_H

#include <stdbool.h>
#include "renderer.h"
#include "termrender.h"

void rencache_show_debug(bool enable);
void rencache_free_font(RenFont *font);
void rencache_set_clip_rect(RenRect rect);
void rencache_draw_rect(RenRect rect, RenColor color);
void rencache_draw_image(RenImage *image, RenRect sub, RenRect dst, RenColor color);
void rencache_draw_line(float x0, float y0, float x1, float y1, float thickness, RenColor color);
int  rencache_draw_text(RenFont *font, const char *text, int x, int y, RenColor color);
bool rencache_draw_grid(RenFont *font,const char *text,size_t length,int x,int y,RenColor color,int *end);
/* Commands own rows until end_frame, including frames with no damage. */
bool rencache_draw_row(tg_row *row, RenFont *font, const tg_theme *theme,
                      double x, int y, int cell_width, int cell_height, RenRect bounds);
void rencache_invalidate(void);
void rencache_begin_frame(void);
void rencache_end_frame(void);
/* Snapshot of the last completed frame; replay counts include each dirty rect. */
typedef struct {
  size_t rows_queued,rows_replayed,rows_skipped;
  int dirty_rects;
  RenGlyphStats glyphs;
} RenCacheStats;
RenCacheStats rencache_stats(void);

#endif
