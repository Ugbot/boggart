#include "rencache.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "btunicode.h"
#define CHECK(c) do{if(!(c)){fprintf(stderr,"line %d: %s\n",__LINE__,#c);exit(1);}}while(0)
static bool allocation_fails;
static unsigned updates,draws,frees;
static unsigned grid_draws;
static unsigned draws_by_y[240];
static void *cache_realloc(void *p,size_t n){return allocation_fails ? NULL : realloc(p,n);}
#define realloc cache_realloc
#include "../../studio/src/rencache.c"
#undef realloc
void ren_get_size(int *w,int *h){*w=320;*h=240;}
void ren_reset_glyph_stats(void){}
RenGlyphStats ren_glyph_stats(void){return (RenGlyphStats){0};}
void ren_set_clip_rect(RenRect r){(void)r;}
void ren_update_rects(RenRect *r,int n){(void)r;CHECK(n>0);updates++;}
void ren_draw_rect(RenRect r,RenColor c){(void)r;(void)c;}
void ren_draw_line(float a,float b,float c,float d,float e,RenColor f){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;}
void ren_draw_image(RenImage *i,RenRect *s,RenRect *d,RenColor c){(void)i;(void)s;(void)d;(void)c;}
int ren_get_font_width(RenFont *f,const char *s){(void)f;return (int)strlen(s)*8;}
int ren_get_font_height(RenFont *f){(void)f;return 16;}
int ren_get_font_tab_width(RenFont *f){(void)f;return 8;}
void ren_set_font_tab_width(RenFont *f,int n){(void)f;(void)n;}
int ren_draw_text(RenFont *f,const char *s,int x,int y,RenColor c){(void)f;(void)y;(void)c;return x+(int)strlen(s)*8;}
int ren_get_grid_width(RenFont *f,const char *s,size_t n){(void)f;return btunicode_text_width(s,n,true)*8;}
bool ren_get_grid_bounds(RenFont *f,const char *s,size_t n,RenRect *bounds){*bounds=(RenRect){0,-2,ren_get_grid_width(f,s,n),18};return true;}
void ren_draw_grid(RenFont *f,const char *s,size_t n,int x,int y,RenColor c){
  (void)f;(void)x;(void)y;(void)c;CHECK(n==3 && !memcmp(s,"a\0b",3));grid_draws++;
}
void ren_free_font(RenFont *f){CHECK(f);frees++;}
void tg_draw(const tg_row *row,RenFont *font,const tg_theme *theme,double x,int y,int cw,int ch){
  (void)font;(void)theme;(void)x;(void)cw;(void)ch;
  CHECK(!strcmp(tg_text(row,&row->cells[0]),"A"));draws++;
  if(y>=0 && y<240)draws_by_y[y]++;
}
int main(void){
  bterm *t=bterm_create(4,1,0,NULL,NULL);CHECK(t);CHECK(bterm_feed(t,(const uint8_t *)"A",1));
  tg_row *row=tg_capture(t,lpage_visible(bterm_screen(t),0),4);CHECK(row);
  tg_value values[4];
  for(size_t i=0;i<4;i++){const tg_cell *c=&row->cells[i];values[i]=(tg_value){c->style,tg_text(row,c),c->length,c->width,c->flags};}
  tg_row *resolved=tg_capture_values(values,4);CHECK(resolved && tg_equal(row,resolved));tg_release(resolved);
  values[0].width=3;CHECK(!tg_capture_values(values,4));values[0].width=1;
  RenFont *font=(RenFont *)(void *)&updates;tg_theme theme={0};
  theme.foreground.r=255;theme.foreground.a=255;
  RenRect bounds={0,0,32,16};
  rencache_begin_frame();CHECK(rencache_draw_row(row,font,&theme,0,0,8,16,bounds));CHECK(row->references==2);
  rencache_end_frame();CHECK(row->references==1 && draws>0);
  /* The legacy two hash buffers converge after two initial frames. */
  rencache_begin_frame();CHECK(rencache_draw_row(row,font,&theme,0,0,8,16,bounds));rencache_end_frame();
  unsigned previous=updates;
  /* Allocation addresses may change while pixels stay identical. */
  tg_row *same=tg_capture(t,lpage_visible(bterm_screen(t),0),4);CHECK(same && same!=row);
  rencache_begin_frame();CHECK(rencache_draw_row(same,font,&theme,0,0,8,16,bounds));
  rencache_free_font(font);rencache_end_frame();
  CHECK(updates==previous && same->references==1 && frees==1);
  tg_release(same);
  /* Dirty region y=0..96 must not replay an unchanged row at y=160. */
  for(unsigned frame=0;frame<3;frame++) {
    rencache_begin_frame();rencache_set_clip_rect((RenRect){0,0,320,240});
    CHECK(rencache_draw_row(row,font,&theme,0,0,8,16,bounds));
    CHECK(rencache_draw_row(row,font,&theme,0,160,8,16,bounds));rencache_end_frame();
  }
  memset(draws_by_y,0,sizeof draws_by_y);
  rencache_begin_frame();rencache_set_clip_rect((RenRect){0,0,320,240});
  tg_theme changed=theme;changed.foreground.r=1;
  CHECK(rencache_draw_row(row,font,&changed,0,0,8,16,bounds));
  CHECK(rencache_draw_row(row,font,&theme,0,160,8,16,bounds));rencache_end_frame();
  CHECK(draws_by_y[0]>0 && draws_by_y[160]==0 && row->references==1);
  RenCacheStats stats=rencache_stats();CHECK(stats.rows_queued==2 && stats.rows_replayed==1 && stats.rows_skipped==1);
  /* Empty clips suppress replay; a later clip restores it in command order. */
  draws=0;rencache_begin_frame();rencache_invalidate();
  rencache_set_clip_rect((RenRect){0,0,0,0});
  CHECK(rencache_draw_row(row,font,&theme,0,0,8,16,bounds));
  rencache_set_clip_rect((RenRect){0,0,320,240});
  CHECK(rencache_draw_row(row,font,&theme,0,32,8,16,bounds));rencache_end_frame();
  CHECK(draws==1 && row->references==1);
  stats=rencache_stats();CHECK(stats.rows_replayed==1 && stats.rows_skipped==1);
  /* The nominal row misses the clip but its glyph overhang intersects it. */
  draws=0;rencache_begin_frame();rencache_invalidate();
  rencache_set_clip_rect((RenRect){0,90,64,6});
  CHECK(rencache_draw_row(row,font,&theme,0,100,8,16,(RenRect){0,-12,32,28}));
  rencache_end_frame();CHECK(draws==1 && row->references==1);
  /* Separate dirty regions each replay only their intersecting row. */
  for(unsigned frame=0;frame<3;frame++) {
    rencache_begin_frame();rencache_set_clip_rect((RenRect){0,0,320,240});
    for(int y=0;y<=220;y+=110)CHECK(rencache_draw_row(row,font,&theme,0,y,8,16,bounds));
    rencache_end_frame();
  }
  memset(draws_by_y,0,sizeof draws_by_y);
  rencache_begin_frame();rencache_set_clip_rect((RenRect){0,0,320,240});
  for(int y=0;y<=220;y+=110)CHECK(rencache_draw_row(row,font,y==110 ? &theme : &changed,0,y,8,16,bounds));
  rencache_end_frame();stats=rencache_stats();
  CHECK(stats.dirty_rects==2 && stats.rows_queued==3 && stats.rows_replayed==2 && stats.rows_skipped==4);
  CHECK(draws_by_y[0]==1 && draws_by_y[110]==0 && draws_by_y[220]==1 && row->references==1);
  rencache_begin_frame();rencache_set_clip_rect((RenRect){0,0,320,240});
  for(int y=0;y<=220;y+=110)CHECK(rencache_draw_row(row,font,y==110 ? &theme : &changed,0,y,8,16,bounds));
  rencache_end_frame();stats=rencache_stats();
  CHECK(!stats.dirty_rects && !stats.rows_replayed && !stats.rows_skipped && row->references==1);
  /* Failed queueing releases its retain and cannot corrupt buffer offsets. */
  int capacity=command_buf_size; command_buf_size=0; allocation_fails=true;
  CHECK(!rencache_draw_row(row,font,&theme,0,0,8,16,bounds));CHECK(row->references==1 && command_buf_idx==0);
  allocation_fails=false; command_buf_size=capacity;
  CHECK(!push_command(DRAW_ROW,INT_MAX) && command_buf_idx==0);
  char grid_text[]={'a',0,'b'};int end;
  rencache_begin_frame();rencache_set_clip_rect((RenRect){0,0,320,240});
  CHECK(rencache_draw_grid(font,grid_text,3,7,10,(RenColor){.a=255},&end) && end==23);
  memset(grid_text,'X',sizeof grid_text);rencache_end_frame();CHECK(grid_draws>0);
  unsigned before_grid=grid_draws;
  rencache_begin_frame();rencache_set_clip_rect((RenRect){0,0,320,240});
  CHECK(rencache_draw_grid(font,"a\0b",3,7,10,(RenColor){.a=255},&end));rencache_end_frame();
  CHECK(grid_draws==before_grid);
  capacity=command_buf_size;command_buf_size=0;allocation_fails=true;
  CHECK(!rencache_draw_grid(font,"a\0b",3,7,10,(RenColor){.a=255},&end));
  allocation_fails=false;command_buf_size=capacity;
  /* Borrowed source destruction and producer release do not invalidate replay. */
  rencache_begin_frame();CHECK(rencache_draw_row(row,font,&theme,8,16,8,16,bounds));
  tg_release(row);bterm_destroy(t);rencache_end_frame();
  free(command_buf);puts("row commands: retained replay, content damage, no-damage cleanup and OOM/bounds pass");return 0;
}
