#include "fontatlas.h"
#include <stdlib.h>
struct FontAtlas { SDL_Texture *texture;int tile; };
static uint64_t capacity_bytes;
FontAtlas *fontatlas_create(SDL_Renderer *renderer,int tile) {
  if(!renderer || tile<1 || tile>2048)return NULL;
  FontAtlas *atlas=calloc(1,sizeof *atlas);if(!atlas)return NULL;
  int side=tile*2;size_t bytes=(size_t)side*(size_t)side*sizeof(RenColor);
  void *empty=calloc(1,bytes);if(!empty){free(atlas);return NULL;}
  atlas->texture=SDL_CreateTexture(renderer,SDL_PIXELFORMAT_ARGB8888,SDL_TEXTUREACCESS_STATIC,side,side);
  bool ready=atlas->texture && SDL_SetTextureBlendMode(atlas->texture,SDL_BLENDMODE_BLEND)
    && SDL_SetTextureScaleMode(atlas->texture,SDL_SCALEMODE_NEAREST)
    && SDL_UpdateTexture(atlas->texture,NULL,empty,side*(int)sizeof(RenColor));
  free(empty);
  if(!ready){fontatlas_destroy(atlas);return NULL;}
  atlas->tile=tile;capacity_bytes+=(uint64_t)bytes;return atlas;
}
bool fontatlas_upload(FontAtlas *atlas,unsigned slot,const RenImage *image) {
  if(!atlas || slot>=4 || !image || image->width<1 || image->height<1
    || image->width>atlas->tile || image->height>atlas->tile)return false;
  SDL_Rect rect={(int)(slot&1)*atlas->tile,(int)(slot>>1)*atlas->tile,image->width,image->height};
  return SDL_UpdateTexture(atlas->texture,&rect,image->pixels,image->width*(int)sizeof(RenColor));
}
SDL_Texture *fontatlas_texture(const FontAtlas *atlas){return atlas->texture;}
int fontatlas_tile(const FontAtlas *atlas){return atlas->tile;}
void fontatlas_destroy(FontAtlas *atlas){if(atlas){
  if(atlas->tile)capacity_bytes-=(uint64_t)atlas->tile*(uint64_t)atlas->tile*16;
  if(atlas->texture)SDL_DestroyTexture(atlas->texture);free(atlas);
}}
uint64_t fontatlas_capacity_bytes(void){return capacity_bytes;}
