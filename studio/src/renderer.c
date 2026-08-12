#include <stdio.h>
#include <stdbool.h>
#include <assert.h>
#include <math.h>
#include <string.h>
#include "lib/stb/stb_truetype.h"
#include "renderer.h"
#include "fontfallback.h"
#include "utf8width.h"

/* Glyph caching, and why it is a two-level table.
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

/* Primary plus every fallback face, where a .ttc contributes one face per
 * subfont. Bounded because the chain is consulted linearly and a face past
 * the twentieth is not adding coverage. */
#define MAX_FACES 32

struct RenImage {
  RenColor *pixels;
  int width, height;
};

typedef struct {
  RenImage *image;
  stbtt_bakedchar glyphs[256];
} GlyphSet;

/* One font file (or one subfont of a collection) at this RenFont's size.
 * `info` points into memory owned elsewhere: font->data for the primary,
 * fontfallback.c's process-wide cache for the rest. */
typedef struct {
  stbtt_fontinfo info;
  float scale;
} Face;

struct RenFont {
  void *data;
  stbtt_fontinfo stbfont;
  GlyphSet **planes[GLYPH_PLANES];
  Face faces[MAX_FACES];
  int nfaces;        /* faces materialised so far; faces[0] is ours */
  int next_file;     /* next entry of the fallback chain left to expand */
  uint32_t covered;  /* union of the accepted faces' coverage signatures */
  float size;
  int height;
  /* Monospace fonts get their advances snapped to the cell grid -- see
   * bake_glyphset. Zero when the font is proportional. */
  int cell;
};


static SDL_Window *window;
static struct { int left, top, right, bottom; } clip;


static void* check_alloc(void *ptr) {
  if (!ptr) {
    fprintf(stderr, "Fatal error: memory allocation failed\n");
    exit(EXIT_FAILURE);
  }
  return ptr;
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
  SDL_Surface *surf = SDL_GetWindowSurface(window);
  ren_set_clip_rect( (RenRect) { 0, 0, surf->w, surf->h } );
}


void ren_update_rects(RenRect *rects, int count) {
  SDL_UpdateWindowSurfaceRects(window, (SDL_Rect*) rects, count);
  static bool initial_frame = true;
  if (initial_frame) {
    SDL_ShowWindow(window);
    initial_frame = false;
  }
}


void ren_set_clip_rect(RenRect rect) {
  clip.left   = rect.x;
  clip.top    = rect.y;
  clip.right  = rect.x + rect.width;
  clip.bottom = rect.y + rect.height;
}


void ren_get_size(int *x, int *y) {
  SDL_Surface *surf = SDL_GetWindowSurface(window);
  *x = surf->w;
  *y = surf->h;
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

static uint32_t face_signature(const stbtt_fontinfo *info) {
  uint32_t sig = 0;
  for (int i = 0; i < FACE_PROBE_N; i++) {
    if (stbtt_FindGlyphIndex(info, FACE_PROBE[i])) { sig |= 1u << i; }
  }
  return sig;
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

    int nsub = stbtt_GetNumberOfFonts(data);
    if (nsub < 1) { nsub = 1; }
    for (int s = 0; s < nsub && font->nfaces < MAX_FACES; s++) {
      int off = stbtt_GetFontOffsetForIndex(data, s);
      if (off < 0) { continue; }
      Face *f = &font->faces[font->nfaces];
      if (!stbtt_InitFont(&f->info, data, off)) { continue; }
      uint32_t sig = face_signature(&f->info);
      if ((sig & ~font->covered) == 0) { continue; }
      font->covered |= sig;
      f->scale = stbtt_ScaleForMappingEmToPixels(&f->info, font->size);
      font->nfaces++;
      entry->usable = 1;
    }
  }
  return &font->faces[i];
}


