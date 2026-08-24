#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <assert.h>
#include <math.h>
#include <string.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_LCD_FILTER_H
#include FT_OUTLINE_H
#include "renderer.h"
#include "fontfallback.h"
#include "utf8width.h"

/* Why FreeType and not stb_truetype, which this used to be.
 *
 * stb_truetype has no hinting. None: it scales the outline and rasterises it
 * wherever it lands, so a 13px stem that wants to be one pixel wide comes out
 * as two columns of 50% grey and the whole page reads soft. That is the entire
 * legibility gap against every other editor on the machine, and no amount of
 * work on the blend or the atlas closes it -- the information was thrown away
 * at rasterisation.
 *
 * FreeType's autohinter is the fix, and specifically its *light* mode, which
 * only ever moves points vertically. That matters more here than it does in a
 * general text engine: horizontal grid fitting changes advance widths, and this
 * renderer's whole contract with the layout above it is that a monospace
 * advance is exactly one or two cells (see the snapping in pack_block). Light
 * hinting sharpens the horizontals -- baselines, x-height, crossbars, which is
 * where small text lives or dies -- and leaves the metrics alone.
 *
 * The cost is a vendored dependency of about a megabyte in the binary. It buys
 * hinting, real bitmap-strike and CFF support, correct metrics, and native
 * TrueType-collection handling that used to need a special case here. */

/* Glyph caching, and why it is a three-level table.
 *
 * This was `GlyphSet *sets[256]` indexed by `(codepoint >> 8) % 256`, which
 * is exactly the codepoints U+0000..U+FFFF and nothing else. Every codepoint
 * above the BMP -- which is all emoji, all of CJK Extension B, all of the
 * mathematical alphanumerics -- wrapped onto a slot already holding some
 * unrelated BMP block and drew whatever happened to live there. Not a blank:
 * a wrong glyph, silently.
 *
 * Unicode is 17 planes of 256 blocks, so a flat table of every block is 4352
 * pointers -- 34 KB per font, and the UI loads four fonts. That is not much,
 * but it is more than one glyph atlas (a 128x128 RGBA image is 64 KB) and it
 * is paid whether or not anything outside Latin is ever drawn. A plane table
 * of 17 pointers, each pointing at a 256-entry block table allocated the first
 * time that plane is touched, costs 136 bytes for a session that only ever
 * renders ASCII and 2 KB more per plane that is not. Two dereferences, no
 * hashing, no collisions, and nothing wraps. */
#define GLYPH_PLANES 17          /* U+0000..U+10FFFF */
#define BLOCKS_PER_PLANE 256

/* Subpixel positioning: how many horizontal phases of each glyph we keep.
 *
 * A glyph drawn at pen x = 100.0 and the same glyph at x = 100.66 are not the
 * same picture, and rounding the pen to an integer -- which is what this did
 * before -- throws away up to half a pixel of position on every character. In
 * a proportional run that error is not just blur, it is *uneven spacing*: the
 * gaps between letters wobble between two values because each advance was
 * floored independently. Three phases (0, 1/3, 2/3 of a pixel) is what lite-xl
 * settled on and it is enough; the residual is a sixth of a pixel.
 *
 * It costs nothing for the code font. Monospace advances are snapped to a whole
 * number of cells, so the pen never leaves the integers, phase 0 is the only
 * one ever asked for, and the other two atlases are never built. */
#define SUBPIXEL_BITMAPS 3

/* Primary plus every fallback face, where a .ttc contributes one face per
 * subfont. Bounded because the chain is consulted linearly and a face past
 * the twentieth is not adding coverage. */
#define MAX_FACES 32

struct RenImage {
  RenColor *pixels;
  int width, height;
};

/* Where one glyph sits in its atlas, and what it does to the pen. Was
 * stbtt_bakedchar; the fields are the same because the drawing code was
 * already written against them. */
typedef struct {
  unsigned short x0, y0, x1, y1;
  float xoff, yoff, xadvance;
} Glyph;

typedef struct {
  RenImage *image;
  SDL_Texture *texture;
  int tw, th;   /* atlas texture size, cached at bake -- constant per set, so the
                 * draw loop reads it here instead of SDL_GetTextureSize per glyph */
  /* An LCD atlas holds three coverages per pixel in r/g/b rather than one
   * alpha, so it needs a different blend. Recorded per atlas rather than per
   * font because a bitmap-strike glyph inside a subpixel font still comes out
   * grayscale. GPU drawing always uses coverage-in-A (see load_glyphset). */
  int lcd;
  Glyph glyphs[256];
} GlyphSet;

typedef struct { GlyphSet *phase[SUBPIXEL_BITMAPS]; } Block;

/* One font file (or one subfont of a collection) at this RenFont's size.
 * The face reads directly out of memory owned elsewhere: font->data for the
 * primary, fontfallback.c's process-wide cache for the rest. FreeType does not
 * copy that memory, so it has to outlive the face -- see ren_free_font. */
typedef struct {
  FT_Face face;
} Face;

struct RenFont {
  void *data;
  size_t datalen;
  Block *planes[GLYPH_PLANES];
  Face faces[MAX_FACES];
  int nfaces;        /* faces materialised so far; faces[0] is ours */
  int next_file;     /* next entry of the fallback chain left to expand */
  uint32_t covered;  /* union of the accepted faces' coverage signatures */
  float size;
  int height;
  int baseline;
  int underline;     /* thickness in pixels, at least 1 */
  /* Monospace fonts get their advances snapped to the cell grid -- see
   * pack_block. Zero when the font is proportional. */
  int cell;
  /* What Lua last asked a tab to advance by, 0 until it asks. Remembered
   * rather than only written into the atlas, because a subpixel phase baked
   * after the call would otherwise get the font's own tab advance back. */
  int tab_advance;
  unsigned char antialias, hinting;
  unsigned style;
};


static SDL_Window *window;
static SDL_Renderer *renderer;
static SDL_Texture *target;
static int target_w, target_h;
static struct { int left, top, right, bottom; } clip;
static FT_Library library;

#define GLYPH_BATCH_MAX 256
static SDL_Vertex glyph_batch[GLYPH_BATCH_MAX * 4];
static SDL_Texture *glyph_batch_tex;
static int glyph_batch_n;

static void glyph_batch_flush(void);

static bool target_undrawn;

