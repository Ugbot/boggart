#include "fontcluster.h"
#include <math.h>
#include <string.h>
static bool cluster_shaping=true;
bool ren_test_cluster_shaping(bool enabled){bool old=cluster_shaping;cluster_shaping=enabled;return old;}
/* Terminal cells supply their recorded advance. Generic editor text keeps its
 * scalar policy until its measurement/prefix consumers migrate together. */
static void diagnostic(RenFont *font,int advance,int x,int y,RenColor color) {
  int height=ren_get_font_height(font),left=advance>2 ? 1 : 0,w=advance>2 ? advance-2 : advance;
  int top=height>6 ? 3 : 0,h=height>6 ? height-6 : height;
  ren_draw_rect((RenRect){x+left,y+top,w,1},color);
  ren_draw_rect((RenRect){x+left,y+top+h-1,w,1},color);
  ren_draw_rect((RenRect){x+left,y+top,1,h},color);
  ren_draw_rect((RenRect){x+left+w-1,y+top,1,h},color);
}
static bool layout(RenFont *font,const char *text,size_t length,int advance,
                   bool paint,int x,int y,RenColor color,uint8_t intensity,RenRect *bounds) {
  if(!font || !text || !length || advance<=0 || advance>8192)return false;
  RenFontMetrics metrics=ren_font_metrics(font);
  float left=0,top=0,right=(float)advance,bottom=(float)metrics.height;
  const RenCluster *cluster=NULL;RenGlyph ascii={0};
  bool fast=length==1 && (uint8_t)text[0]>=32 && (uint8_t)text[0]<127;
  unsigned count=1;float intrinsic;
  if(fast){ascii=ren_font_glyph(font,(uint8_t)text[0],0);intrinsic=(float)advance;}
  else {
    cluster=ren_font_cluster(font,text,length);if(!cluster)return false;
    if(cluster->missing) {
      if(paint)diagnostic(font,advance,x,y,color);
    }
    count=cluster->run.count;intrinsic=cluster->run.advance;
  }
  /* A snapped monospace cell may be less than a pixel below the outline's
   * fractional advance. Preserve that ink, as the scalar path does. Compress
   * a genuinely wider cluster to its recorded span; never advance its neighbor. */
  float scale=intrinsic>(float)advance+1 ? (float)advance/intrinsic : 1;
  float shift=intrinsic>0 && scale==1 ? ((float)advance-intrinsic)/2 : 0;
  for(unsigned i=0;i<count;i++) {
    RenGlyph glyph=ascii;float px=0,py=0;
    if(!fast) {
      px=cluster->run.glyphs[i].x*scale;py=cluster->run.glyphs[i].y;
      int origin=(int)floorf(px);int phase=(int)((px-(float)origin)*REN_GLYPH_PHASES);
      if(phase<0)phase=0;if(phase>=REN_GLYPH_PHASES)phase=REN_GLYPH_PHASES-1;
      if(!ren_font_glyph_id(font,cluster->face,cluster->run.glyphs[i].id,phase,&glyph))return false;
      px=(float)origin+shift;
    }
    int w=glyph.x1-glyph.x0,h=glyph.y1-glyph.y0;
    if(w && h) {
      float x0=px+glyph.xoff*scale,y0=py+glyph.yoff;
      if(x0<left)left=x0;if(y0<top)top=y0;
      if(x0+(float)w*scale>right)right=x0+(float)w*scale;
      if(y0+(float)h>bottom)bottom=y0+(float)h;
      if(paint)ren_draw_glyph_intensity(glyph,(float)x+px,(float)y+py,scale,color,intensity);
    }
  }
  if(metrics.style&REN_STYLE_UNDERLINE) {
    int line_y=metrics.height-metrics.underline;
    if((float)line_y<top)top=(float)line_y;
    if(paint)ren_draw_rect((RenRect){x,y+line_y,advance,metrics.underline},color);
  }
  if(metrics.style&REN_STYLE_STRIKETHROUGH) {
    int line_y=metrics.baseline-metrics.height/6;
    if((float)line_y<top)top=(float)line_y;
    if((float)(line_y+metrics.underline)>bottom)bottom=(float)(line_y+metrics.underline);
    if(paint)ren_draw_rect((RenRect){x,y+line_y,advance,metrics.underline},color);
  }
  if(bounds)*bounds=(RenRect){(int)floorf(left),(int)floorf(top),(int)ceilf(right)-(int)floorf(left),(int)ceilf(bottom)-(int)floorf(top)};
  return true;
}
bool ren_get_cluster_bounds(RenFont *font,const char *text,size_t length,int advance,RenRect *bounds) {
  if(!cluster_shaping) {
    if(!text || !length || length>FONT_SHAPE_BYTES || !bounds)return false;
    char legacy[FONT_SHAPE_BYTES+1];memcpy(legacy,text,length);legacy[length]=0;
    *bounds=ren_get_text_bounds(font,legacy);return true;
  }
  return layout(font,text,length,advance,false,0,0,(RenColor){0},255,bounds);
}
void ren_draw_cluster_intensity(RenFont *font,const char *text,size_t length,int x,int y,int advance,RenColor color,uint8_t intensity) {
  if(!cluster_shaping && text && length && length<=FONT_SHAPE_BYTES) {
    char legacy[FONT_SHAPE_BYTES+1];memcpy(legacy,text,length);legacy[length]=0;
    ren_draw_text(font,legacy,x,y,color);return;
  }
  if(font && text && length==1 && (uint8_t)text[0]>=32 && (uint8_t)text[0]<127
    && !(ren_font_metrics(font).style&(REN_STYLE_UNDERLINE|REN_STYLE_STRIKETHROUGH))) {
    char scalar[2]={text[0],0};ren_draw_text(font,scalar,x,y,color);return;
  }
  if(!layout(font,text,length,advance,true,x,y,color,intensity,NULL))diagnostic(font,advance,x,y,color);
}
void ren_draw_cluster(RenFont *font,const char *text,size_t length,int x,int y,int advance,RenColor color) {
  ren_draw_cluster_intensity(font,text,length,x,y,advance,color,255);
}
