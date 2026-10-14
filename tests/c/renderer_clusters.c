#include "renderer.h"
#include "fontcluster.h"
#include "termgrid.h"
#include "termrender.h"
#include "btunicode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(c) do{if(!(c)){fprintf(stderr,"line %d: %s (%s)\n",__LINE__,#c,SDL_GetError());exit(1);}}while(0)
#include "../../studio/src/renderer.c"
#include "../../studio/src/fontglyph.c"
static unsigned char *pixels(size_t *bytes) {
  glyph_batch_flush();SDL_SetRenderTarget(renderer,target);
  SDL_Surface *surface=SDL_RenderReadPixels(renderer,NULL);CHECK(surface);
  SDL_Surface *rgba=SDL_ConvertSurface(surface,SDL_PIXELFORMAT_RGBA32);CHECK(rgba);
  SDL_DestroySurface(surface);surface=rgba;
  *bytes=(size_t)surface->pitch*(size_t)surface->h;
  unsigned char *copy=malloc(*bytes);CHECK(copy);memcpy(copy,surface->pixels,*bytes);SDL_DestroySurface(surface);return copy;
}
static unsigned char *draw_cell(RenFont *font,const char *text,int width,size_t *bytes) {
  ren_draw_rect((RenRect){0,0,640,240},(RenColor){.a=255});
  ren_draw_cluster(font,text,strlen(text),20,20,width,(RenColor){.r=255,.g=255,.b=255,.a=255});
  ren_draw_text(font,"X",20+width,20,(RenColor){.r=255,.a=255});
  return pixels(bytes);
}
static unsigned char *draw_emoji(RenFont *font,const char *text,int width,RenColor color,size_t *bytes) {
  ren_draw_rect((RenRect){0,0,640,240},(RenColor){.a=255});
  ren_draw_cluster(font,text,strlen(text),20,20,width,color);
  ren_draw_text(font,"X",20+width,20,(RenColor){.r=255,.a=255});
  return pixels(bytes);
}
static unsigned chromatic(const unsigned char *rgba,int width) {
  unsigned count=0;
  for(int y=0;y<80;y++)for(int x=20;x<20+width;x++) {
    const unsigned char *p=rgba+((size_t)y*640+x)*4;
    if(p[0]!=p[1] || p[1]!=p[2])count++;
  }
  return count;
}
int main(int argc,char **argv) {
  CHECK(argc==3 || argc==4);CHECK(SDL_Init(SDL_INIT_VIDEO));
  SDL_Window *win=SDL_CreateWindow("cluster test",640,240,SDL_WINDOW_HIDDEN);CHECK(win);ren_init(win);
  RenFont *font=ren_load_font(argv[1],16,NULL);CHECK(font);
  if(argc==4) {
    const unsigned char half_red[]={0,0,128,128},transparent[]={255,128,10,0};
    RenColor straight=color_pixel(half_red);CHECK(straight.r==255 && straight.g==0 && straight.b==0 && straight.a==128);
    straight=color_pixel(transparent);CHECK(!straight.r && !straight.g && !straight.b && !straight.a);
    /* The test's BOGGART_STUDIO_FONTS pins the color face. A diagnostic box
     * passing a byte-stability oracle is insufficient: require colored ink. */
    const char *emoji[]={"😀","👩‍💻","🇬🇧","❤️","👍🏽","1️⃣","👨‍👩‍👧‍👦"};
    for(unsigned flags=0;flags<4;flags++) {
      RenFont *variant=ren_get_font_variant(font,flags);CHECK(variant);
      for(unsigned e=0;e<sizeof emoji/sizeof *emoji;e++) {
        const RenCluster *cluster=ren_font_cluster(variant,emoji[e],strlen(emoji[e]));
        CHECK(cluster && !cluster->missing && ren_font_face_color(variant,cluster->face));
        CHECK(cluster->run.count==1);
        RenGlyph glyph;CHECK(ren_font_glyph_id(variant,cluster->face,cluster->run.glyphs[0].id,0,&glyph));
        CHECK(glyph.colored && glyph.x1>glyph.x0 && glyph.y1>glyph.y0);
        CHECK(glyph.y1-glyph.y0<40); /* Selected 109px strike has been scaled. */
        int width=btunicode_text_width(emoji[e],strlen(emoji[e]),true)*font->cell;
        CHECK(width==2*font->cell);
        size_t a,b,c;unsigned char *white=draw_emoji(variant,emoji[e],width,(RenColor){255,255,255,255},&a);
        unsigned char *green=draw_emoji(variant,emoji[e],width,(RenColor){0,255,0,255},&b);
        unsigned char *dim=draw_emoji(variant,emoji[e],width,(RenColor){255,255,255,100},&c);
        CHECK(a==b && a==c && !memcmp(white,green,a) && memcmp(white,dim,a));
        CHECK(chromatic(white,width)>0);
        free(white);free(green);free(dim);
      }
    }
    const RenCluster *text=ren_font_cluster(font,"©︎",strlen("©︎"));
    CHECK(text && !text->missing && !ren_font_face_color(font,text->face));
    RenFont *bitmap=ren_load_font(argv[3],13.5f,NULL);CHECK(bitmap);
    CHECK(ren_font_metrics(bitmap).height<32);
    const RenCluster *cluster=ren_font_cluster(bitmap,"👩‍💻",strlen("👩‍💻"));
    CHECK(cluster && !cluster->missing && cluster->face==0);
    RenGlyph glyph;CHECK(ren_font_glyph_id(bitmap,0,cluster->run.glyphs[0].id,0,&glyph));
    CHECK(glyph.colored && glyph.y1-glyph.y0<32);ren_free_font(bitmap);
    for(unsigned e=0;e<sizeof emoji/sizeof *emoji;e++) {
      bterm *native=bterm_create(16,1,0,NULL,NULL);CHECK(native);
      CHECK(bterm_feed(native,(const uint8_t *)emoji[e],strlen(emoji[e])));
      CHECK(bterm_feed(native,(const uint8_t *)"X",1));
      tg_row *snapshot=tg_capture(native,lpage_visible(bterm_screen(native),0),16);CHECK(snapshot);
      CHECK(snapshot->cells[0].width==2 && snapshot->cells[2].width==1);
      tg_theme theme={.foreground={.r=255,.g=255,.b=255,.a=255}};
      ren_draw_rect((RenRect){0,0,640,240},(RenColor){.a=255});
      tg_draw(snapshot,font,&theme,20,20,font->cell,font->height);size_t a;unsigned char *expected=pixels(&a);
      tg_release(snapshot);bterm_destroy(native);
      char joined[128];snprintf(joined,sizeof joined,"%sX",emoji[e]);
      ren_draw_rect((RenRect){0,0,640,240},(RenColor){.a=255});
      ren_draw_grid(font,joined,strlen(joined),20,20,theme.foreground);size_t b;unsigned char *actual=pixels(&b);
      CHECK(a==b && !memcmp(expected,actual,a));free(expected);free(actual);
    }
    ren_free_font(font);CHECK(!glyphcache_bytes());
    SDL_DestroyTexture(target);SDL_DestroyRenderer(renderer);SDL_DestroyWindow(win);SDL_Quit();
    puts("color emoji: ZWJ/flags/selectors/skin tones, scaled strikes, native/grid pixels, intrinsic color and opacity pass");return 0;
  }
  const char *texts[]={"日","é","Ω","👩‍💻","🇬🇧","क्‍ष"};
  for(unsigned i=0;i<sizeof texts/sizeof *texts;i++) {
    const RenCluster *run=ren_font_cluster(font,texts[i],strlen(texts[i]));CHECK(run);
    for(unsigned j=0;j<run->run.count;j++) {
      RenGlyph g;uint32_t id=run->run.glyphs[j].id;
      CHECK(ren_font_glyph_id(font,run->face,id,0,&g));
    }
    RenRect bounds;CHECK(ren_get_cluster_bounds(font,texts[i],strlen(texts[i]),18,&bounds));
  }
  bterm *term=bterm_create(24,8,12,NULL,NULL);CHECK(term);
  const char *input="plain 日é Ω\r\n\033[1;31;44mBOLD\033[2;7m INV\033[0m\r\n"
    "\033[38;2;19;123;241;48;5;233mRGB\033[0m\r\n"
    "\033[4:1;58;2;255;0;0mONE\033[4:2m TWO\033[4:3m WAVE\033[0m\r\n"
    "\033[4:4mDOT\033[4:5m DASH\033[9;53m LINES\033[8m HIDDEN\033[0m\r\n"
    "\033[3mITALIC Ag日é\033[0m\r\n\033[1;3mBOTH Ag日é\033[0m";
  CHECK(bterm_feed(term,(const uint8_t *)input,strlen(input)));
  for(unsigned row=0;row<8;row++) {
    tg_row *snapshot=tg_capture(term,lpage_visible(bterm_screen(term),row),24);CHECK(snapshot);
    for(unsigned i=0;i<24;i++) {
      tg_cell *cell=&snapshot->cells[i];if(!cell->width || !cell->length)continue;
      unsigned flags=((cell->style.attrs&LP_BOLD)!=0)|(((cell->style.attrs&LP_ITALIC)!=0)<<1);
      RenFont *variant=ren_get_font_variant(font,flags);CHECK(variant);RenRect bounds;
      if(!ren_get_cluster_bounds(variant,tg_text(snapshot,cell),cell->length,cell->width*font->cell,&bounds)) {
        printf("failed native row %u col %u length %u width %u flags %u first byte %x\n",row,i,cell->length,cell->width,flags,(unsigned char)*tg_text(snapshot,cell));return 1;
      }
    }
    tg_release(snapshot);
  }
  bterm_destroy(term);
  /* A positive-width soft hyphen is a retained terminal cell, rather than
   * discretionary line-breaking input. It must keep its font's nominal ink. */
  bterm *soft=bterm_create(4,1,0,NULL,NULL);CHECK(soft);
  CHECK(bterm_feed(soft,(const uint8_t *)"\xc2\xad",2));
  CHECK(lpage_visible(bterm_screen(soft),0)->cells[0].width==1);
  CHECK(lpage_codepoint(bterm_screen(soft),&lpage_visible(bterm_screen(soft),0)->cells[0])==0xad);
  bterm_destroy(soft);
  const RenCluster *hyphen=ren_font_cluster(font,"\xc2\xad",2);CHECK(hyphen && !hyphen->missing && hyphen->run.count==1);
  CHECK(hyphen->run.glyphs[0].id==FT_Get_Char_Index(font->faces[hyphen->face].face,0xad));
  hyphen=ren_font_cluster(font,"\xc2\xad\xcc\x81\xe2\x80\x8d",7);
  CHECK(hyphen && !hyphen->missing && hyphen->run.count>=1);
  CHECK(hyphen->run.glyphs[0].id==FT_Get_Char_Index(font->faces[hyphen->face].face,0xad));
  for(unsigned flags=0;flags<4;flags++) {
    RenFont *variant=ren_get_font_variant(font,flags);CHECK(variant);
    for(int width=1;width<=18;width++) {
      size_t a,b;unsigned char *accent=draw_cell(variant,"é",width,&a),*composed=draw_cell(variant,"é",width,&b);
      CHECK(a==b && !memcmp(accent,composed,a));free(accent);free(composed);
    }
    const RenCluster *marks=ren_font_cluster(variant,"x́",3);CHECK(marks && !marks->missing && marks->run.count==2);
    CHECK(marks->run.glyphs[1].x!=0 || marks->run.glyphs[1].y!=0);
  }
  const char *vectors[]={"éX","x́X","👩‍💻X","🇬🇧X","❤️X","⌚︎X","क्षX","日X"};
  tg_theme theme={.foreground={.r=255,.g=255,.b=255,.a=255}};
  for(unsigned mode=0;mode<2;mode++)for(unsigned v=0;v<sizeof vectors/sizeof *vectors;v++) {
    unsigned char *expected=NULL;size_t expected_size=0,length=strlen(vectors[v]);
    for(size_t split=0;split<=length;split++) {
      bterm *native=bterm_create(16,1,0,NULL,NULL);CHECK(native);
      if(!mode)CHECK(bterm_feed(native,(const uint8_t *)"\033[?2027l",8));
      CHECK(bterm_feed(native,(const uint8_t *)vectors[v],split));
      CHECK(bterm_feed(native,(const uint8_t *)vectors[v]+split,length-split));
      tg_row *snapshot=tg_capture(native,lpage_visible(bterm_screen(native),0),16);CHECK(snapshot);
      RenRect bounds;CHECK(tg_measure(snapshot,font,font->cell,font->height,&bounds));
      bterm_destroy(native); /* Drawing owns complete cell text, not source IDs. */
      ren_draw_rect((RenRect){0,0,640,240},(RenColor){.a=255});
      tg_draw(snapshot,font,&theme,20,20,font->cell,font->height);tg_release(snapshot);
      size_t n;unsigned char *actual=pixels(&n);
      if(!expected){expected=actual;expected_size=n;}
      else {CHECK(n==expected_size && !memcmp(expected,actual,n));free(actual);}
    }
    free(expected);
  }
  FontShape *shape=NULL;CHECK(ren_font_face_shape(font,0,&shape) && shape);
  for(unsigned v=0;v<sizeof vectors/sizeof *vectors;v++) {
    const char *text=vectors[v];size_t length=strlen(text);
    bterm *native=bterm_create(64,1,0,NULL,NULL);CHECK(native);
    CHECK(bterm_feed(native,(const uint8_t *)text,length));
    tg_row *snapshot=tg_capture(native,lpage_visible(bterm_screen(native),0),64);CHECK(snapshot);
    ren_draw_rect((RenRect){0,0,640,240},(RenColor){.a=255});
    tg_draw(snapshot,font,&theme,20,20,font->cell,font->height);size_t a;unsigned char *expected=pixels(&a);
    tg_release(snapshot);bterm_destroy(native);
    ren_draw_rect((RenRect){0,0,640,240},(RenColor){.a=255});
    RenRect bounds;CHECK(ren_get_grid_bounds(font,text,length,&bounds));
    CHECK(ren_get_grid_width(font,text,length)==btunicode_text_width(text,length,true)*font->cell);
    ren_draw_grid(font,text,length,20,20,theme.foreground);size_t b;unsigned char *actual=pixels(&b);
    CHECK(a==b && !memcmp(expected,actual,a));free(expected);free(actual);
  }
  uint32_t too_many[FONT_SHAPE_SCALARS+1]={0};FontShapeRun unchanged;memset(&unchanged,0x5a,sizeof unchanged);
  FontShapeRun before=unchanged;CHECK(!fontshape_run(shape,too_many,FONT_SHAPE_SCALARS+1,&unchanged));CHECK(!memcmp(&before,&unchanged,sizeof before));
  RenFont *indic=ren_load_font(argv[2],16,NULL);CHECK(indic);
  const RenCluster *conjunct=ren_font_cluster(indic,"क्ष",strlen("क्ष"));CHECK(conjunct && !conjunct->missing && conjunct->face==0 && conjunct->run.count==1);
  const RenCluster *vowel=ren_font_cluster(indic,"कि",strlen("कि"));CHECK(vowel && !vowel->missing && vowel->face==0 && vowel->run.count==2);
  CHECK(vowel->run.glyphs[0].id!=FT_Get_Char_Index(indic->faces[0].face,0x915));
  RenRect bounds;CHECK(ren_get_cluster_bounds(indic,"कि",strlen("कि"),9,&bounds));ren_free_font(indic);
  /* Freeing a font must flush pending ID-atlas geometry before retiring pages. */
  ren_draw_rect((RenRect){0,0,640,240},(RenColor){.a=255});
  ren_draw_cluster(font,"x́",3,20,20,9,(RenColor){.r=255,.a=255});size_t a;unsigned char *expected=pixels(&a);
  ren_draw_rect((RenRect){0,0,640,240},(RenColor){.a=255});
  ren_draw_cluster(font,"x́",3,20,20,9,(RenColor){.r=255,.a=255});CHECK(glyph_batch_n>0);
  ren_free_font(font);CHECK(!glyphcache_bytes());size_t b;unsigned char *actual=pixels(&b);
  CHECK(a==b && !memcmp(expected,actual,a));free(expected);free(actual);

  SDL_DestroyTexture(target);SDL_DestroyRenderer(renderer);SDL_DestroyWindow(win);SDL_Quit();puts("native clusters: canonical pixels, positioned marks/Indic, byte splits/modes, retained rows and atlas lifetime pass");return 0;
}