static void ensure_target(void) {
  int pw = 0, ph = 0;
  if (!window || !renderer) { return; }
  SDL_GetWindowSizeInPixels(window, &pw, &ph);
  if (pw < 1) { pw = 1; }
  if (ph < 1) { ph = 1; }
  if (target && target_w == pw && target_h == ph) { return; }
  if (target) { SDL_DestroyTexture(target); target = NULL; }
  target = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                             SDL_TEXTUREACCESS_TARGET, pw, ph);
  target_w = pw;
  target_h = ph;
  if (target) {
    SDL_SetTextureScaleMode(target, SDL_SCALEMODE_NEAREST);
    SDL_SetRenderTarget(renderer, target);
    /* Match the studio chrome, not black: a resize that presents before the
       next Lua frame would otherwise flash the swapchain black. The undrawn
       flag still skips that present entirely (see ren_update_rects). */
    SDL_SetRenderDrawColor(renderer, 46, 46, 50, 255);
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_NONE);
    SDL_RenderClear(renderer);
    target_undrawn = true;
  }
}

static void bind_target(void) {
  ensure_target();
  if (!renderer || !target) { return; }
  target_undrawn = false;
  if (SDL_GetRenderTarget(renderer) != target) {
    SDL_SetRenderTarget(renderer, target);
  }
  SDL_Rect r = {
    clip.left, clip.top,
    clip.right - clip.left, clip.bottom - clip.top
  };
  if (r.w <= 0 || r.h <= 0) {
    SDL_SetRenderClipRect(renderer, NULL);
  } else {
    SDL_SetRenderClipRect(renderer, &r);
  }
}


static void glyph_batch_flush(void) {
  if (glyph_batch_n <= 0 || !renderer) {
    glyph_batch_n = 0;
    glyph_batch_tex = NULL;
    return;
  }
  int indices[GLYPH_BATCH_MAX * 6];
  for (int i = 0; i < glyph_batch_n; i++) {
    int v = i * 4;
    int b = i * 6;
    indices[b + 0] = v + 0;
    indices[b + 1] = v + 1;
    indices[b + 2] = v + 2;
    indices[b + 3] = v + 0;
    indices[b + 4] = v + 2;
    indices[b + 5] = v + 3;
  }
  SDL_SetRenderTarget(renderer, target);
  SDL_Rect r = {
    clip.left, clip.top,
    clip.right - clip.left, clip.bottom - clip.top
  };
  if (r.w <= 0 || r.h <= 0) {
    SDL_SetRenderClipRect(renderer, NULL);
  } else {
    SDL_SetRenderClipRect(renderer, &r);
  }
  SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
  SDL_RenderGeometry(renderer, glyph_batch_tex, glyph_batch, glyph_batch_n * 4,
                     indices, glyph_batch_n * 6);
  glyph_batch_n = 0;
  glyph_batch_tex = NULL;
}


static void* check_alloc(void *ptr) {
  if (!ptr) {
    fprintf(stderr, "Fatal error: memory allocation failed\n");
    exit(EXIT_FAILURE);
  }
  return ptr;
}


/* FreeType is initialised on first use rather than in ren_init, because fonts
 * are loaded from Lua and a headless probe can reach renderer.font.load before
 * a window exists. */
static int ft_ready(void) {
  if (!library && FT_Init_FreeType(&library) != 0) { library = NULL; }
  return library != NULL;
}


/* The decoder that used to live here now lives in src/utf8width.h next to the
 * width tables, because the studio and the terminal dashboard must agree
 * byte-for-byte on where one character ends and the next begins. Two lenient
 * decoders drifting apart is how a caret ends up half a codepoint away from
 * where the renderer thinks it drew. */
static const char* utf8_to_codepoint(const char *p, unsigned *dst) {
  uint32_t cp;
  const char *next = bog_utf8_next(p, NULL, &cp);
  *dst = cp;
  return next;
}


void ren_init(SDL_Window *win) {
  assert(win);
  window = win;
  renderer = SDL_CreateRenderer(window, NULL);
  if (!renderer) {
    fprintf(stderr, "Fatal error: SDL_CreateRenderer failed: %s\n", SDL_GetError());
    exit(EXIT_FAILURE);
  }
  SDL_SetRenderVSync(renderer, 0);
  ensure_target();
  ren_set_clip_rect( (RenRect) { 0, 0, target_w, target_h } );
}


void ren_update_rects(RenRect *rects, int count) {
  (void)rects;
  glyph_batch_flush();
  /* A just-resized target is filled with chrome grey and has no scene yet.
     Presenting it is the black/smear flash on the first event after a drag. */
  if (count > 0 && renderer && target && !target_undrawn) {
    SDL_SetRenderTarget(renderer, NULL);
    SDL_SetRenderClipRect(renderer, NULL);
    SDL_RenderTexture(renderer, target, NULL, NULL);
    SDL_RenderPresent(renderer);
  }
  static bool initial_frame = true;
  if (initial_frame) {
    SDL_ShowWindow(window);
    initial_frame = false;
  }
}


void ren_set_clip_rect(RenRect rect) {
  glyph_batch_flush();
  clip.left   = rect.x;
  clip.top    = rect.y;
  clip.right  = rect.x + rect.width;
  clip.bottom = rect.y + rect.height;
}


void ren_get_size(int *x, int *y) {
  ensure_target();
  *x = target_w;
  *y = target_h;
}


int ren_save_screenshot(const char *path) {
  if (!renderer || !target) { return -1; }
  glyph_batch_flush();
  SDL_SetRenderTarget(renderer, target);
  SDL_Surface *surf = SDL_RenderReadPixels(renderer, NULL);
  if (!surf) { return -1; }
  int ok = SDL_SaveBMP(surf, path) ? 0 : -1;
  SDL_DestroySurface(surf);
  return ok;
}


RenImage* ren_new_image(int width, int height) {
  assert(width > 0 && height > 0);
  RenImage *image = malloc(sizeof(RenImage) + width * height * sizeof(RenColor));
  check_alloc(image);
  image->pixels = (void*) (image + 1);
  image->width = width;
  image->height = height;
  return image;
}


void ren_free_image(RenImage *image) {
  free(image);
}


/* ---- FreeType load and render options -------------------------------------
 *
 * The split is FreeType's: the *load* flags decide how the outline is fitted
 * to the grid, the *render* mode decides how it is sampled. Hinting therefore
 * belongs to the first and antialiasing to the second, and they are chosen
 * separately because a font can sensibly want either without the other. */
static int load_flags(const RenFont *font) {
  int target = FT_LOAD_TARGET_NORMAL;
  if (font->antialias == REN_AA_NONE) {
    target = FT_LOAD_TARGET_MONO;
  } else if (font->hinting == REN_HINT_SLIGHT) {
    target = FT_LOAD_TARGET_LIGHT;
  }
  /* FORCE_AUTOHINT rather than the font's own bytecode. The autohinter is
   * consistent across every font we might fall back to, including the ones
   * whose shipped bytecode was written for a rasteriser that no longer
   * exists; a fallback chain that renders each face by a different set of
   * rules is exactly the inconsistency this is trying to remove. */
  int hint = (font->hinting == REN_HINT_NONE)
    ? FT_LOAD_NO_HINTING : FT_LOAD_FORCE_AUTOHINT;
  return target | hint;
}