/* Which face draws this codepoint, and as which glyph.
 *
 * stbtt_FindGlyphIndex returning 0 means "this font has no glyph for that
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
    int g = stbtt_FindGlyphIndex(&f->info, (int) cp);
    if (g) { *out = f; return g; }
  }
  *out = &font->faces[0];
  return 0;
}


/* Bake one 256-codepoint block into `set`, returning 0 if the atlas was too
 * small and the caller should retry with a bigger one.
 *
 * This replaces stbtt_BakeFontBitmap, which cannot do the one thing this
 * needs: it takes a single font and bakes a contiguous codepoint range from
 * it, and a fallback chain has to choose a font per codepoint. The packing is
 * stb's -- a shelf allocator, a row at a time -- because it is the right
 * amount of packing for a 256-glyph atlas and there was no reason to invent a
 * different one.
 *
 * Baseline alignment across faces is the subtle part. Each face's outline is
 * scaled with its own em-to-pixel scale, so a 13.5px Hiragino ideograph and a
 * 13.5px Latin letter agree on em size rather than on cap height, and both
 * yoffs are then shifted by *our* font's ascent -- the primary's, once, for
 * every glyph. Sharing one baseline is what stops mixed text from stepping up
 * and down as it changes script. */
static int bake_glyphset(RenFont *font, GlyphSet *set, int block,
                         int pw, int ph) {
  uint8_t *pixels = (uint8_t*) set->image->pixels;
  memset(pixels, 0, (size_t) pw * (size_t) ph);
  memset(set->glyphs, 0, sizeof set->glyphs);

  int ascent, descent, linegap;
  stbtt_GetFontVMetrics(&font->stbfont, &ascent, &descent, &linegap);
  float own_scale = stbtt_ScaleForMappingEmToPixels(&font->stbfont, font->size);
  int baseline = (int) (ascent * own_scale + 0.5f);

  int x = 1, y = 1, bottom_y = 1;

  for (int i = 0; i < 256; i++) {
    unsigned cp = (unsigned) block * 256u + (unsigned) i;
    Face *face = NULL;
    int glyph = find_glyph(font, cp, &face);

    int adv, lsb;
    stbtt_GetGlyphHMetrics(&face->info, glyph, &adv, &lsb);

    /* Nothing on this machine has this character. Draw the box.
     *
     * The alternative was in front of me on screen: emoji laid out two cells
     * wide and drawn as nothing at all, because monospace.ttf's .notdef is an
     * empty outline. Blank is the one thing a missing glyph must not be -- it
     * reads as "the text is not there" rather than "this font cannot draw the
     * text", and those call for completely different reactions from whoever is
     * looking. Synthesised rather than borrowed from a fallback's U+FFFD so it
     * is always available, including on a machine with no fallbacks at all.
     *
     * A codepoint of zero width is skipped: an unassigned combining slot is
     * genuinely invisible and boxing it would be noise. */
    int missing = (glyph == 0 && bog_cp_width(cp) > 0);

    int x0, y0, x1, y1;
    int gw, gh;
    if (missing) {
      int cells = bog_cp_width(cp);
      gw = (font->cell > 0 ? font->cell * cells : (int) (font->size * 0.55f)) - 2;
      gh = (int) (font->size * 0.72f);
      if (gw < 3) { gw = 3; }
      if (gh < 3) { gh = 3; }
      x0 = 1;
      y0 = -gh;   /* sits on the baseline, like a capital letter */
    } else {
      stbtt_GetGlyphBitmapBox(&face->info, glyph, face->scale, face->scale,
                              &x0, &y0, &x1, &y1);
      gw = x1 - x0;
      gh = y1 - y0;
      if (gw < 0) { gw = 0; }
      if (gh < 0) { gh = 0; }
    }

    if (x + gw + 1 >= pw) { y = bottom_y; x = 1; }
    if (y + gh + 1 >= ph) { return 0; }

    if (missing) {
      uint8_t *dst = pixels + x + y * pw;
      for (int c = 0; c < gw; c++) { dst[c] = 0xa0; dst[c + (gh - 1) * pw] = 0xa0; }
      for (int r = 0; r < gh; r++) { dst[r * pw] = 0xa0; dst[gw - 1 + r * pw] = 0xa0; }
    } else if (gw > 0 && gh > 0) {
      stbtt_MakeGlyphBitmap(&face->info, pixels + x + y * pw, gw, gh, pw,
                            face->scale, face->scale, glyph);
    }
    if (missing && font->cell <= 0) {
      /* A proportional font's .notdef often advances zero, which would stack
       * every unknown character on the same pixel. */
      int want = (int) ((gw + 2) / face->scale);
      if (adv < want) { adv = want; }
    }

    stbtt_bakedchar *bc = &set->glyphs[i];
    bc->x0 = (unsigned short) x;
    bc->y0 = (unsigned short) y;
    bc->x1 = (unsigned short) (x + gw);
    bc->y1 = (unsigned short) (y + gh);
    bc->xoff = (float) x0;
    bc->yoff = (float) (y0 + baseline);
    bc->xadvance = floorf(adv * face->scale);

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
     * forcing one would make the menu bar look like a ransom note. */
    if (font->cell > 0) {
      int cells = bog_cp_width(cp);
      if (cells > 0) {
        float want = (float) (font->cell * cells);
        bc->xoff += (want - bc->xadvance) / 2.0f;
        bc->xadvance = want;
      } else {
        /* A combining mark has no advance of its own and stacks on what came
         * before it. Only true for the simple cases -- there is no mark
         * positioning here, so the mark lands on the cell, not on the letter's
         * actual centre. */
        bc->xadvance = 0.0f;
      }
    }

    x = x + gw + 1;
    if (y + gh + 1 > bottom_y) { bottom_y = y + gh + 1; }
  }
  return 1;
}


