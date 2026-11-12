#include "fontshape.h"
#include <hb.h>
#include <hb-ot.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
struct FontShape { hb_font_t *font; hb_buffer_t *buffer; };
FontShape *fontshape_create(const void *bytes,size_t length,unsigned index,float size) {
  if(!bytes || !length || length>UINT_MAX || !isfinite(size) || size<=0 || size>4096)return NULL;
  FontShape *shape=calloc(1,sizeof *shape);if(!shape)return NULL;
  hb_blob_t *blob=hb_blob_create(bytes,(unsigned)length,HB_MEMORY_MODE_READONLY,NULL,NULL);
  if(hb_blob_get_length(blob)!=length){hb_blob_destroy(blob);free(shape);return NULL;}
  hb_face_t *face=hb_face_create(blob,index);hb_blob_destroy(blob);
  if(face==hb_face_get_empty()){free(shape);return NULL;}
  if(!hb_face_get_glyph_count(face)){hb_face_destroy(face);return shape;}
  shape->font=hb_font_create(face);hb_face_destroy(face);
  if(shape->font==hb_font_get_empty()){free(shape);return NULL;}
  hb_ot_font_set_funcs(shape->font);
  int scale=(int)lroundf(size*64);hb_font_set_scale(shape->font,scale,scale);
  shape->buffer=hb_buffer_create();
  if(!hb_buffer_pre_allocate(shape->buffer,FONT_SHAPE_GLYPHS)){fontshape_destroy(shape);return NULL;}
  return shape;
}
void fontshape_destroy(FontShape *shape) {
  if(!shape)return;
  if(shape->buffer)hb_buffer_destroy(shape->buffer);
  if(shape->font)hb_font_destroy(shape->font);
  free(shape);
}
bool fontshape_allocation_ok(const FontShape *shape) {
  return shape && (!shape->buffer || hb_buffer_allocation_successful(shape->buffer));
}
bool fontshape_run(FontShape *shape,const uint32_t *scalars,unsigned count,FontShapeRun *out) {
  if(!shape || !shape->font || !shape->buffer || !scalars || !out || !count || count>FONT_SHAPE_SCALARS)return false;
  hb_buffer_t *buffer=shape->buffer;hb_buffer_clear_contents(buffer);
  /* A retained scalar/soft-hyphen head is literal terminal content, rather
   * than discretionary line-breaking input. Reset flags on every reused run. */
  hb_buffer_set_flags(buffer,count==1 || scalars[0]==0xad
    ? HB_BUFFER_FLAG_PRESERVE_DEFAULT_IGNORABLES : HB_BUFFER_FLAG_DEFAULT);
  hb_buffer_add_codepoints(buffer,scalars,(int)count,0,(int)count);
  hb_buffer_set_language(buffer,hb_language_from_string("und",3));
  hb_buffer_guess_segment_properties(buffer);
  static const char *const shapers[]={"ot",NULL};
  if(!hb_shape_full(shape->font,buffer,NULL,0,shapers) || !hb_buffer_allocation_successful(buffer))return false;
  unsigned n=hb_buffer_get_length(buffer);if(n>FONT_SHAPE_GLYPHS)return false;
  const hb_glyph_info_t *info=hb_buffer_get_glyph_infos(buffer,NULL);
  const hb_glyph_position_t *pos=hb_buffer_get_glyph_positions(buffer,NULL);
  FontShapeRun result={.count=n};int64_t x=0,y=0;
  for(unsigned i=0;i<n;i++) {
    if(!info[i].codepoint)return false;
    result.glyphs[i]=(FontShapeGlyph){info[i].codepoint,(float)(x+pos[i].x_offset)/64,-(float)(y+pos[i].y_offset)/64};
    if(fabsf(result.glyphs[i].x)>65536 || fabsf(result.glyphs[i].y)>65536)return false;
    x+=pos[i].x_advance;y+=pos[i].y_advance;
  }
  result.advance=(float)x/64;if(fabsf(result.advance)>65536)return false;*out=result;return true;
}