static int render_mode(const RenFont *font) {
  if (font->antialias == REN_AA_NONE) { return FT_RENDER_MODE_MONO; }
  if (font->antialias == REN_AA_SUBPIXEL) {
    /* The five-tap FIR that spreads each stripe's energy into its neighbours.
     * Without it a subpixel-rendered stem is a coloured bar rather than a
     * black one; the filter is what trades the fringes back for resolution.
     * Weights are FreeType's own light default. A build without
     * FT_CONFIG_OPTION_SUBPIXEL_RENDERING answers "unimplemented" and uses
     * Harmony mode instead, which needs no filter -- either is fine, so the
     * return value is deliberately ignored. */
    unsigned char weights[] = { 0x10, 0x40, 0x70, 0x40, 0x10 };
    if (font->hinting == REN_HINT_NONE) {
      FT_Library_SetLcdFilter(library, FT_LCD_FILTER_NONE);
    } else {
      FT_Library_SetLcdFilterWeights(library, weights);
    }
    return FT_RENDER_MODE_LCD;
  }
  return font->hinting == REN_HINT_NONE
    ? FT_RENDER_MODE_NORMAL : FT_RENDER_MODE_LIGHT;
}


/* One codepoint per script or block we might have to draw, used as a coverage
 * signature. A subfont whose signature adds no bit the chain already has is a
 * different weight of a face we have -- and .ttc collections are mostly
 * weights: AppleSDGothicNeo.ttc is eighteen of them.
 *
 * That mattered rather than being tidy. Admitting all eighteen filled the face
 * budget before the chain reached Geeza Pro or Kohinoor, so on this machine
 * Arabic and Devanagari had fallbacks discovered, listed, and never consulted.
 * Coverage is what a fallback is for, so coverage is what earns a slot.
 *
 * The signature is a sample, so two faces differing only outside it collapse
 * into one. Thirty-two probes across the scripts a code editor sees is a good
 * trade against the alternative, which is intersecting whole cmaps. */
static const int FACE_PROBE[] = {
  0x0041, 0x00E9, 0x03B1, 0x0410, 0x05D0, 0x0627, 0x0915, 0x0E01,
  0x10A0, 0x0531, 0x1200, 0x0700, 0x0D85, 0x1780, 0x3042, 0x30A2,
  0x3131, 0x4E2D, 0x9F8D, 0xD55C, 0x2192, 0x2500, 0x2665, 0x2200,
  0xFF21, 0x20AC, 0x1E00, 0xA000, 0x1F600, 0x1D400, 0x13000, 0x2E80,
};
#define FACE_PROBE_N ((int) (sizeof FACE_PROBE / sizeof *FACE_PROBE))

static uint32_t face_signature(FT_Face face) {
  uint32_t sig = 0;
  for (int i = 0; i < FACE_PROBE_N; i++) {
    if (FT_Get_Char_Index(face, (FT_ULong) FACE_PROBE[i])) { sig |= 1u << i; }
  }
  return sig;
}


/* Size a face so that its em box is `size` pixels tall.
 *
 * Em, not cap height and not line height, and the same rule for every face in
 * the chain -- that is what makes a 27px Hiragino ideograph and a 27px Latin
 * letter agree about how big they are. FT_Set_Char_Size at 72 dpi is the only
 * way to say that in fractional pixels; FT_Set_Pixel_Sizes takes an integer
 * and would quietly turn our 13.5 into 13. The integer call is still the
 * fallback, because a bitmap-strike face has no continuous sizes and rejects
 * the first form. */
static int face_set_size(FT_Face face, float size) {
  FT_F26Dot6 sz = (FT_F26Dot6) (size * 64.0f + 0.5f);
  if (FT_Set_Char_Size(face, 0, sz, 72, 72) == 0) { return 1; }
  if (FT_Set_Pixel_Sizes(face, 0, (FT_UInt) (size + 0.5f)) == 0) { return 1; }
  return 0;
}


/* The i-th face of this font's chain, materialised on demand, or NULL once the
 * chain runs out.
 *
 * Lazy file by file, not lazy in one lump. Callers walk i upwards until a face
 * has the glyph, so a block of ASCII never opens a fallback at all, a block of
 * Japanese opens files up to the first CJK one, and only a codepoint that
 * nothing on the machine can draw pays for reading the whole chain -- which is
 * a one-off of tens of megabytes, once, and then it is cached for the session.
 *
 * A .ttc is a collection and its subfonts are separate faces. Some collections
 * really are several families -- Noto Sans CJK ships JP, KR, SC and TC in one
 * file -- so they are all considered, and filtered by what they add. */
static Face* face_at(RenFont *font, int i) {
  if (i < 0 || i >= MAX_FACES) { return NULL; }
  while (i >= font->nfaces) {
    int n = 0;
    FontFallback *chain = fontfallback_chain(&n);
    if (font->next_file >= n) { return NULL; }

    FontFallback *entry = &chain[font->next_file++];
    size_t sz = 0;
    unsigned char *data = fontfallback_data(entry, &sz);
    if (!data) { continue; }

    /* Face index -1 asks FreeType for the collection's shape without building
     * anything; num_faces is 1 for a plain file. */
    FT_Face probe = NULL;
    FT_Long nsub = 1;
    if (FT_New_Memory_Face(library, data, (FT_Long) sz, -1, &probe) == 0) {
      nsub = probe->num_faces > 0 ? probe->num_faces : 1;
      FT_Done_Face(probe);
    }

    for (FT_Long s = 0; s < nsub && font->nfaces < MAX_FACES; s++) {
      FT_Face f = NULL;
      if (FT_New_Memory_Face(library, data, (FT_Long) sz, s, &f) != 0) { continue; }
      /* A face with no Unicode cmap cannot answer "do you have U+65E5", which
       * is the only question the chain asks it. */
      if (!f->charmap && FT_Select_Charmap(f, FT_ENCODING_UNICODE) != 0) {
        FT_Done_Face(f);
        continue;
      }
      uint32_t sig = face_signature(f);
      if ((sig & ~font->covered) == 0 || !face_set_size(f, font->size)) {
        FT_Done_Face(f);
        continue;
      }
      font->covered |= sig;
      font->faces[font->nfaces++].face = f;
      entry->usable = 1;
    }
  }
  return &font->faces[i];
}


