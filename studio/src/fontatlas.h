#ifndef BOGGART_FONTATLAS_H
#define BOGGART_FONTATLAS_H
#include "renderer.h"
/* Four fixed style slots. Cold creation/upload, main-thread only. A failed
 * upload into an unused slot does not change any published glyph metadata. */
typedef struct FontAtlas FontAtlas;
FontAtlas *fontatlas_create(SDL_Renderer *renderer,int tile);
bool fontatlas_upload(FontAtlas *atlas,unsigned slot,const RenImage *image);
SDL_Texture *fontatlas_texture(const FontAtlas *atlas);
int fontatlas_tile(const FontAtlas *atlas);
void fontatlas_destroy(FontAtlas *atlas);
uint64_t fontatlas_capacity_bytes(void);
#endif
