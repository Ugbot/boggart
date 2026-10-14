#include "fontcluster.h"
#include "utf8width.h"
#include "bunicode.h"
#include <stdlib.h>
#include <string.h>
#define CLUSTERS 64
struct FontClusters {
  struct { size_t length; char text[FONT_SHAPE_BYTES]; RenCluster cluster; } slots[CLUSTERS];
};
FontClusters *fontcluster_create(void){return calloc(1,sizeof(FontClusters));}
void fontcluster_destroy(FontClusters *cache){free(cache);}
const RenCluster *fontcluster_layout(FontClusters *cache,RenFont *font,const char *text,size_t length) {
  if(!cache || !text || !length || length>FONT_SHAPE_BYTES)return NULL;
  uint64_t hash=UINT64_C(14695981039346656037);
  for(size_t i=0;i<length;i++){hash^=(uint8_t)text[i];hash*=UINT64_C(1099511628211);}
  unsigned slot=(unsigned)(hash^(hash>>32))&(CLUSTERS-1);
  if(cache->slots[slot].length==length && !memcmp(cache->slots[slot].text,text,length))return &cache->slots[slot].cluster;
  uint32_t scalars[FONT_SHAPE_SCALARS];unsigned count=0;
  for(const char *p=text,*end=text+length;p<end;) {
    if(count==FONT_SHAPE_SCALARS)return NULL;
    p=bog_utf8_next(p,end,&scalars[count++]);
  }
  RenCluster result={.missing=true};
  uint16_t head=bunicode_properties(scalars[0]);
  bool emoji=(head&BU_EMOJI_PRESENTATION)!=0,text_presentation=false;
  for(unsigned i=1;i<count;i++) {
    if(scalars[i]==0xfe0f){emoji=true;text_presentation=false;}
    if(scalars[i]==0xfe0e){emoji=false;text_presentation=true;}
  }
  /* Emoji presentation must not stop at a monochrome heart/dingbat in the
   * primary font. Text presentation still prefers an outline face. */
  bool mono=text_presentation || (!emoji && (head&BU_EMOJI_VS_BASE));
  unsigned passes=(emoji || (mono && !text_presentation))?2:1;
  for(unsigned pass=0;pass<passes && result.missing;pass++)for(unsigned i=0;i<32;i++) {
    FontShape *shape=NULL;if(!ren_font_face_shape(font,i,&shape))return NULL;if(!shape)break;
    bool colored=ren_font_face_color(font,i);
    if((emoji && colored!=(pass==0)) || (mono && colored!=(pass==1)))continue;
    if(fontshape_run(shape,scalars,count,&result.run)) {
      /* A COLRv1/SVG-only glyph can shape successfully but our rasterizer
       * cannot paint it. Try the next face rather than publish a blank run. */
      bool drawable=true,ink=false,color_ink=false;
      if(colored)for(unsigned g=0;g<result.run.count;g++) {
        RenGlyph raster;
        if(!ren_font_glyph_id(font,i,result.run.glyphs[g].id,0,&raster)){drawable=false;break;}
        if(raster.x1>raster.x0 && raster.y1>raster.y0){ink=true;color_ink|=raster.colored;}
      }
      if(!drawable || (colored && (!ink || (emoji && !color_ink))))continue;
      result.face=i;result.missing=false;break;
    }
    if(!fontshape_allocation_ok(shape))return NULL;
  }
  if(result.missing)memset(&result.run,0,sizeof result.run);
  memcpy(cache->slots[slot].text,text,length);cache->slots[slot].length=length;
  cache->slots[slot].cluster=result;return &cache->slots[slot].cluster;
}
