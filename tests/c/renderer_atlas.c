#include "renderer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(c) do{if(!(c)){fprintf(stderr,"line %d: %s (%s)\n",__LINE__,#c,SDL_GetError());exit(1);}}while(0)
static int fail_update,update_count;
static size_t glyphset_size;
static int fail_glyphset,allocation_count;
static void *checked_calloc(size_t n,size_t bytes) {
  if(fail_glyphset && n==1 && bytes==glyphset_size && ++allocation_count==fail_glyphset)return NULL;
  return calloc(n,bytes);
}
static bool checked_update(SDL_Texture *texture,const SDL_Rect *rect,const void *pixels,int pitch) {
  update_count++;if(fail_update && update_count==fail_update)return false;
  return SDL_UpdateTexture(texture,rect,pixels,pitch);
}
#define SDL_UpdateTexture checked_update
#define calloc checked_calloc
#include "../../studio/src/renderer.c"
#include "../../studio/src/fontglyph.c"
#include "../../studio/src/fontatlas.c"
#include "../../studio/src/glyphcache.c"
#undef calloc
#undef SDL_UpdateTexture
static unsigned char *pixels(size_t *bytes) {
  glyph_batch_flush();SDL_SetRenderTarget(renderer,target);
  SDL_Surface *surface=SDL_RenderReadPixels(renderer,NULL);CHECK(surface);
  *bytes=(size_t)surface->pitch*(size_t)surface->h;
  unsigned char *copy=malloc(*bytes);CHECK(copy);memcpy(copy,surface->pixels,*bytes);SDL_DestroySurface(surface);return copy;
}
int main(int argc,char **argv) {
  CHECK(argc==2);CHECK(SDL_Init(SDL_INIT_VIDEO));
  SDL_Window *win=SDL_CreateWindow("atlas test",640,240,SDL_WINDOW_HIDDEN);CHECK(win);ren_init(win);
  if(!strcmp(SDL_GetRendererName(renderer),"software"))CHECK(!share_style_atlases);
  ren_test_style_atlas_sharing(true);
  RenFont *base=ren_load_font(argv[1],16,NULL);CHECK(base);
  GlyphSet *regular=get_glyphset(base,'A',0);CHECK(regular->texture && !regular->shared_texture);
  SDL_Texture *old=regular->texture;
  /* Geometry already queued against the old texture must flush before retire. */
  ren_draw_text(base,"before",0,0,(RenColor){.r=255,.a=255});CHECK(glyph_batch_n>0);
  RenFont *bold=ren_get_font_variant(base,REN_STYLE_BOLD);CHECK(bold);
  GlyphSet *b=get_glyphset(bold,'A',0);CHECK(b->shared_texture && regular->shared_texture);
  CHECK(regular->texture==b->texture && regular->texture!=old && glyph_batch_n==0);
  RenFont *fonts[4]={base,bold,ren_get_font_variant(base,REN_STYLE_ITALIC),ren_get_font_variant(base,3)};
  for(unsigned i=0;i<4;i++)CHECK(get_glyphset(fonts[i],'A',0)->texture==regular->texture);
  ren_draw_rect((RenRect){0,32,640,32},(RenColor){.a=255});
  ren_reset_glyph_stats();
  for(unsigned i=0;i<80;i++)ren_draw_text(fonts[i&3],"A",(int)i*7,32,(RenColor){.r=255,.g=255,.b=255,.a=255});
  glyph_batch_flush();RenGlyphStats stats=ren_glyph_stats();CHECK(stats.quads==80 && stats.batches==1 && !stats.texture_switches);
  size_t native_bytes;unsigned char *native=pixels(&native_bytes);
  /* Independent style fonts use standalone atlases as the pixel oracle. */
  ren_draw_rect((RenRect){0,32,640,32},(RenColor){.a=255});
  RenFont *reference[4];
  for(unsigned i=0;i<4;i++){RenFontOptions opt={REN_AA_GRAYSCALE,REN_HINT_SLIGHT,i};reference[i]=ren_load_font(argv[1],16,&opt);CHECK(reference[i]);}
  for(unsigned i=0;i<80;i++)ren_draw_text(reference[i&3],"A",(int)i*7,32,(RenColor){.r=255,.g=255,.b=255,.a=255});
  size_t reference_bytes;unsigned char *expected=pixels(&reference_bytes);
  CHECK(native_bytes==reference_bytes && !memcmp(native,expected,native_bytes));free(native);free(expected);
  for(unsigned i=0;i<4;i++)ren_free_font(reference[i]);ren_free_font(base);
  /* A failed shared-page upload falls back without changing existing sets. */
  base=ren_load_font(argv[1],16,NULL);CHECK(base);regular=get_glyphset(base,'A',0);old=regular->texture;
  bold=ren_get_font_variant(base,1);update_count=0;fail_update=2;
  b=get_glyphset(bold,'A',0);fail_update=0;
  CHECK(!regular->shared_texture && regular->texture==old && b->texture && !b->shared_texture);
  RenFont *italic=ren_get_font_variant(base,2);GlyphSet *c=get_glyphset(italic,'A',0);
  CHECK(c->shared_texture && regular->texture==b->texture && b->texture==c->texture);
  /* Larger later styles replace the page, retaining all old style slots. */
  RenFont *both=ren_get_font_variant(base,3);float original=both->size;both->size=64;
  CHECK(face_set_size(both->faces[0].face,64));
  GlyphSet *large=get_glyphset(both,'A',0);both->size=original;
  CHECK(large->shared_texture && regular->texture==large->texture && b->texture==large->texture);
  ren_free_font(base);
  base=ren_load_font(argv[1],16,NULL);CHECK(base);regular=get_glyphset(base,'A',0);old=regular->texture;
  bold=ren_get_font_variant(base,1);glyphset_size=sizeof(GlyphSet);allocation_count=0;fail_glyphset=2;
  b=get_glyphset(bold,'A',0);fail_glyphset=0;
  CHECK(!regular->shared_texture && regular->texture==old && b->texture && !b->shared_texture);
  ren_free_font(base);
  base=ren_load_font(argv[1],16,NULL);CHECK(base);regular=get_glyphset(base,'A',0);
  bold=ren_get_font_variant(base,1);b=get_glyphset(bold,'A',0);old=regular->texture;
  italic=ren_get_font_variant(base,2);update_count=0;fail_update=1;
  c=get_glyphset(italic,'A',0);fail_update=0;
  CHECK(regular->texture==old && b->texture==old && !c->shared_texture && c->texture!=old);
  both=ren_get_font_variant(base,3);large=get_glyphset(both,'A',0);
  CHECK(regular->texture==c->texture && c->texture==large->texture);ren_free_font(base);
  base=ren_load_font(argv[1],16,NULL);CHECK(base);regular=get_glyphset(base,'A',0);old=regular->texture;
  bold=ren_get_font_variant(base,1);glyphset_size=sizeof(FontAtlas);allocation_count=0;fail_glyphset=1;
  b=get_glyphset(bold,'A',0);fail_glyphset=0;
  CHECK(regular->texture==old && !regular->shared_texture && b->texture && !b->shared_texture);ren_free_font(base);
  GlyphCache *ids=glyphcache_create(renderer,glyph_batch_flush);CHECK(ids);
  RenColor ink={.r=255,.g=255,.b=255,.a=255};RenImage image={&ink,1,1};RenGlyph glyph,old_glyph;
  update_count=0;fail_update=1;CHECK(!glyphcache_insert(ids,0,&image,0,0,1,&glyph));fail_update=0;
  CHECK(!glyphcache_find(ids,0,&glyph) && !glyphcache_bytes());
  CHECK(glyphcache_insert(ids,0,&image,0,0,1,&glyph));old_glyph=glyph;
  update_count=0;fail_update=1;CHECK(!glyphcache_insert(ids,1,&image,0,0,1,&glyph));fail_update=0;
  CHECK(glyphcache_find(ids,0,&glyph) && !memcmp(&glyph,&old_glyph,sizeof glyph));
  CHECK(!glyphcache_find(ids,1,&glyph));
  ren_draw_glyph(glyph,0,0,1,(RenColor){.r=255,.a=255});CHECK(glyph_batch_n>0);
  for(uint64_t key=1;key<=7168;key++)CHECK(glyphcache_insert(ids,key,&image,0,0,1,&glyph));
  CHECK(!glyph_batch_n && !glyphcache_find(ids,0,&glyph) && glyphcache_find(ids,7168,&glyph));
  glyphcache_destroy(ids);CHECK(!glyphcache_bytes());
  ids=glyphcache_create(renderer,glyph_batch_flush);CHECK(ids);
  RenColor *large_pixels=calloc((size_t)1022*1022,sizeof *large_pixels);CHECK(large_pixels);
  image=(RenImage){large_pixels,1022,1022};
  for(uint64_t key=0;key<4;key++)CHECK(glyphcache_insert(ids,key,&image,0,0,1,&glyph));
  CHECK(glyphcache_bytes()==UINT64_C(4)*1024*1024*4);
  CHECK(glyphcache_insert(ids,4,&image,0,0,1,&glyph));
  CHECK(glyphcache_bytes()==UINT64_C(1024)*1024*4 && !glyphcache_find(ids,0,&glyph));
  free(large_pixels);glyphcache_destroy(ids);CHECK(!glyphcache_bytes());
  CHECK(!fontatlas_create(renderer,2049));
  CHECK(!fontatlas_capacity_bytes() && !standalone_atlas_bytes);
  SDL_DestroyTexture(target);target=NULL;SDL_DestroyRenderer(renderer);renderer=NULL;SDL_DestroyWindow(win);SDL_Quit();
  puts("SDL atlas: shared style texture/batches, exact pixels, pending geometry, fallback/growth, ID cache rollover/upload failure and teardown pass");return 0;
}
