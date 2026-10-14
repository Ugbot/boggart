#ifndef BOGGART_GLYPHCACHE_H
#define BOGGART_GLYPHCACHE_H
#include "fontglyph.h"
/* Fixed 7168-entry Venus Swiss map and at most four SDL pages per cache, starting
 * at 512 square and using 1024 for larger glyphs. No retained CPU pixels.
 * Capacity rollover flushes pending quads before
 * clearing textures. Failed unused-slot uploads do not publish an entry. */
typedef struct GlyphCache GlyphCache;
GlyphCache *glyphcache_create(SDL_Renderer *device,void (*flush)(void));
void glyphcache_destroy(GlyphCache *cache);
bool glyphcache_find(GlyphCache *cache,uint64_t key,RenGlyph *out);
bool glyphcache_insert(GlyphCache *cache,uint64_t key,const RenImage *image,
                       float xoff,float yoff,float advance,bool colored,RenGlyph *out);
uint64_t glyphcache_bytes(void);
#endif