/* Which face draws this codepoint, and as which glyph.
 *
 * FT_Get_Char_Index returning 0 means "this font has no glyph for that
 * character" -- it is the .notdef index, not an error -- and that is the whole
 * test a fallback chain needs. First face that answers wins, so the chain's
 * order in fontfallback.c is the coverage policy.
 *
 * Returns 0 when nothing has it, with *out set to the primary face, so the
 * caller draws our own .notdef. That is deliberate: a character the machine
 * cannot draw should look like a character the machine cannot draw, not like
 * a space. */
static int find_glyph(RenFont *font, unsigned cp, Face **out) {
  for (int i = 0; i < MAX_FACES; i++) {
    Face *f = face_at(font, i);
    if (!f) { break; }
    FT_UInt g = FT_Get_Char_Index(f->face, (FT_ULong) cp);
    if (g) { *out = f; return (int) g; }
  }
  *out = &font->faces[0];
  return 0;
}


/* ---- baking a block -------------------------------------------------------
 *
 * A glyph as FreeType hands it over, before it has been given a home in an
 * atlas. Kept for the whole block because the atlas is sized by trial: the
 * shelf packer is told 128x128, and if the block does not fit it is told 256
 * and so on. Rendering is by far the expensive half of that loop -- an
 * autohinted CJK ideograph is not cheap and there are 256 of them -- so it
 * happens once and only the arithmetic is repeated. */
typedef struct {
  unsigned char *bits;   /* w*h, or w*h*3 when lcd; NULL for a blank */
  int w, h;
  int left, top;         /* FreeType's bitmap_left / bitmap_top */
  float advance;
  int lcd;
} RawGlyph;


/* The advance, measured with hinting off.
 *
 * Separate from the render pass and deliberately so. A grid-fitted advance is
 * rounded to a whole pixel by the hinter, and for a monospace face that means
 * the reported cell width depends on which glyph you asked about -- which is
 * how a "monospace" font stops being one. Positioning and styling do not touch
 * the advance either, so this is also the only load the three subpixel phases
 * need to share. */
static float glyph_advance(RenFont *font, FT_Face face, FT_UInt gid) {
  int flags = (load_flags(font) | FT_LOAD_NO_HINTING) & ~FT_LOAD_FORCE_AUTOHINT;
  if (FT_Load_Glyph(face, gid, flags) != 0) { return 0.0f; }
  return face->glyph->advance.x / 64.0f;
}


/* Render one glyph at one subpixel phase into `g`. Returns 0 if there is
 * nothing to draw, which covers both failure and the ordinary case of a space.
 *
 * The phase shift happens after FT_Load_Glyph, so it moves an outline that has
 * already been hinted. That is only sound because the hinting is vertical
 * (see load_flags): a horizontal nudge cannot undo alignment that was never
 * horizontal. It would be wrong under full hinting, which is one more reason
 * slight is the default. */
static int render_glyph(RenFont *font, FT_Face face, FT_UInt gid, int phase,
                        RawGlyph *g) {
  memset(g, 0, sizeof *g);
  if (FT_Load_Glyph(face, gid, load_flags(font)) != 0) { return 0; }

  FT_GlyphSlot slot = face->glyph;
  if (slot->format == FT_GLYPH_FORMAT_OUTLINE) {
    if (phase) {
      FT_Outline_Translate(&slot->outline, phase * (64 / SUBPIXEL_BITMAPS), 0);
    }
    /* Synthesised bold and italic: fatten in x only so the baseline and
     * x-height stay where the regular weight put them, and shear by 1/4 which
     * is the usual 14 degrees. Neither is as good as a real bold or italic
     * face and both are better than drawing the same shape twice. */
    if (font->style & REN_STYLE_BOLD) {
      FT_Outline_EmboldenXY(&slot->outline, 1 << 5, 0);
    }
    if (font->style & REN_STYLE_ITALIC) {
      FT_Matrix m = { 1 << 16, 1 << 14, 0, 1 << 16 };
      FT_Outline_Transform(&slot->outline, &m);
    }
  }
  if (FT_Render_Glyph(slot, render_mode(font)) != 0) { return 0; }

  FT_Bitmap *bm = &slot->bitmap;
  if (!bm->width || !bm->rows || !bm->buffer) { return 0; }

  int channels = 1;
  int w = (int) bm->width;
  if (bm->pixel_mode == FT_PIXEL_MODE_LCD) {
    channels = 3;
    w = (int) bm->width / 3;
  } else if (bm->pixel_mode != FT_PIXEL_MODE_GRAY
             && bm->pixel_mode != FT_PIXEL_MODE_MONO) {
    /* FT_PIXEL_MODE_BGRA is a colour glyph. fontfallback.c refuses colour
     * fonts before they get this far; a colour glyph inside an otherwise
     * monochrome face would land here, and a silhouette is worse than the
     * missing-glyph box, so treat it as absent. */
    return 0;
  }
  if (w <= 0) { return 0; }

  int h = (int) bm->rows;
  g->bits = check_alloc(calloc((size_t) w * (size_t) h, (size_t) channels));
  g->w = w;
  g->h = h;
  g->lcd = (channels == 3);
  g->left = slot->bitmap_left;
  g->top = slot->bitmap_top;

  for (int row = 0; row < h; row++) {
    const unsigned char *src = bm->buffer + (ptrdiff_t) row * bm->pitch;
    unsigned char *dst = g->bits + (size_t) row * (size_t) w * (size_t) channels;
    if (bm->pixel_mode == FT_PIXEL_MODE_MONO) {
      for (int x = 0; x < w; x++) {
        dst[x] = (unsigned char) (((src[x / 8] >> (7 - (x % 8))) & 1) * 0xff);
      }
    } else if (bm->pixel_mode == FT_PIXEL_MODE_GRAY && bm->num_grays != 256
               && bm->num_grays > 1) {
      /* A 2- or 4-level strike, which some bitmap faces ship. */
      for (int x = 0; x < w; x++) {
        dst[x] = (unsigned char) (src[x] * 255 / (bm->num_grays - 1));
      }
    } else {
      memcpy(dst, src, (size_t) w * (size_t) channels);
    }
  }
  return 1;
}


/* Nothing on this machine has this character. Draw the box.
 *
 * The alternative was in front of me on screen: emoji laid out two cells wide
 * and drawn as nothing at all, because monospace.ttf's .notdef is an empty
 * outline. Blank is the one thing a missing glyph must not be -- it reads as
 * "the text is not there" rather than "this font cannot draw the text", and
 * those call for completely different reactions from whoever is looking.
 * Synthesised rather than borrowed from a fallback's U+FFFD so it is always
 * available, including on a machine with no fallbacks at all. */