static GlyphSet* load_glyphset(RenFont *font, int block) {
  GlyphSet *set = check_alloc(calloc(1, sizeof(GlyphSet)));

  int width = 128;
  int height = 128;
  for (;;) {
    set->image = ren_new_image(width, height);
    if (bake_glyphset(font, set, block, width, height)) { break; }
    /* Too small for this block's glyphs. CJK blocks are 256 ideographs at
     * full em, so they land here two or three times before they fit. */
    ren_free_image(set->image);
    width *= 2;
    height *= 2;
  }

  /* convert 8bit data to 32bit */
  for (int i = width * height - 1; i >= 0; i--) {
    uint8_t n = *((uint8_t*) set->image->pixels + i);
    set->image->pixels[i] = (RenColor) { .r = 255, .g = 255, .b = 255, .a = n };
  }

  return set;
}


static GlyphSet* get_glyphset(RenFont *font, int codepoint) {
  /* Unsigned throughout, so a decode that went wrong cannot index backwards --
   * font->planes[-1] is a pointer read out of the struct above this array, and
   * that is what a signed shift of a sign-extended continuation byte used to
   * produce. Anything past U+10FFFF is not a codepoint and is folded onto the
   * replacement character's block rather than given one of its own. */
  unsigned cp = (unsigned) codepoint;
  if (cp > 0x10FFFFu) { cp = 0xFFFDu; }

  unsigned plane = cp >> 16;
  unsigned block = (cp >> 8) & 0xffu;
  if (!font->planes[plane]) {
    font->planes[plane] = check_alloc(calloc(BLOCKS_PER_PLANE, sizeof(GlyphSet*)));
  }
  GlyphSet **table = font->planes[plane];
  if (!table[block]) {
    table[block] = load_glyphset(font, (int) (cp >> 8));
  }
  return table[block];
}


/* The shared tail of ren_load_font and ren_load_font_mem: everything from
 * "we have the bytes" onwards. `font->data` is owned by the RenFont either
 * way -- the memory entry point copies, so a baked-in asset in read-only
 * .rodata and a file read off disk are freed the same way. */
static RenFont* font_from_data(RenFont *font, float size);


RenFont* ren_load_font_mem(const void *data, size_t len, float size) {
  if (!data || len == 0) { return NULL; }
  RenFont *font = check_alloc(calloc(1, sizeof(RenFont)));
  font->size = size;
  font->data = check_alloc(malloc(len));
  memcpy(font->data, data, len);
  return font_from_data(font, size);
}


