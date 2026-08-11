#ifndef RENDERER_H
#define RENDERER_H

#include <SDL2/SDL.h>
#include <stdint.h>
#include <stddef.h>

typedef struct RenImage RenImage;
typedef struct RenFont RenFont;

typedef struct { uint8_t b, g, r, a; } RenColor;
typedef struct { int x, y, width, height; } RenRect;


void ren_init(SDL_Window *win);
void ren_update_rects(RenRect *rects, int count);
void ren_set_clip_rect(RenRect rect);
void ren_get_size(int *x, int *y);

RenImage* ren_new_image(int width, int height);
void ren_free_image(RenImage *image);

RenFont* ren_load_font(const char *filename, float size);
/* Same, from bytes already in memory -- a font baked into the binary by
 * tools/bake_assets.cmake. The bytes are copied, so the caller keeps ownership
 * and .rodata is never written to. */
RenFont* ren_load_font_mem(const void *data, size_t len, float size);
void ren_free_font(RenFont *font);
/* The system fonts discovered to draw what the bundled ones cannot, in the
 * order they are consulted. Diagnostic: it is how a user finds out why their
 * Japanese is boxes, and how the tests assert the chain degrades rather than
 * crashing on a machine that has none. */
int ren_fallback_count(void);
const char* ren_fallback_path(int i, int *loaded);
void ren_set_font_tab_width(RenFont *font, int n);
int ren_get_font_tab_width(RenFont *font);
int ren_get_font_width(RenFont *font, const char *text);
int ren_get_font_height(RenFont *font);

void ren_draw_rect(RenRect rect, RenColor color);
void ren_draw_line(float x0, float y0, float x1, float y1, float thickness, RenColor color);
void ren_draw_image(RenImage *image, RenRect *sub, int x, int y, RenColor color);
int ren_draw_text(RenFont *font, const char *text, int x, int y, RenColor color);

#endif