static void synth_missing(RenFont *font, unsigned cp, RawGlyph *g) {
  memset(g, 0, sizeof *g);
  int cells = bog_cp_width(cp);
  int w = (font->cell > 0 ? font->cell * cells : (int) (font->size * 0.55f)) - 2;
  int h = (int) (font->size * 0.72f);
  if (w < 3) { w = 3; }
  if (h < 3) { h = 3; }

  g->bits = check_alloc(calloc((size_t) w * (size_t) h, 1));
  g->w = w;
  g->h = h;
  g->left = 1;
  g->top = h;    /* sits on the baseline, like a capital letter */
  for (int c = 0; c < w; c++) { g->bits[c] = 0xa0; g->bits[c + (h - 1) * w] = 0xa0; }
  for (int r = 0; r < h; r++) { g->bits[r * w] = 0xa0; g->bits[w - 1 + r * w] = 0xa0; }
}


/* Shelf-pack the block's glyphs into a pw x ph atlas, filling in each Glyph's
 * rectangle. Returns 0 if they do not fit and the caller should try bigger.
 * The packing is stb_truetype's -- a row at a time, no rotation, no
 * repacking -- because it is the right amount of packing for a 256-glyph atlas
 * and there was no reason to invent a different one. */
static int pack_block(GlyphSet *set, const RawGlyph *raw, int pw, int ph) {
  int x = 1, y = 1, bottom_y = 1;
  for (int i = 0; i < 256; i++) {
    int w = raw[i].w, h = raw[i].h;
    if (x + w + 1 >= pw) { y = bottom_y; x = 1; }
    if (y + h + 1 >= ph) { return 0; }
    Glyph *g = &set->glyphs[i];
    g->x0 = (unsigned short) x;
    g->y0 = (unsigned short) y;
    g->x1 = (unsigned short) (x + w);
    g->y1 = (unsigned short) (y + h);
    x = x + w + 1;
    if (y + h + 1 > bottom_y) { bottom_y = y + h + 1; }
  }
  return 1;
}


static GlyphSet* load_glyphset(RenFont *font, int block, int phase) {
  GlyphSet *set = check_alloc(calloc(1, sizeof(GlyphSet)));
  RawGlyph raw[256];

  /* ---- render ------------------------------------------------------------
   *
   * Baseline alignment across faces is the subtle part. Each face is sized so
   * its em box is font->size pixels (face_set_size), and every glyph's
   * vertical offset is then measured from *our* font's baseline -- the
   * primary's, once, for every glyph. Sharing one baseline is what stops mixed
   * text from stepping up and down as it changes script. */
  for (int i = 0; i < 256; i++) {
    unsigned cp = (unsigned) block * 256u + (unsigned) i;
    Face *face = NULL;
    int gid = find_glyph(font, cp, &face);

    float advance = glyph_advance(font, face->face, (FT_UInt) gid);
    int missing = (gid == 0 && bog_cp_width(cp) > 0);

    if (missing) {
      synth_missing(font, cp, &raw[i]);
      raw[i].advance = advance;
      if (font->cell <= 0 && advance < (float) (raw[i].w + 2)) {
        /* A proportional font's .notdef often advances zero, which would stack
         * every unknown character on the same pixel. */
        raw[i].advance = (float) (raw[i].w + 2);
      }
    } else {
      if (!render_glyph(font, face->face, (FT_UInt) gid, phase, &raw[i])) {
        memset(&raw[i], 0, sizeof raw[i]);
      }
      raw[i].advance = advance;
    }

    /* Tab and newline are laid out by the code above the renderer and must not
     * also be drawn. A tab in particular has a real glyph in some faces. */
    if (cp == '\t' || cp == '\n') {
      free(raw[i].bits);
      raw[i].bits = NULL;
      raw[i].w = raw[i].h = 0;
    }
  }

  /* ---- place -------------------------------------------------------------- */
  int width = 128, height = 128;
  while (!pack_block(set, raw, width, height)) {
    /* CJK blocks are 256 ideographs at full em, so they land here two or three
     * times before they fit. Only the arithmetic repeats; see RawGlyph. */
    width *= 2;
    height *= 2;
  }
  set->image = ren_new_image(width, height);
  /* GPU path stores coverage in A. Per-channel LCD needs a custom blend that
   * is not portable across Metal/D3D/GL, and REN_AA_SUBPIXEL is already wrong
   * on HiDPI; average the three coverages instead. */
  set->lcd = 0;
  memset(set->image->pixels, 0, (size_t) width * (size_t) height * sizeof(RenColor));

  /* ---- blit and finish the metrics ---------------------------------------- */
  for (int i = 0; i < 256; i++) {
    unsigned cp = (unsigned) block * 256u + (unsigned) i;
    Glyph *g = &set->glyphs[i];
    const RawGlyph *r = &raw[i];

    /* Everything in one atlas is stored in that atlas's format, whatever the
     * glyph arrived as. It has to be: the blend is chosen per atlas, so a
     * grayscale glyph sitting in an LCD atlas -- the synthesised missing-glyph
     * box is exactly that, and so is anything that came from a bitmap strike --
     * would otherwise be composited as if its coverage were a colour. Widening
     * one coverage into three equal stripes is what grayscale *is* under the
     * subpixel blend, so the conversion is exact rather than approximate. */
    for (int row = 0; row < r->h; row++) {
      RenColor *dst = set->image->pixels + (g->y0 + row) * width + g->x0;
      const unsigned char *src = r->bits + (size_t) row * (size_t) r->w
                               * (size_t) (r->lcd ? 3 : 1);
      for (int c = 0; c < r->w; c++) {
        if (set->lcd) {
          unsigned char cr = r->lcd ? src[c * 3]     : src[c];
          unsigned char cg = r->lcd ? src[c * 3 + 1] : src[c];
          unsigned char cb = r->lcd ? src[c * 3 + 2] : src[c];
          dst[c] = (RenColor) { .r = cr, .g = cg, .b = cb, .a = 255 };
        } else {
          unsigned cov = r->lcd
            ? ((unsigned) src[c * 3] + src[c * 3 + 1] + src[c * 3 + 2]) / 3u
            : src[c];
          dst[c] = (RenColor) { .r = 255, .g = 255, .b = 255, .a = (uint8_t) cov };
        }
      }
    }

    g->xoff = (float) r->left;
    g->yoff = (float) (font->baseline - r->top);
    g->xadvance = r->advance;

    /* Grid snapping, and only for a monospace font.
     *
     * The chat panel measures in columns and multiplies by the width of "0".
     * A fallback face has its own advances -- Hiragino's ideograph is a full
     * em where our monospace cell is about 0.6 of one -- so an unsnapped CJK
     * run drifts left of the grid it was laid out on, a little more with every
     * character, and the caret ends up somewhere else entirely. Snapping the
     * advance to one or two cells, exactly as bog_cp_width says, is what makes
     * the drawn line and the measured line the same line.
     *
     * Centring within the cells is cosmetic and cheap: a wide glyph narrower
     * than two cells sits between them rather than hugging the left one.
     *
     * A proportional font gets none of this. There is no grid to snap to, and
     * forcing one would make the menu bar look like a ransom note -- it keeps
     * the fractional advance FreeType reported, which together with the three
     * subpixel phases is what makes its spacing even. */
    if (font->cell > 0) {
      int cells = bog_cp_width(cp);
      if (cells > 0) {
        float want = (float) (font->cell * cells);
        g->xoff += (want - g->xadvance) / 2.0f;
        g->xadvance = want;
      } else {
        /* A combining mark has no advance of its own and stacks on what came
         * before it. Only true for the simple cases -- there is no mark
         * positioning here, so the mark lands on the cell, not on the letter's
         * actual centre. */
        g->xadvance = 0.0f;
      }
    }

    free(raw[i].bits);
  }

  if (block == 0 && font->tab_advance > 0) {
    set->glyphs['\t'].xadvance = (float) font->tab_advance;
  }

  if (renderer) {
    set->texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                     SDL_TEXTUREACCESS_STATIC, width, height);
    if (!set->texture) {
      /* Text in this atlas will silently render as nothing; say so once. */
      fprintf(stderr, "Warning: (" __FILE__ "): glyph atlas texture failed: %s\n",
              SDL_GetError());
    }
    if (set->texture) {
      set->tw = width; set->th = height;
      SDL_SetTextureBlendMode(set->texture, SDL_BLENDMODE_BLEND);
      SDL_SetTextureScaleMode(set->texture, SDL_SCALEMODE_NEAREST);
      SDL_SetTextureColorMod(set->texture, 255, 255, 255);
      SDL_UpdateTexture(set->texture, NULL, set->image->pixels,
                        width * (int)sizeof(RenColor));
      ren_free_image(set->image);
      set->image = NULL;
    }
  }
  return set;
}


