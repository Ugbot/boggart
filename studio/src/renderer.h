#ifndef RENDERER_H
#define RENDERER_H

#include <SDL2/SDL.h>
#include <stdint.h>
#include <stddef.h>

typedef struct RenImage RenImage;
typedef struct RenFont RenFont;

typedef struct { uint8_t b, g, r, a; } RenColor;
typedef struct { int x, y, width, height; } RenRect;

/* How a glyph is rasterised, and how hard the outline is pulled onto the pixel
 * grid before it is. Both are per font, because the answers differ: the code
 * font wants everything the hinter will give it, and an icon font wants none of
 * it (hinting a pictograph distorts the picture).
 *
 * REN_AA_SUBPIXEL asks FreeType for LCD coverage -- three samples per pixel,
 * one per colour stripe -- which is a real legibility win on a 1x RGB-striped
 * panel and wrong everywhere else: on a rotated or OLED panel the stripe order
 * differs, and on a HiDPI backing store the fringes land between physical
 * subpixels and read as colour noise. It is offered, not defaulted. */
typedef enum {
  REN_AA_NONE,       /* 1-bit, no antialiasing at all */
  REN_AA_GRAYSCALE,  /* 8-bit coverage; the default */
  REN_AA_SUBPIXEL    /* LCD: 8-bit coverage per colour stripe */
} RenAntialias;

typedef enum {
  REN_HINT_NONE,     /* the outline as designed */
  REN_HINT_SLIGHT,   /* vertical-only autohint; the default, see renderer.c */
  REN_HINT_FULL      /* the autohinter's full grid fitting */
} RenHinting;

enum {
  REN_STYLE_BOLD          = 1 << 0,
  REN_STYLE_ITALIC        = 1 << 1,
  REN_STYLE_UNDERLINE     = 1 << 2,
  REN_STYLE_STRIKETHROUGH = 1 << 3
};

/* NULL anywhere a `const RenFontOptions*` is taken means "the defaults", which
 * are grayscale antialiasing, slight hinting and no synthesised style. */
typedef struct {
  RenAntialias antialiasing;
  RenHinting hinting;
  unsigned style;
} RenFontOptions;


void ren_init(SDL_Window *win);
void ren_update_rects(RenRect *rects, int count);
void ren_set_clip_rect(RenRect rect);
void ren_get_size(int *x, int *y);

RenImage* ren_new_image(int width, int height);
void ren_free_image(RenImage *image);

RenFont* ren_load_font(const char *filename, float size, const RenFontOptions *opt);
/* Same, from bytes already in memory -- a font baked into the binary by
 * tools/bake_assets.cmake. The bytes are copied, so the caller keeps ownership
 * and .rodata is never written to. The copy also has to outlive the FT_Face
 * built on top of it, which is why ren_free_font drops the face first. */
RenFont* ren_load_font_mem(const void *data, size_t len, float size,
                           const RenFontOptions *opt);
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
