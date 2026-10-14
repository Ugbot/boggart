#ifndef BOGGART_FONTGLYPH_H
#define BOGGART_FONTGLYPH_H
#include "renderer.h"

/* Internal font/raster boundary. No FreeType faces, font bytes, fallback tables
 * or mutable cache entries escape. A glyph's texture is borrowed; enqueue its
 * quad before another lookup can migrate an atlas. Migration/free flush pending
 * geometry before changing UVs or destroying textures. Main-thread only. */
#define REN_GLYPH_PHASES 3
typedef struct {
  SDL_Texture *texture;
  int tw, th;
  unsigned short x0, y0, x1, y1;
  float xoff, yoff, xadvance;
} RenGlyph;
typedef struct { int height, baseline, underline; unsigned style; } RenFontMetrics;
typedef struct {
  bool shared_style_atlases;
  uint64_t shared_bytes, standalone_bytes;
} RenFontAtlasStats;

/* Borrow the device/flush hook. Install before loading GPU glyphs, release all
 * font caches before destroying the device. NULL device supports headless font
 * measurement/rasterization. Sharing changes affect future atlas loads. */
void ren_font_set_device(SDL_Renderer *device, bool sharing, void (*flush)(void));
bool ren_font_style_atlas_sharing(bool enabled);
RenFontAtlasStats ren_font_atlas_stats(void);
RenFontMetrics ren_font_metrics(const RenFont *font);
RenGlyph ren_font_glyph(RenFont *font, unsigned codepoint, int phase);struct FontShape;
struct RenCluster;
bool ren_font_face_shape(RenFont *font,unsigned index,struct FontShape **out);
bool ren_font_glyph_id(RenFont *font,unsigned face,uint32_t id,int phase,RenGlyph *out);
void ren_draw_glyph(RenGlyph glyph,float x,float y,float scale,RenColor color);
#endif
