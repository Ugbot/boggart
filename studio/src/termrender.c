#include "termrender.h"
RenRect tg_measure(const tg_row *row,RenFont *font,int cw,int ch) {
  int width=(int)row->columns*cw;
  for(uint32_t i=0;i<row->columns;i++) {
    const tg_cell *cell=&row->cells[i];
    if(cell->width && cell->length) {
      int end=(int)i*cw+ren_get_font_width(font,tg_text(row,cell));
      if(end>width)width=end;
    }
  }
  int top=ch<3 ? ch-3 : 0,height=ren_get_font_height(font);
  if(height<ch)height=ch;
  return (RenRect){0,top,width+1,height-top};
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
    if(cell->length && !(cell->style.attrs&LP_INVISIBLE))ren_draw_text(font,tg_text(row,cell),px,y,fg);
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
