#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <assert.h>
#include <math.h>
#include <string.h>
#include "renderer.h"
#include "fontglyph.h"
#include "utf8width.h"

static SDL_Window *window;
static SDL_Renderer *renderer;
static SDL_Texture *target;
static int target_w, target_h;
static struct { int left, top, right, bottom; } clip;
/* An EMPTY clip means "draw nothing", and must never be confused with "no clip".
 * rencache replays the whole command list once per dirty rect, intersecting each
 * SET_CLIP with that rect, so a view whose clip does not touch the rect legally
 * yields a zero-sized clip. Passing NULL to SDL for that case disables clipping
 * instead of suppressing the draw, and the view then paints over the entire
 * target -- including over overlays drawn later in the frame, whose own cells
 * are not dirty and so are never repaired. That was the menu-dropdown flicker. */
static bool clip_empty;

#define GLYPH_BATCH_MAX 256
static SDL_Vertex glyph_batch[GLYPH_BATCH_MAX * 4];
static SDL_Texture *glyph_batch_tex;
static int glyph_batch_n;
static RenGlyphStats glyph_stats;

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
  if (r.w < 0) { r.w = 0; }
  if (r.h < 0) { r.h = 0; }
  SDL_SetRenderClipRect(renderer, &r);
}


static void glyph_batch_flush(void) {
  if (glyph_batch_n <= 0 || !renderer || clip_empty) {
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
  if (r.w < 0) { r.w = 0; }
  if (r.h < 0) { r.h = 0; }
  SDL_SetRenderClipRect(renderer, &r);
  SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
  SDL_RenderGeometry(renderer, glyph_batch_tex, glyph_batch, glyph_batch_n * 4,
                     indices, glyph_batch_n * 6);
  glyph_stats.batches++;
  glyph_batch_n = 0;
  glyph_batch_tex = NULL;
}

void ren_reset_glyph_stats(void){glyph_stats=(RenGlyphStats){.shared_style_atlases=ren_font_atlas_stats().shared_style_atlases};}
RenGlyphStats ren_glyph_stats(void){
  RenGlyphStats stats=glyph_stats;
  RenFontAtlasStats atlases=ren_font_atlas_stats();
  stats.shared_atlas_bytes=atlases.shared_bytes;
  stats.standalone_atlas_bytes=atlases.standalone_bytes;
  stats.backend=renderer ? SDL_GetRendererName(renderer) : NULL;
  return stats;
}
bool ren_test_style_atlas_sharing(bool enabled){return ren_font_style_atlas_sharing(enabled);}


static void* check_alloc(void *ptr) {
  if (!ptr) {
    fprintf(stderr, "Fatal error: memory allocation failed\n");
    exit(EXIT_FAILURE);
  }
  return ptr;
}


/* The compatibility header delegates to the shared strict Unicode decoder.
 * Studio and terminal layout agree on scalar boundaries and invalid input. */
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
  /* Software geometry emulates per-vertex tint with texture color modulation.
   * Sharing styles makes alternating tints repeatedly invalidate its blit map. */
  const char *backend=SDL_GetRendererName(renderer);
  ren_font_set_device(renderer,backend && strcmp(backend,"software")!=0,glyph_batch_flush);
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
  glyph_batch_flush();   /* flush under the OLD clip, before it changes */
  clip.left   = rect.x;
  clip.top    = rect.y;
  clip.right  = rect.x + rect.width;
  clip.bottom = rect.y + rect.height;
  clip_empty  = (clip.right <= clip.left) || (clip.bottom <= clip.top);
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
  if (color.a == 0 || !renderer || clip_empty) { return; }
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
  if (color.a == 0 || !renderer || clip_empty) { return; }
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


/* Blit the sub-rect of an RGBA image, scaled into the destination rect. src and
 * dst are independent so the caller can fit an image to a column width. The
 * texture is created and destroyed per call: images are occasional (Markdown,
 * later PDF pages), so this stays simple rather than caching a texture on the
 * RenImage and having to invalidate it. Linear scaling reads better than nearest
 * for a down-scaled photo/diagram. */
void ren_draw_image(RenImage *image, RenRect *sub, RenRect *dst, RenColor color) {
  if (color.a == 0 || !renderer || !image || !sub || !dst || clip_empty) { return; }
  if (sub->width <= 0 || sub->height <= 0 || dst->width <= 0 || dst->height <= 0) { return; }
  glyph_batch_flush();
  bind_target();
  SDL_Texture *tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                       SDL_TEXTUREACCESS_STATIC,
                                       image->width, image->height);
  if (!tex) { return; }
  SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
  SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_LINEAR);
  SDL_SetTextureColorMod(tex, color.r, color.g, color.b);
  SDL_SetTextureAlphaMod(tex, color.a);
  SDL_UpdateTexture(tex, NULL, image->pixels, image->width * (int)sizeof(RenColor));
  SDL_FRect src = {
    (float) sub->x, (float) sub->y,
    (float) sub->width, (float) sub->height
  };
  SDL_FRect fdst = {
    (float) dst->x, (float) dst->y,
    (float) dst->width, (float) dst->height
  };
  SDL_RenderTexture(renderer, tex, &src, &fdst);
  SDL_DestroyTexture(tex);
}