static GlyphSet* get_glyphset(RenFont *font, unsigned codepoint, int phase) {
  /* Unsigned throughout, so a decode that went wrong cannot index backwards --
   * font->planes[-1] is a pointer read out of the struct above this array, and
   * that is what a signed shift of a sign-extended continuation byte used to
   * produce. Anything past U+10FFFF is not a codepoint and is folded onto the
   * replacement character's block rather than given one of its own. */
  unsigned cp = codepoint;
  if (cp > 0x10FFFFu) { cp = 0xFFFDu; }

  unsigned plane = cp >> 16;
  unsigned block = (cp >> 8) & 0xffu;
  if (!font->planes[plane]) {
    font->planes[plane] = check_alloc(calloc(BLOCKS_PER_PLANE, sizeof(Block)));
  }
  Block *b = &font->planes[plane][block];
  if (!b->phase[phase]) {
    b->phase[phase] = load_glyphset(font, (int) (cp >> 8), phase);
  }
  return b->phase[phase];
}


/* The shared tail of ren_load_font and ren_load_font_mem: everything from
 * "we have the bytes" onwards. `font->data` is owned by the RenFont either
 * way -- the memory entry point copies, so a baked-in asset in read-only
 * .rodata and a file read off disk are freed the same way, and both outlive
 * the FT_Face that reads out of them. */
static RenFont* font_from_data(RenFont *font);


static void apply_options(RenFont *font, const RenFontOptions *opt) {
  font->antialias = REN_AA_GRAYSCALE;
  font->hinting = REN_HINT_SLIGHT;
  font->style = 0;
  if (opt) {
    font->antialias = (unsigned char) opt->antialiasing;
    font->hinting = (unsigned char) opt->hinting;
    font->style = opt->style;
  }
}


RenFont* ren_load_font_mem(const void *data, size_t len, float size,
                           const RenFontOptions *opt) {
  if (!data || len == 0) { return NULL; }
  RenFont *font = check_alloc(calloc(1, sizeof(RenFont)));
  font->size = size;
  apply_options(font, opt);
  font->data = check_alloc(malloc(len));
  font->datalen = len;
  memcpy(font->data, data, len);
  return font_from_data(font);
}


RenFont* ren_load_font(const char *filename, float size,
                       const RenFontOptions *opt) {
  RenFont *font = NULL;
  FILE *fp = NULL;

  /* init font */
  font = check_alloc(calloc(1, sizeof(RenFont)));
  font->size = size;
  apply_options(font, opt);

  /* load font into buffer */
  fp = fopen(filename, "rb");
  if (!fp) { free(font); return NULL; }
  /* get size */
  fseek(fp, 0, SEEK_END); long buf_size = ftell(fp); fseek(fp, 0, SEEK_SET);
  if (buf_size <= 0) { fclose(fp); free(font); return NULL; }
  /* load */
  font->data = check_alloc(malloc((size_t) buf_size));
  size_t got = fread(font->data, 1, (size_t) buf_size, fp);
  fclose(fp);
  if (got != (size_t) buf_size) { free(font->data); free(font); return NULL; }
  font->datalen = got;

  return font_from_data(font);
}