RenFont* ren_load_font(const char *filename, float size) {
  RenFont *font = NULL;
  FILE *fp = NULL;

  /* init font */
  font = check_alloc(calloc(1, sizeof(RenFont)));
  font->size = size;

  /* load font into buffer */
  fp = fopen(filename, "rb");
  if (!fp) { free(font); return NULL; }
  /* get size */
  fseek(fp, 0, SEEK_END); int buf_size = ftell(fp); fseek(fp, 0, SEEK_SET);
  /* load */
  font->data = check_alloc(malloc(buf_size));
  int _ = fread(font->data, 1, buf_size, fp); (void) _;
  fclose(fp);
  fp = NULL;

  return font_from_data(font, size);
}


static RenFont* font_from_data(RenFont *font, float size) {
  /* init stbfont
   *
   * Offset 0 is a plain single-face file. A TrueType *collection* (.ttc, and
   * some .otf) packs several faces behind a header, and stbtt_InitFont at
   * offset 0 simply fails on one -- which is why choosing a font from
   * /System/Library/Fonts used to be refused: macOS ships most of its faces
   * that way, so the obvious thing to pick was the one thing that could not
   * load.
   *
   * stbtt_GetFontOffsetForIndex is what the fallback chain in fontfallback.c
   * already uses to walk a collection; the primary loader can use it too. Face
   * 0 is taken because the alternative -- a syntax for naming a face inside a
   * file -- is a setting nobody wants to learn, and face 0 is the regular
   * weight in every collection I have looked at. */
  int ok = stbtt_InitFont(&font->stbfont, font->data, 0);
  if (!ok) {
    int off = stbtt_GetFontOffsetForIndex(font->data, 0);
    if (off >= 0) { ok = stbtt_InitFont(&font->stbfont, font->data, off); }
  }
  if (!ok) { goto fail; }

  /* The primary face is the head of its own fallback chain. Everything after
   * it is discovered lazily by face_at(). */
  font->faces[0].info = font->stbfont;
  font->faces[0].scale = stbtt_ScaleForMappingEmToPixels(&font->stbfont, size);
  font->nfaces = 1;
  font->covered = face_signature(&font->stbfont);

  /* get height and scale */
  int ascent, descent, linegap;
  stbtt_GetFontVMetrics(&font->stbfont, &ascent, &descent, &linegap);
  float scale = stbtt_ScaleForMappingEmToPixels(&font->stbfont, size);
  font->height = (ascent - descent + linegap) * scale + 0.5;

  /* Is this a monospace font? Four characters that differ as much as Latin
   * ones can -- widest, narrowest, a digit, punctuation -- agreeing on their
   * advance is a reliable answer, and a cheap one. It decides whether glyphs
   * get snapped to a cell grid; see bake_glyphset.
   *
   * All four have to be present. A font with none of them -- icons.ttf is
   * exactly that, fourteen pictographs and no Latin -- answers every probe
   * with .notdef, so the four advances agree trivially and an icon font would
   * be declared monospace and have every icon crushed to one cell. */
  {
    static const char probe[] = { 'W', 'i', '0', '.' };
    int cell = -1;
    font->cell = 0;
    for (size_t i = 0; i < sizeof probe; i++) {
      int glyph = stbtt_FindGlyphIndex(&font->stbfont, probe[i]);
      if (!glyph) { cell = 0; break; }
      int adv, lsb;
      stbtt_GetGlyphHMetrics(&font->stbfont, glyph, &adv, &lsb);
      int w = (int) floorf(adv * font->faces[0].scale);
      if (cell < 0) { cell = w; }
      else if (w != cell) { cell = 0; break; }
    }
    if (cell > 0) { font->cell = cell; }
  }

  /* make tab and newline glyphs invisible */
  stbtt_bakedchar *g = get_glyphset(font, '\n')->glyphs;
  g['\t'].x1 = g['\t'].x0;
  g['\n'].x1 = g['\n'].x0;

  return font;

fail:
  free(font->data);
  free(font);
  return NULL;
}