static void glyph_batch_push(SDL_Texture *tex, float x0, float y0, float x1, float y1,
                             float u0, float v0, float u1, float v1, SDL_FColor col) {
  if (!tex) { return; }
  if (glyph_batch_tex != tex || glyph_batch_n >= GLYPH_BATCH_MAX) {
    if(glyph_batch_n && glyph_batch_tex!=tex)glyph_stats.texture_switches++;
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
  glyph_stats.quads++;
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

  /* Clipped to nothing: skip the raster/batch entirely, but still answer with
   * the advance the caller would have got, since the return value is the pen. */
  if (clip_empty) { return x + ren_get_font_width(font, text); }

  if (color.a != 0 && renderer) {
    bind_target();
  }

  while (*p) {
    p = utf8_to_codepoint(p, &codepoint);
    int origin = (int) floorf(pen);
    int phase = (int) ((pen - (float) origin) * REN_GLYPH_PHASES);
    if (phase < 0) { phase = 0; }
    if (phase >= REN_GLYPH_PHASES) { phase = REN_GLYPH_PHASES - 1; }

    RenGlyph glyph = ren_font_glyph(font, codepoint, phase);
    const RenGlyph *g = &glyph;
    int gw = g->x1 - g->x0;
    int gh = g->y1 - g->y0;
    if (gw > 0 && gh > 0 && color.a != 0 && g->texture) {
      float tw = (float) g->tw, th = (float) g->th;
      if (tw > 0 && th > 0) {
        float gx = (float) origin + g->xoff;
        float gy = (float) y + g->yoff;
        glyph_batch_push(g->texture, gx, gy, gx + (float) gw, gy + (float) gh,
                         (float) g->x0 / tw, (float) g->y0 / th,
                         (float) g->x1 / tw, (float) g->y1 / th,
                         g->colored ? (SDL_FColor){1,1,1,col.a} : col);
      }
    }
    pen += g->xadvance;
  }

  int end = (int) lroundf(pen);
  RenFontMetrics metrics = ren_font_metrics(font);
  /* Synthesised decorations, drawn once for the whole run rather than per
   * glyph so a dashed-looking underline is impossible. */
  if (metrics.style & REN_STYLE_UNDERLINE) {
    ren_draw_rect((RenRect) { x, y + metrics.height - metrics.underline,
                              end - x, metrics.underline }, color);
  }
  if (metrics.style & REN_STYLE_STRIKETHROUGH) {
    ren_draw_rect((RenRect) { x, y + metrics.baseline - metrics.height / 6,
                              end - x, metrics.underline }, color);
  }
  return end;
}
void ren_draw_glyph_intensity(RenGlyph glyph,float x,float y,float scale,RenColor color,uint8_t intensity) {
  if(clip_empty || !renderer || !color.a || !glyph.texture || !glyph.tw || !glyph.th)return;
  bind_target();
  if(glyph.colored)color.r=color.g=color.b=intensity;
  float x0=x+glyph.xoff*scale,y0=y+glyph.yoff;
  float w=(float)(glyph.x1-glyph.x0)*scale,h=(float)(glyph.y1-glyph.y0);
  if(w>0 && h>0)glyph_batch_push(glyph.texture,x0,y0,x0+w,y0+h,
    (float)glyph.x0/glyph.tw,(float)glyph.y0/glyph.th,(float)glyph.x1/glyph.tw,(float)glyph.y1/glyph.th,fcolor(color));
}
void ren_draw_glyph(RenGlyph glyph,float x,float y,float scale,RenColor color) {
  ren_draw_glyph_intensity(glyph,x,y,scale,color,255);
}