static RenFont* font_from_data(RenFont *font) {
  if (!ft_ready()) { goto fail; }

  /* Face 0 of the file. A TrueType *collection* (.ttc, and some .otf) packs
   * several faces behind a header; FreeType reads one natively, which is a
   * special case this used to need and no longer does. Face 0 is taken because
   * the alternative -- a syntax for naming a face inside a file -- is a setting
   * nobody wants to learn, and face 0 is the regular weight in every collection
   * I have looked at. */
  FT_Face face = NULL;
  if (FT_New_Memory_Face(library, font->data, (FT_Long) font->datalen, 0,
                         &face) != 0) {
    goto fail;
  }
  if (!face->charmap && FT_Select_Charmap(face, FT_ENCODING_UNICODE) != 0) {
    FT_Done_Face(face);
    goto fail;
  }
  if (!face_set_size(face, font->size)) {
    FT_Done_Face(face);
    goto fail;
  }

  /* The primary face is the head of its own fallback chain. Everything after
   * it is discovered lazily by face_at(). */
  font->faces[0].face = face;
  font->nfaces = 1;
  font->covered = face_signature(face);

  /* Vertical metrics. FT_IS_SCALABLE decides which of the two the face can
   * actually answer: an outline face is asked in design units and scaled here,
   * a bitmap strike only knows the size it was made at. */
  if (FT_IS_SCALABLE(face) && face->units_per_EM > 0) {
    float s = font->size / (float) face->units_per_EM;
    font->height = (int) (face->height * s + 0.5f);
    font->baseline = (int) (face->ascender * s + 0.5f);
    font->underline = (int) (face->underline_thickness * s + 0.5f);
  } else {
    font->height = (int) (face->size->metrics.height / 64.0f + 0.5f);
    font->baseline = (int) (face->size->metrics.ascender / 64.0f + 0.5f);
    font->underline = 0;
  }
  if (font->underline < 1) { font->underline = 1; }

  /* Is this a monospace font? Four characters that differ as much as Latin
   * ones can -- widest, narrowest, a digit, punctuation -- agreeing on their
   * advance is a reliable answer, and a cheap one. It decides whether glyphs
   * get snapped to a cell grid; see pack_block's snapping.
   *
   * All four have to be present. A font with none of them -- icons.ttf is
   * exactly that, fourteen pictographs and no Latin -- answers every probe
   * with .notdef, so the four advances agree trivially and an icon font would
   * be declared monospace and have every icon crushed to one cell.
   *
   * FT_IS_FIXED_WIDTH is not used instead: it reads the OS/2 panose byte,
   * which plenty of genuinely monospaced fonts leave unset. */
  {
    static const unsigned char probe[] = { 'W', 'i', '0', '.' };
    int cell = -1;
    font->cell = 0;
    for (size_t i = 0; i < sizeof probe; i++) {
      FT_UInt gid = FT_Get_Char_Index(face, (FT_ULong) probe[i]);
      if (!gid) { cell = 0; break; }
      int w = (int) floorf(glyph_advance(font, face, gid));
      if (cell < 0) { cell = w; }
      else if (w != cell) { cell = 0; break; }
    }
    if (cell > 0) { font->cell = cell; }
  }

  return font;

fail:
  free(font->data);
  free(font);
  return NULL;
}


void ren_free_font(RenFont *font) {
  glyph_batch_flush();
  for (int p = 0; p < GLYPH_PLANES; p++) {
    Block *table = font->planes[p];
    if (!table) { continue; }
    for (int b = 0; b < BLOCKS_PER_PLANE; b++) {
      for (int s = 0; s < SUBPIXEL_BITMAPS; s++) {
        GlyphSet *set = table[b].phase[s];
        if (!set) { continue; }
        if (set->texture) { SDL_DestroyTexture(set->texture); }
        if (set->image) { ren_free_image(set->image); }
        free(set);
      }
    }
    free(table);
  }
  /* Faces first, bytes second, and not the other way round: FreeType reads out
   * of the buffer it was given for as long as the face exists. */
  for (int i = 0; i < font->nfaces; i++) {
    if (font->faces[i].face) { FT_Done_Face(font->faces[i].face); }
  }
  /* Only our own file. The fallback faces point into fontfallback.c's cache,
   * which is shared by every RenFont and lives as long as the process -- the
   * alternative is re-reading a 23 MB pan-Unicode face once per font size the
   * UI happens to load. */
  free(font->data);
  free(font);
}


int ren_fallback_count(void) {
  int n = 0;
  fontfallback_chain(&n);
  return n;
}


const char* ren_fallback_path(int i, int *loaded) {
  int n = 0;
  FontFallback *chain = fontfallback_chain(&n);
  if (i < 0 || i >= n) { return NULL; }
  if (loaded) { *loaded = chain[i].data != NULL; }
  return chain[i].path;
}


void ren_set_font_tab_width(RenFont *font, int n) {
  font->tab_advance = n;
  Block *table = font->planes[0];
  if (!table) { return; }
  for (int s = 0; s < SUBPIXEL_BITMAPS; s++) {
    if (table[0].phase[s]) { table[0].phase[s]->glyphs['\t'].xadvance = (float) n; }
  }
}


int ren_get_font_tab_width(RenFont *font) {
  return (int) get_glyphset(font, '\t', 0)->glyphs['\t'].xadvance;
}


int ren_get_font_width(RenFont *font, const char *text) {
  /* Phase 0 for the measurement, because the three phases differ only in where
   * the ink lands, never in what the pen does. Measuring at phase 0 also keeps
   * a width query from building two atlases it will never draw from. */
  float x = 0;
  const char *p = text;
  unsigned codepoint;
  while (*p) {
    p = utf8_to_codepoint(p, &codepoint);
    GlyphSet *set = get_glyphset(font, codepoint, 0);
    x += set->glyphs[codepoint & 0xff].xadvance;
  }
  return (int) lroundf(x);
}


int ren_get_font_height(RenFont *font) {
  return font->height;
}


static SDL_FColor fcolor(RenColor c) {
  return (SDL_FColor) {
    (float) c.r / 255.0f,
    (float) c.g / 255.0f,
    (float) c.b / 255.0f,
    (float) c.a / 255.0f
  };
}


/* Anti-aliased thick line as a GPU quad.
 *
 * The editor core this grew from draws axis-aligned rectangles and glyphs,
 * which is everything a text editor needs and nothing a diagram does. A line at
 * an arbitrary angle is the one primitive that unlocks the rest: the sketch
 * engine -- and any other vector work -- reduces curves, ellipses, arrows and
 * hatch fills to short straight segments, so a line is not one feature among
 * many, it is the whole capability.
 *
 * Core width is `thickness`; a 0.5px fringe with vertex alpha 0 antialiases
 * the edges. Clip is the renderer clip rect. */
