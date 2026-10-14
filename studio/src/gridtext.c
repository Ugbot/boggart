#include "renderer.h"
#include "btunicode.h"
#include <limits.h>
#define GRID_MAX_PIXELS 100000000
static int cell_width(RenFont *font) {
  int width=ren_get_font_width(font,"0");return width>0 ? width : 1;
}
int ren_get_grid_width(RenFont *font,const char *text,size_t length) {
  if(!font || (!text && length))return -1;
  if(!length)return 0;
  int cells=btunicode_text_width(text,length,true),cw=cell_width(font);
  return cells>GRID_MAX_PIXELS/cw ? -1 : cells*cw;
}
bool ren_get_grid_bounds(RenFont *font,const char *text,size_t length,RenRect *bounds) {
  if(!bounds)return false;
  int advance=ren_get_grid_width(font,text,length);if(advance<0)return false;
  int left=0,top=0,right=advance,bottom=ren_get_font_height(font),pen=0,cw=cell_width(font);
  for(size_t p=0;p<length;) {
    btunicode_text_cluster cluster;p+=btunicode_text_next(text+p,length-p,true,&cluster);
    if(!cluster.width)continue;
    RenRect ink;if(!ren_get_cluster_bounds(font,cluster.text,cluster.length,(int)cluster.width*cw,&ink))return false;
    if(pen+ink.x<left)left=pen+ink.x;if(ink.y<top)top=ink.y;
    if(pen+ink.x+ink.width>right)right=pen+ink.x+ink.width;
    if(ink.y+ink.height>bottom)bottom=ink.y+ink.height;
    pen+=(int)cluster.width*cw;
  }
  *bounds=(RenRect){left,top,right-left,bottom-top};return true;
}
void ren_draw_grid(RenFont *font,const char *text,size_t length,int x,int y,RenColor color) {
  if(ren_get_grid_width(font,text,length)<0)return;
  int cw=cell_width(font),pen=x;
  for(size_t p=0;p<length;) {
    btunicode_text_cluster cluster;p+=btunicode_text_next(text+p,length-p,true,&cluster);
    if(!cluster.width)continue;
    int advance=(int)cluster.width*cw;
    ren_draw_cluster(font,cluster.text,cluster.length,pen,y,advance,color);pen+=advance;
  }
}
