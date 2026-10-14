#include "fontcluster.h"
#include "utf8width.h"
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
  for(unsigned i=0;i<32;i++) {
    FontShape *shape=NULL;if(!ren_font_face_shape(font,i,&shape))return NULL;if(!shape)break;
    if(fontshape_run(shape,scalars,count,&result.run)) {
      result.face=i;result.missing=false;break;
    }
    if(!fontshape_allocation_ok(shape))return NULL;
  }
  memcpy(cache->slots[slot].text,text,length);cache->slots[slot].length=length;
  cache->slots[slot].cluster=result;return &cache->slots[slot].cluster;
}
