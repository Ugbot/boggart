#ifndef BOGGART_TERMRENDER_H
#define BOGGART_TERMRENDER_H
#include "termgrid.h"
#include "renderer.h"
typedef struct { RenColor foreground,background,palette[16]; } tg_theme;
/* Include glyph advances/font height and decorations outside a short cell. */
bool tg_measure(const tg_row *row,RenFont *font,int cell_width,int cell_height,RenRect *bounds);
void tg_draw(const tg_row *row,RenFont *font,const tg_theme *theme,double x,int y,int cell_width,int cell_height);
#endif
