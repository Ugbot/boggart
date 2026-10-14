#include "renderer.h"
#include "termgrid.h"
#include "termrender.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(c) do{if(!(c)){fprintf(stderr,"line %d: %s\n",__LINE__,#c);exit(1);}}while(0)
static bool allocation_fails,face_fails;
static void *font_calloc(size_t n,size_t bytes){return allocation_fails ? NULL : calloc(n,bytes);}
static FT_Error font_face(FT_Library lib,const FT_Byte *bytes,FT_Long n,FT_Long index,FT_Face *face){
  return face_fails ? FT_Err_Invalid_Argument : FT_New_Memory_Face(lib,bytes,n,index,face);
}
#define calloc font_calloc
#define FT_New_Memory_Face font_face
#include "../../studio/src/renderer.c"
#include "../../studio/src/fontglyph.c"
#undef calloc
#undef FT_New_Memory_Face
static uint64_t atlas_hash(GlyphSet *set) {
  uint64_t hash=UINT64_C(14695981039346656037);
  CHECK(set->image);const unsigned char *bytes=(const unsigned char *)set->image->pixels;
  size_t n=(size_t)set->image->width*(size_t)set->image->height*sizeof(RenColor);
  for(size_t i=0;i<n;i++){hash^=bytes[i];hash*=UINT64_C(1099511628211);}return hash;
}
int main(int argc,char **argv) {
  CHECK(argc==2);RenFont *base=ren_load_font(argv[1],16,NULL);CHECK(base);
  int width=ren_get_font_width(base,"Ag日é"),height=base->height;
  void *data=base->data;size_t bytes=base->datalen;
  allocation_fails=true;CHECK(!ren_get_font_variant(base,REN_STYLE_BOLD));allocation_fails=false;
  CHECK(base->data==data && base->datalen==bytes && ren_get_font_width(base,"Ag日é")==width);
  face_fails=true;CHECK(!ren_get_font_variant(base,REN_STYLE_ITALIC));face_fails=false;
  CHECK(ren_get_font_width(base,"Ag日é")==width);
  RenFont *fonts[4]={base,NULL,NULL,NULL};uint64_t hashes[4];
  for(unsigned flags=0;flags<4;flags++) {
    fonts[flags]=ren_get_font_variant(base,flags);CHECK(fonts[flags]);
    CHECK(fonts[flags]==ren_get_font_variant(base,flags));
    CHECK(fonts[flags]->data==data && fonts[flags]->datalen==bytes);
    CHECK(fonts[flags]->style==flags && fonts[flags]->height==height && fonts[flags]->cell==base->cell);
    CHECK(ren_get_font_width(fonts[flags],"Ag日é")==width);
    hashes[flags]=atlas_hash(get_glyphset(fonts[flags],'A',0));
    RenRect bounds=ren_get_text_bounds(fonts[flags],"Ag日é");CHECK(bounds.x<=0 && bounds.width>=width && bounds.height>=height);
    for(unsigned cp='!';cp<='~';cp++) {
      char text[2]={(char)cp,0};Glyph *glyph=&get_glyphset(fonts[flags],cp,0)->glyphs[cp];
      if(glyph->x1>glyph->x0 && glyph->y1>glyph->y0) {
        bounds=ren_get_text_bounds(fonts[flags],text);
        CHECK(bounds.x<=(int)floorf(glyph->xoff) && bounds.y<=(int)floorf(glyph->yoff));
        CHECK(bounds.x+bounds.width>=(int)ceilf(glyph->xoff+glyph->x1-glyph->x0));
        CHECK(bounds.y+bounds.height>=(int)ceilf(glyph->yoff+glyph->y1-glyph->y0));
      }
    }
  }
  for(unsigned a=0;a<4;a++)for(unsigned b=a+1;b<4;b++)CHECK(fonts[a]!=fonts[b] && hashes[a]!=hashes[b]);
  CHECK(ren_get_font_variant(fonts[1],REN_STYLE_ITALIC)==fonts[3]);
  ren_set_font_tab_width(base,23);
  CHECK(ren_get_font_tab_width(ren_get_font_variant(base,REN_STYLE_BOLD))==23);
  ren_set_font_tab_width(base,0);CHECK(ren_get_font_tab_width(ren_get_font_variant(base,REN_STYLE_BOLD))==0);
  /* FreeType faces and atlases must go before their single shared byte owner. */
  ren_free_font(base);
  RenFontOptions opt={REN_AA_GRAYSCALE,REN_HINT_SLIGHT,REN_STYLE_BOLD};
  base=ren_load_font(argv[1],16,&opt);CHECK(base);
  CHECK(ren_get_font_variant(base,0)==base && ren_get_font_variant(base,REN_STYLE_BOLD)==base);
  CHECK(ren_get_font_variant(base,REN_STYLE_ITALIC)->style==(REN_STYLE_BOLD|REN_STYLE_ITALIC));ren_free_font(base);
  base=ren_load_font(argv[1],16,NULL);CHECK(base);
  bterm *term=bterm_create(4,1,0,NULL,NULL);CHECK(term);
  const char *styled="\033[1;3mA";CHECK(bterm_feed(term,(const uint8_t *)styled,strlen(styled)));
  tg_row *row=tg_capture(term,lpage_visible(bterm_screen(term),0),4);CHECK(row);
  RenRect bounds={11,22,33,44},before=bounds;
  allocation_fails=true;CHECK(!tg_measure(row,base,8,16,&bounds));allocation_fails=false;
  CHECK(!memcmp(&before,&bounds,sizeof bounds));
  face_fails=true;CHECK(!tg_measure(row,base,8,16,&bounds));face_fails=false;
  CHECK(!memcmp(&before,&bounds,sizeof bounds));
  CHECK(tg_measure(row,base,8,16,&bounds));
  bterm_destroy(term);tg_release(row);ren_free_font(base);
  opt.style=REN_STYLE_UNDERLINE|REN_STYLE_STRIKETHROUGH;
  base=ren_load_font(argv[1],16,&opt);CHECK(base);
  base->underline=base->height+3;
  bounds=ren_get_text_bounds(base,"A");CHECK(bounds.y<=-3);
  CHECK(bounds.y+bounds.height>=base->baseline-base->height/6+base->underline);
  ren_free_font(base);
  puts("font variants: shared bytes/cache, stable metrics, styled atlases, failure recovery and teardown pass");return 0;
}
