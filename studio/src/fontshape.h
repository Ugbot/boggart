#ifndef BOGGART_FONTSHAPE_H
#define BOGGART_FONTSHAPE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
/* One native cell retains a base and at most 64 suffix scalars. */
#define FONT_SHAPE_SCALARS 65
#define FONT_SHAPE_GLYPHS 256
#define FONT_SHAPE_BYTES (FONT_SHAPE_SCALARS * 4)
typedef struct FontShape FontShape;
typedef struct { uint32_t id; float x, y; } FontShapeGlyph;
typedef struct {
  unsigned count;
  float advance;
  FontShapeGlyph glyphs[FONT_SHAPE_GLYPHS];
} FontShapeRun;
/* Bytes are borrowed and immutable, and must outlive the shape object. This
 * OpenType backend never borrows a FreeType face. Main-thread buffer reuse. */
FontShape *fontshape_create(const void *bytes,size_t length,unsigned index,float size);
void fontshape_destroy(FontShape *shape);
bool fontshape_allocation_ok(const FontShape *shape);
/* Bounded complete result on success; output stays unchanged on failure. */
bool fontshape_run(FontShape *shape,const uint32_t *scalars,unsigned count,FontShapeRun *out);
#endif