void ren_free_font(RenFont *font) {
  for (int p = 0; p < GLYPH_PLANES; p++) {
    GlyphSet **table = font->planes[p];
    if (!table) { continue; }
    for (int b = 0; b < BLOCKS_PER_PLANE; b++) {
      if (table[b]) {
        ren_free_image(table[b]->image);
        free(table[b]);
      }
    }
    free(table);
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
  GlyphSet *set = get_glyphset(font, '\t');
  set->glyphs['\t'].xadvance = n;
}


int ren_get_font_tab_width(RenFont *font) {
  GlyphSet *set = get_glyphset(font, '\t');
  return set->glyphs['\t'].xadvance;
}


int ren_get_font_width(RenFont *font, const char *text) {
  int x = 0;
  const char *p = text;
  unsigned codepoint;
  while (*p) {
    p = utf8_to_codepoint(p, &codepoint);
    GlyphSet *set = get_glyphset(font, codepoint);
    stbtt_bakedchar *g = &set->glyphs[codepoint & 0xff];
    x += g->xadvance;
  }
  return x;
}


int ren_get_font_height(RenFont *font) {
  return font->height;
}


static inline RenColor blend_pixel(RenColor dst, RenColor src) {
  int ia = 0xff - src.a;
  dst.r = ((src.r * src.a) + (dst.r * ia)) >> 8;
  dst.g = ((src.g * src.a) + (dst.g * ia)) >> 8;
  dst.b = ((src.b * src.a) + (dst.b * ia)) >> 8;
  return dst;
}


static inline RenColor blend_pixel2(RenColor dst, RenColor src, RenColor color) {
  src.a = (src.a * color.a) >> 8;
  int ia = 0xff - src.a;
  dst.r = ((src.r * color.r * src.a) >> 16) + ((dst.r * ia) >> 8);
  dst.g = ((src.g * color.g * src.a) >> 16) + ((dst.g * ia) >> 8);
  dst.b = ((src.b * color.b * src.a) >> 16) + ((dst.b * ia) >> 8);
  return dst;
}


#define rect_draw_loop(expr)        \
  for (int j = y1; j < y2; j++) {   \
    for (int i = x1; i < x2; i++) { \
      *d = expr;                    \
      d++;                          \
    }                               \
    d += dr;                        \
  }

/* Anti-aliased line, clipped to the current clip rect.
 *
 * The editor core this grew from draws axis-aligned rectangles and glyphs,
 * which is everything a text editor needs and nothing a diagram does. A line at
 * an arbitrary angle is the one primitive that unlocks the rest: the sketch
 * engine -- and any other vector work -- reduces curves, ellipses, arrows and
 * hatch fills to short straight segments, so a line is not one feature among
 * many, it is the whole capability.
 *
 * Sampled and bilinearly blended rather than Bresenham. A hard-edged diagonal
 * looks like a mistake next to anti-aliased glyphs, and the sketchy strokes
 * this exists to draw are mostly shallow diagonals where aliasing is worst.
 * The cost is one pass along the longer axis, which is the same order as
 * Bresenham with a constant on it. */
static inline void blend_px(SDL_Surface *surf, int x, int y, RenColor color, float a) {
  if (x < clip.left || x >= clip.right || y < clip.top || y >= clip.bottom) { return; }
  if (a <= 0.0f) { return; }
  if (a > 1.0f) { a = 1.0f; }
  RenColor c = color;
  c.a = (uint8_t) ((float) color.a * a);
  if (c.a == 0) { return; }
  RenColor *d = (RenColor*) surf->pixels + x + y * surf->w;
  *d = blend_pixel(*d, c);
}


static void aa_line(SDL_Surface *surf, float x0, float y0, float x1, float y1,
                    RenColor color) {
  float dx = x1 - x0, dy = y1 - y0;
  float adx = dx < 0 ? -dx : dx, ady = dy < 0 ? -dy : dy;
  float len = adx > ady ? adx : ady;
  int n = (int) len;
  if (n < 1) { n = 1; }
  for (int i = 0; i <= n; i++) {
    float t = (float) i / (float) n;
    float x = x0 + dx * t, y = y0 + dy * t;
    int ix = (int) floorf(x), iy = (int) floorf(y);
    float fx = x - (float) ix, fy = y - (float) iy;
    blend_px(surf, ix,     iy,     color, (1.0f - fx) * (1.0f - fy));
    blend_px(surf, ix + 1, iy,     color, fx * (1.0f - fy));
    blend_px(surf, ix,     iy + 1, color, (1.0f - fx) * fy);
    blend_px(surf, ix + 1, iy + 1, color, fx * fy);
  }
}


void ren_draw_line(float x0, float y0, float x1, float y1, float thickness,
                   RenColor color) {
  if (color.a == 0) { return; }
  SDL_Surface *surf = SDL_GetWindowSurface(window);
  if (!surf) { return; }
  if (thickness < 1.0f) { thickness = 1.0f; }

  float dx = x1 - x0, dy = y1 - y0;
  float len = sqrtf(dx * dx + dy * dy);
  if (len < 0.0001f) {
    /* A zero-length line is a dot, which is a legitimate thing for a dotted
     * fill to ask for. */
    blend_px(surf, (int) x0, (int) y0, color, 1.0f);
    return;
  }
  /* Thickness as parallel offsets half a pixel apart: enough passes that they
   * overlap, so a thick stroke has no gaps down its middle. */
  float px = -dy / len, py = dx / len;
  int passes = (int) (thickness * 2.0f);
  if (passes < 1) { passes = 1; }
  for (int i = 0; i < passes; i++) {
    float off = ((float) i / (float) (passes > 1 ? passes - 1 : 1) - 0.5f) * thickness;
    if (passes == 1) { off = 0.0f; }
    aa_line(surf, x0 + px * off, y0 + py * off, x1 + px * off, y1 + py * off, color);
  }
}


void ren_draw_rect(RenRect rect, RenColor color) {
  if (color.a == 0) { return; }

  int x1 = rect.x < clip.left ? clip.left : rect.x;
  int y1 = rect.y < clip.top  ? clip.top  : rect.y;
  int x2 = rect.x + rect.width;
  int y2 = rect.y + rect.height;
  x2 = x2 > clip.right  ? clip.right  : x2;
  y2 = y2 > clip.bottom ? clip.bottom : y2;

  SDL_Surface *surf = SDL_GetWindowSurface(window);
  RenColor *d = (RenColor*) surf->pixels;
  d += x1 + y1 * surf->w;
  int dr = surf->w - (x2 - x1);

  if (color.a == 0xff) {
    rect_draw_loop(color);
  } else {
    rect_draw_loop(blend_pixel(*d, color));
  }
}


void ren_draw_image(RenImage *image, RenRect *sub, int x, int y, RenColor color) {
  if (color.a == 0) { return; }

  /* clip */
  int n;
  if ((n = clip.left - x) > 0) { sub->width  -= n; sub->x += n; x += n; }
  if ((n = clip.top  - y) > 0) { sub->height -= n; sub->y += n; y += n; }
  if ((n = x + sub->width  - clip.right ) > 0) { sub->width  -= n; }
  if ((n = y + sub->height - clip.bottom) > 0) { sub->height -= n; }

  if (sub->width <= 0 || sub->height <= 0) {
    return;
  }

  /* draw */
  SDL_Surface *surf = SDL_GetWindowSurface(window);
  RenColor *s = image->pixels;
  RenColor *d = (RenColor*) surf->pixels;
  s += sub->x + sub->y * image->width;
  d += x + y * surf->w;
  int sr = image->width - sub->width;
  int dr = surf->w - sub->width;

  for (int j = 0; j < sub->height; j++) {
    for (int i = 0; i < sub->width; i++) {
      *d = blend_pixel2(*d, *s, color);
      d++;
      s++;
    }
    d += dr;
    s += sr;
  }
}


int ren_draw_text(RenFont *font, const char *text, int x, int y, RenColor color) {
  RenRect rect;
  const char *p = text;
  unsigned codepoint;
  while (*p) {
    p = utf8_to_codepoint(p, &codepoint);
    GlyphSet *set = get_glyphset(font, codepoint);
    stbtt_bakedchar *g = &set->glyphs[codepoint & 0xff];
    rect.x = g->x0;
    rect.y = g->y0;
    rect.width = g->x1 - g->x0;
    rect.height = g->y1 - g->y0;
    ren_draw_image(set->image, &rect, x + g->xoff, y + g->yoff, color);
    x += g->xadvance;
  }
  return x;
}
