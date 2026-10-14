#include "glyphcache.h"
#include "lidmap.h"
#include <stdlib.h>
#include <string.h>
#define GC_ENTRIES 7168
#define GC_SIDE 1024
#define GC_PAGES 4
typedef struct { SDL_Texture *texture; int x,y,height,side; } Page;
struct GlyphCache {
  lidmap map; RenGlyph entries[GC_ENTRIES]; unsigned count,pages;
  Page page[GC_PAGES]; SDL_Renderer *device; void (*flush)(void);
};
static uint64_t page_bytes;
GlyphCache *glyphcache_create(SDL_Renderer *device,void (*flush)(void)) {
  GlyphCache *cache=calloc(1,sizeof *cache);if(!cache)return NULL;
  if(!lidmap_init(&cache->map,4096)){free(cache);return NULL;}
  cache->device=device;cache->flush=flush;return cache;
}
static void clear(GlyphCache *cache) {
  if(cache->flush)cache->flush();
  for(unsigned i=0;i<cache->pages;i++) {
    SDL_DestroyTexture(cache->page[i].texture);page_bytes-=(uint64_t)cache->page[i].side*cache->page[i].side*4;
  }
  memset(cache->page,0,sizeof cache->page);cache->pages=cache->count=0;lidmap_clear(&cache->map);
}
void glyphcache_destroy(GlyphCache *cache) {
  if(!cache)return;clear(cache);lidmap_free(&cache->map);free(cache);
}
bool glyphcache_find(GlyphCache *cache,uint64_t key,RenGlyph *out) {
  uint32_t i;if(!cache || !lidmap_find(&cache->map,key,&i))return false;
  *out=cache->entries[i];return true;
}
static bool page_create(GlyphCache *cache,int side,Page *out) {
  RenColor *pixels=calloc((size_t)side*side,sizeof *pixels);if(!pixels)return false;
  SDL_Texture *texture=SDL_CreateTexture(cache->device,SDL_PIXELFORMAT_ARGB8888,SDL_TEXTUREACCESS_STATIC,side,side);
  bool ok=texture && SDL_SetTextureBlendMode(texture,SDL_BLENDMODE_BLEND)
    && SDL_SetTextureScaleMode(texture,SDL_SCALEMODE_NEAREST)
    && SDL_UpdateTexture(texture,NULL,pixels,side*(int)sizeof *pixels);
  free(pixels);if(!ok){if(texture)SDL_DestroyTexture(texture);return false;}
  *out=(Page){.texture=texture,.side=side};return true;
}
bool glyphcache_insert(GlyphCache *cache,uint64_t key,const RenImage *image,
                       float xoff,float yoff,float advance,RenGlyph *out) {
  if(!cache || !out || !image || image->width<0 || image->height<0
    || image->width>GC_SIDE-2 || image->height>GC_SIDE-2)return false;
  if(glyphcache_find(cache,key,out))return true;
  if(cache->count==GC_ENTRIES)clear(cache);
  int w=image->width,h=image->height;RenGlyph glyph={.xoff=xoff,.yoff=yoff,.xadvance=advance};
  unsigned index=cache->pages ? cache->pages-1 : 0;Page next={0};bool fresh=false;
  if(w && h && cache->device) {
    if(!image->pixels)return false;
    if(cache->pages)next=cache->page[index];
    if(next.texture && next.x+w+2>next.side){next.x=0;next.y+=next.height;next.height=0;}
    if(next.texture && (next.y+h+2>next.side || w+2>next.side)){index=cache->pages;next=(Page){0};}
    if(!next.texture) {
      if(index==GC_PAGES){clear(cache);index=0;}
      if(!page_create(cache,w+2>512 || h+2>512 ? GC_SIDE : 512,&next))return false;fresh=true;
    }
    SDL_Rect rect={next.x+1,next.y+1,w,h};
    if(!SDL_UpdateTexture(next.texture,&rect,image->pixels,w*(int)sizeof(RenColor))) {
      if(fresh)SDL_DestroyTexture(next.texture);return false;
    }
    glyph.texture=next.texture;glyph.tw=glyph.th=next.side;
    glyph.x0=(unsigned short)rect.x;glyph.y0=(unsigned short)rect.y;
    glyph.x1=(unsigned short)(rect.x+w);glyph.y1=(unsigned short)(rect.y+h);
    next.x+=w+2;if(h+2>next.height)next.height=h+2;
  } else {glyph.x1=(unsigned short)w;glyph.y1=(unsigned short)h;}
  /* The fixed map admits exactly these 7168 entries at its 7/8 load limit. */
  if(!lidmap_insert(&cache->map,key,cache->count)) {
    if(fresh)SDL_DestroyTexture(next.texture);return false;
  }
  if(glyph.texture) {
    cache->page[index]=next;
    if(fresh){cache->pages=index+1;page_bytes+=(uint64_t)next.side*next.side*4;}
  }
  cache->entries[cache->count++]=glyph;*out=glyph;return true;
}
uint64_t glyphcache_bytes(void){return page_bytes;}
