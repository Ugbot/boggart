#include "termrender.h"
static RenFont *cell_font(RenFont *font,const tg_cell *cell) {
  unsigned style=0;
  if(cell->style.attrs&LP_BOLD)style|=REN_STYLE_BOLD;
  if(cell->style.attrs&LP_ITALIC)style|=REN_STYLE_ITALIC;
  return ren_get_font_variant(font,style);
}
bool tg_measure(const tg_row *row,RenFont *font,int cw,int ch,RenRect *bounds) {
  int left=0,right=(int)row->columns*cw,top=ch<3 ? ch-3 : 0,bottom=ch;
  for(uint32_t i=0;i<row->columns;i++) {
    const tg_cell *cell=&row->cells[i];
    if(cell->width && cell->length) {
      RenFont *variant=cell_font(font,cell);if(!variant)return false;
      RenRect ink;
      if(!ren_get_cluster_bounds(variant,tg_text(row,cell),cell->length,cell->width*cw,&ink))return false;
      int x=(int)i*cw+ink.x,end=x+ink.width;
      if(x<left)left=x;if(end>right)right=end;
      if(ink.y<top)top=ink.y;if(ink.y+ink.height>bottom)bottom=ink.y+ink.height;
    }
  }
  *bounds=(RenRect){left,top,right-left+1,bottom-top};return true;
}
static RenColor resolve(uint32_t value,const tg_theme *theme,bool bold,RenColor fallback) {
  if(!value)return fallback;
  if(value&LP_COLOR_RGB)return (RenColor){.r=(uint8_t)(value>>16),.g=(uint8_t)(value>>8),.b=(uint8_t)value,.a=255};
  unsigned index=value&255;
  if(index<16)return theme->palette[bold && index<8 ? index+8 : index];
  if(index>=232){uint8_t level=(uint8_t)(8+(index-232)*10);return (RenColor){.r=level,.g=level,.b=level,.a=255};}
  static const uint8_t cube[]={0,95,135,175,215,255};unsigned n=index-16;
  return (RenColor){.r=cube[n/36],.g=cube[n/6%6],.b=cube[n%6],.a=255};
}
static void colors(const tg_cell *cell,const tg_theme *theme,RenColor *fg,RenColor *bg,RenColor *line) {
  bool bold=(cell->style.attrs&LP_BOLD)!=0;
  *fg=resolve(cell->style.fg,theme,bold,bold ? theme->palette[15] : theme->foreground);
  *bg=resolve(cell->style.bg,theme,false,(RenColor){0});
  if(cell->style.attrs&LP_INVERSE){RenColor previous=*fg;*fg=cell->style.bg ? *bg : theme->background;*bg=previous;}
  if(cell->style.attrs&LP_FAINT){fg->r/=2;fg->g/=2;fg->b/=2;}
  *line=resolve(cell->style.underline,theme,false,*fg);
}
void tg_draw(const tg_row *row,RenFont *font,const tg_theme *theme,double x,int y,int cw,int ch) {
  for(uint32_t i=0;i<row->columns;i++){
    RenColor fg,bg,line;colors(&row->cells[i],theme,&fg,&bg,&line);
    if(bg.a)ren_draw_rect((RenRect){(int)(x+(double)i*cw),y,cw,ch},bg);
  }
  for(uint32_t i=0;i<row->columns;i++){
    const tg_cell *cell=&row->cells[i];if(!cell->width)continue;
    RenColor fg,bg,line;colors(cell,theme,&fg,&bg,&line);int px=(int)(x+(double)i*cw),width=cell->width*cw;
    if(cell->length && !(cell->style.attrs&LP_INVISIBLE)){
      RenFont *variant=cell_font(font,cell);
      if(variant)ren_draw_cluster(variant,tg_text(row,cell),cell->length,px,y,width,fg);
    }
    unsigned underline=(cell->style.attrs&LP_UNDERLINE_MASK)>>LP_UNDERLINE_SHIFT;
    if(underline){
      if(underline==3){for(int dx=0;dx<width;dx++){int wave=dx%4-2;if(wave<0)wave=-wave;ren_draw_rect((RenRect){px+dx,y+ch-3+wave,1,1},line);}}
      else if(underline==4 || underline==5){int span=underline==4 ? 1 : 3;for(int dx=0;dx<width;dx+=span+1)ren_draw_rect((RenRect){px+dx,y+ch-1,span<width-dx ? span : width-dx,1},line);}
      else ren_draw_rect((RenRect){px,y+ch-1,width,1},line);
      if(underline==2)ren_draw_rect((RenRect){px,y+ch-3,width,1},line);
    }
    if(cell->style.attrs&LP_STRIKE)ren_draw_rect((RenRect){px,y+ch/2,width,1},fg);
    if(cell->style.attrs&LP_OVERLINE)ren_draw_rect((RenRect){px,y,width,1},fg);
  }
}