void ren_draw_line(float x0, float y0, float x1, float y1, float thickness,
                   RenColor color) {
  if (color.a == 0 || !renderer) { return; }
  glyph_batch_flush();
  bind_target();
  if (thickness < 1.0f) { thickness = 1.0f; }

  float dx = x1 - x0, dy = y1 - y0;
  float len = sqrtf(dx * dx + dy * dy);
  SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
  if (len < 0.0001f) {
    /* A zero-length line is a dot, which is a legitimate thing for a dotted
     * fill to ask for. */
    SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    SDL_RenderPoint(renderer, x0, y0);
    return;
  }

  float nx = -dy / len, ny = dx / len;
  float hw = thickness * 0.5f;
  float fr = 0.5f;
  SDL_FColor solid = fcolor(color);
  SDL_FColor fade = solid;
  fade.a = 0.0f;

  SDL_Vertex v[8];
  SDL_Vertex tmpl = { .position = { 0, 0 }, .color = solid, .tex_coord = { 0, 0 } };
  v[0] = tmpl; v[0].position.x = x0 + nx * hw; v[0].position.y = y0 + ny * hw;
  v[1] = tmpl; v[1].position.x = x0 - nx * hw; v[1].position.y = y0 - ny * hw;
  v[2] = tmpl; v[2].position.x = x1 - nx * hw; v[2].position.y = y1 - ny * hw;
  v[3] = tmpl; v[3].position.x = x1 + nx * hw; v[3].position.y = y1 + ny * hw;
  tmpl.color = fade;
  v[4] = tmpl; v[4].position.x = x0 + nx * (hw + fr); v[4].position.y = y0 + ny * (hw + fr);
  v[5] = tmpl; v[5].position.x = x0 - nx * (hw + fr); v[5].position.y = y0 - ny * (hw + fr);
  v[6] = tmpl; v[6].position.x = x1 - nx * (hw + fr); v[6].position.y = y1 - ny * (hw + fr);
  v[7] = tmpl; v[7].position.x = x1 + nx * (hw + fr); v[7].position.y = y1 + ny * (hw + fr);

  static const int idx[] = {
    0, 1, 2,  0, 2, 3,
    0, 3, 7,  0, 7, 4,
    1, 5, 6,  1, 6, 2,
    0, 4, 5,  0, 5, 1,
    3, 2, 6,  3, 6, 7
  };
  SDL_RenderGeometry(renderer, NULL, v, 8, idx, (int) (sizeof idx / sizeof idx[0]));
}


void ren_draw_rect(RenRect rect, RenColor color) {
  if (color.a == 0 || !renderer) { return; }
  glyph_batch_flush();
  bind_target();
  SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
  SDL_SetRenderDrawBlendMode(renderer,
                             color.a == 0xff ? SDL_BLENDMODE_NONE : SDL_BLENDMODE_BLEND);
  SDL_FRect r = {
    (float) rect.x, (float) rect.y,
    (float) rect.width, (float) rect.height
  };
  SDL_RenderFillRect(renderer, &r);
}


void ren_draw_image(RenImage *image, RenRect *sub, int x, int y, RenColor color) {
  if (color.a == 0 || !renderer || !image || !sub) { return; }
  if (sub->width <= 0 || sub->height <= 0) { return; }
  glyph_batch_flush();
  bind_target();
  SDL_Texture *tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                       SDL_TEXTUREACCESS_STATIC,
                                       image->width, image->height);
  if (!tex) { return; }
  SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
  SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_NEAREST);
  SDL_SetTextureColorMod(tex, color.r, color.g, color.b);
  SDL_SetTextureAlphaMod(tex, color.a);
  SDL_UpdateTexture(tex, NULL, image->pixels, image->width * (int)sizeof(RenColor));
  SDL_FRect src = {
    (float) sub->x, (float) sub->y,
    (float) sub->width, (float) sub->height
  };
  SDL_FRect dst = {
    (float) x, (float) y,
    (float) sub->width, (float) sub->height
  };
  SDL_RenderTexture(renderer, tex, &src, &dst);
  SDL_DestroyTexture(tex);
}


static void glyph_batch_push(SDL_Texture *tex, float x0, float y0, float x1, float y1,
                             float u0, float v0, float u1, float v1, SDL_FColor col) {
  if (!tex) { return; }
  if (glyph_batch_tex != tex || glyph_batch_n >= GLYPH_BATCH_MAX) {
    glyph_batch_flush();
    bind_target();
    glyph_batch_tex = tex;
  }
  SDL_Vertex *q = &glyph_batch[glyph_batch_n * 4];
  q[0].position.x = x0; q[0].position.y = y0; q[0].color = col; q[0].tex_coord.x = u0; q[0].tex_coord.y = v0;
  q[1].position.x = x1; q[1].position.y = y0; q[1].color = col; q[1].tex_coord.x = u1; q[1].tex_coord.y = v0;
  q[2].position.x = x1; q[2].position.y = y1; q[2].color = col; q[2].tex_coord.x = u1; q[2].tex_coord.y = v1;
  q[3].position.x = x0; q[3].position.y = y1; q[3].color = col; q[3].tex_coord.x = u0; q[3].tex_coord.y = v1;
  glyph_batch_n++;
}


int ren_draw_text(RenFont *font, const char *text, int x, int y, RenColor color) {
  /* The pen is a float even though the entry and exit points are integers.
   * That is the whole of subpixel positioning: a proportional advance of 7.4px
   * puts the next glyph at .4 of a pixel, and the phase index picks the
   * pre-rendered bitmap that was shifted by the nearest third. Rounding the
   * pen instead -- which is what this did while it was stb_truetype -- loses
   * that, and the loss compounds across a word. */
  float pen = (float) x;
  const char *p = text;
  unsigned codepoint;
  SDL_FColor col = fcolor(color);

  if (color.a != 0 && renderer) {
    bind_target();
  }

  while (*p) {
    p = utf8_to_codepoint(p, &codepoint);
    int origin = (int) floorf(pen);
    int phase = (int) ((pen - (float) origin) * SUBPIXEL_BITMAPS);
    if (phase < 0) { phase = 0; }
    if (phase >= SUBPIXEL_BITMAPS) { phase = SUBPIXEL_BITMAPS - 1; }

    GlyphSet *set = get_glyphset(font, codepoint, phase);
    Glyph *g = &set->glyphs[codepoint & 0xff];
    int gw = g->x1 - g->x0;
    int gh = g->y1 - g->y0;
    if (gw > 0 && gh > 0 && color.a != 0 && set->texture) {
      float tw = (float) set->tw, th = (float) set->th;
      if (tw > 0 && th > 0) {
        float gx = (float) origin + g->xoff;
        float gy = (float) y + g->yoff;
        glyph_batch_push(set->texture, gx, gy, gx + (float) gw, gy + (float) gh,
                         (float) g->x0 / tw, (float) g->y0 / th,
                         (float) g->x1 / tw, (float) g->y1 / th, col);
      }
    }
    pen += g->xadvance;
  }

  int end = (int) lroundf(pen);
  /* Synthesised decorations, drawn once for the whole run rather than per
   * glyph so a dashed-looking underline is impossible. */
  if (font->style & REN_STYLE_UNDERLINE) {
    ren_draw_rect((RenRect) { x, y + font->height - font->underline,
                              end - x, font->underline }, color);
  }
  if (font->style & REN_STYLE_STRIKETHROUGH) {
    ren_draw_rect((RenRect) { x, y + font->baseline - font->height / 6,
                              end - x, font->underline }, color);
  }
  return end;
}
