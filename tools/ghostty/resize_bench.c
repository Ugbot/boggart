/* Original optional C-API benchmark. Neither product links this harness. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#endif
#ifdef BMUX_GHOSTTY
#include <ghostty/vt.h>
typedef GhosttyTerminal terminal;
#else
#include "bterm_internal.h"
typedef bterm *terminal;
#endif
#define MAX_STEPS 16
#define MAX_FEED (1024u*1024u)
static void die(const char *why) { fprintf(stderr,"resize bench: %s\n",why); exit(2); }
static unsigned number(const char *s,unsigned max,bool zero) {
  char *end; if (!s[0] || s[0]<'0' || s[0]>'9') die("invalid number");
  unsigned long n=strtoul(s,&end,10);
  if (*end || n>max || (!zero && !n)) die("number out of range"); return (unsigned)n;
}
static uint64_t now(void) {
#ifdef __APPLE__
  static mach_timebase_info_data_t scale;
  if (!scale.denom && mach_timebase_info(&scale))die("clock scale failed");
  uint64_t ticks=mach_absolute_time();
  return (ticks/scale.denom)*scale.numer+(ticks%scale.denom)*scale.numer/scale.denom;
#else
  struct timespec t; if (clock_gettime(CLOCK_MONOTONIC,&t)) die("clock failed");
  return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
#endif
}
static uint64_t peak_rss(void) {
  struct rusage r; if (getrusage(RUSAGE_SELF,&r)) die("RSS query failed");
#ifdef __APPLE__
  return (uint64_t)r.ru_maxrss;
#else
  return (uint64_t)r.ru_maxrss*1024;
#endif
}
static uint64_t digest;
static void hash(uint64_t v) { for(unsigned i=0;i<8;i++) { digest^=(v>>(i*8))&255; digest*=UINT64_C(1099511628211); } }
#ifdef BMUX_GHOSTTY
static void success(GhosttyResult r) { if (r!=GHOSTTY_SUCCESS) die("SDK call failed"); }
static terminal create(unsigned cols,unsigned rows,const uint8_t *feed,size_t n) {
  terminal t; success(ghostty_terminal_new(NULL,&t,(uint16_t)cols,(uint16_t)rows));
  size_t history=2000; success(ghostty_terminal_set(t,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,&history));
  ghostty_terminal_vt_write(t,(const uint8_t *)"\033[?2027h",8);
  ghostty_terminal_vt_write(t,feed,n); return t;
}
static void resize(terminal t,unsigned cols,unsigned rows) { success(ghostty_terminal_resize(t,(uint16_t)cols,(uint16_t)rows,0,0)); }
static void destroy(terminal t) { ghostty_terminal_free(t); }
static uint32_t color(GhosttyStyleColor c) {
  if(c.tag==GHOSTTY_STYLE_COLOR_NONE)return 0;
  if(c.tag==GHOSTTY_STYLE_COLOR_PALETTE)return 0x01000000u|c.value.palette;
  if(c.tag==GHOSTTY_STYLE_COLOR_RGB)return 0x02000000u|((uint32_t)c.value.rgb.r<<16)|((uint32_t)c.value.rgb.g<<8)|c.value.rgb.b;
  die("unknown color"); return 0;
}
static void hash_rows(terminal t,uint16_t cols,size_t count,GhosttyPointTag tag) {
  for(size_t y=0;y<count;y++) {
    GhosttyPoint p={0}; p.tag=tag; p.value.coordinate.y=(uint32_t)y;
    GhosttyGridRef ref; GhosttyRow row; bool wrapped;
    success(ghostty_terminal_grid_ref(t,p,&ref)); success(ghostty_grid_ref_row(&ref,&row));
    success(ghostty_row_get(row,GHOSTTY_ROW_DATA_WRAP,&wrapped)); hash(wrapped);
    for(uint16_t x=0;x<cols;x++) {
      p.value.coordinate.x=x; success(ghostty_terminal_grid_ref(t,p,&ref));
      GhosttyCell cell; GhosttyCellWide wide; bool protected_cell;
      success(ghostty_grid_ref_cell(&ref,&cell)); success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_WIDE,&wide));
      success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_PROTECTED,&protected_cell));
      hash(wide==GHOSTTY_CELL_WIDE_WIDE ? 2 : wide==GHOSTTY_CELL_WIDE_SPACER_TAIL ? 0 : 1);
      hash(wide==GHOSTTY_CELL_WIDE_SPACER_HEAD); hash(protected_cell);
      GhosttyStyle s=GHOSTTY_INIT_SIZED(GhosttyStyle); success(ghostty_grid_ref_style(&ref,&s));
      GhosttyCellContentTag content; success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_CONTENT_TAG,&content));
      if(content==GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
        s.bg_color.tag=GHOSTTY_STYLE_COLOR_PALETTE; success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_COLOR_PALETTE,&s.bg_color.value.palette));
      } else if(content==GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
        s.bg_color.tag=GHOSTTY_STYLE_COLOR_RGB; success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_COLOR_RGB,&s.bg_color.value.rgb));
      }
      hash(color(s.fg_color)); hash(color(s.bg_color)); hash(color(s.underline_color));
      hash((s.bold ? 1u:0)|(s.italic ? 2u:0)|(s.faint ? 4u:0)|(s.blink ? 8u:0)|(s.inverse ? 16u:0)|(s.invisible ? 32u:0)|(s.strikethrough ? 64u:0)|(s.overline ? 128u:0)|((unsigned)s.underline<<8));
      uint32_t cps[65]; size_t n; success(ghostty_grid_ref_graphemes(&ref,cps,65,&n)); hash(n);
      for(size_t i=0;i<n;i++)hash(cps[i]);
      uint8_t uri[4096]; success(ghostty_grid_ref_hyperlink_uri(&ref,uri,sizeof uri,&n)); hash(n);
      for(size_t i=0;i<n;i++)hash(uri[i]);
    }
  }
}
static uint64_t state(terminal t) {
  uint16_t cols,rows,x,y; size_t history; bool pending; GhosttyTerminalScreen active;
  success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_COLS,&cols)); success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_ROWS,&rows));
  success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_CURSOR_X,&x)); success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y));
  success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,&history)); success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP,&pending));
  success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,&active));
  digest=UINT64_C(14695981039346656037); hash(cols); hash(rows); hash(x); hash(y); hash(pending); hash(active==GHOSTTY_TERMINAL_SCREEN_ALTERNATE); hash(history);
  hash_rows(t,cols,history,GHOSTTY_POINT_TAG_HISTORY); hash_rows(t,cols,rows,GHOSTTY_POINT_TAG_ACTIVE); return digest;
}
static void memory(terminal t) {
  GhosttyTerminalMemoryUsage m=GHOSTTY_INIT_SIZED(GhosttyTerminalMemoryUsage);
  success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_MEMORY_USAGE,&m));
  printf("{\"screen_resident_bytes\":%llu,\"screen_virtual_bytes\":%llu,\"pages\":%llu}",
    (unsigned long long)(m.primary_resident_bytes+m.alternate_resident_bytes),
    (unsigned long long)(m.primary_virtual_bytes+m.alternate_virtual_bytes),(unsigned long long)(m.primary_pages+m.alternate_pages));
}
#else
static terminal create(unsigned cols,unsigned rows,const uint8_t *feed,size_t n) {
  terminal t=bterm_create(cols,rows,2000,NULL,NULL); if(!t || !bterm_feed(t,feed,n))die("native create/feed failed"); return t;
}
static void resize(terminal t,unsigned cols,unsigned rows) { if(!bterm_resize(t,cols,rows))die("native resize failed"); }
static void destroy(terminal t) { bterm_destroy(t); }
static uint64_t state(terminal t) {
  const lpage_screen *s=bterm_screen(t); bterm_status status=bterm_state(t);
  size_t cols=lpage_columns(s),rows=lpage_rows(s),history=lpage_history_count(s);
  digest=UINT64_C(14695981039346656037); hash(cols); hash(rows); hash(status.x); hash(status.y); hash(status.pending_wrap); hash(status.alternate); hash(history);
  for(size_t y=0;y<history+rows;y++) {
    const lpage_row *row=y<history ? lpage_history(s,y) : lpage_visible(s,y-history); hash(row->wrapped);
    for(size_t x=0;x<cols;x++) {
      const lpage_cell *c=&row->cells[x]; hash(c->width); hash((c->flags&LP_CELL_WIDE_HEAD)!=0); hash((c->flags&LP_CELL_PROTECTED)!=0);
      const lpage_style *style=bterm_style(t,c->style); hash(style->fg); hash(style->bg); hash(style->underline); hash(style->attrs);
      lgrapheme_value g=lpage_grapheme(s,c); hash(g.length); for(size_t i=0;i<g.length;i++)hash(g.codepoints[i]);
      const llink_value *link=bterm_link(t,c->hyperlink); size_t n=link ? link->uri_length : 0; hash(n);
      for(size_t i=0;i<n;i++)hash((uint8_t)link->uri[i]);
    }
  }
  return digest;
}
static void memory(terminal t) {
  size_t bytes=0,pages=0;
  for(unsigned i=0;i<2;i++)if(t->buffers[i].screen) {
    lpage_stats m=lpage_usage(t->buffers[i].screen); bytes+=m.bytes; pages+=m.pages;
  }
  printf("{\"screen_allocated_bytes\":%zu,\"pages\":%zu}",bytes,pages);
}
#endif
int main(int argc,char **argv) {
  if(argc<8 || (argc-6)%2 || (argc-6)/2>MAX_STEPS)die("usage: samples warmups cols rows feed-file [cols rows]...");
  unsigned samples=number(argv[1],10000,false),warmups=number(argv[2],1000,true);
  unsigned cols=number(argv[3],4096,false),rows=number(argv[4],4096,false),steps=(unsigned)(argc-6)/2;
  unsigned widths[MAX_STEPS],heights[MAX_STEPS];
  for(unsigned i=0;i<steps;i++) { widths[i]=number(argv[6+2*i],4096,false); heights[i]=number(argv[7+2*i],4096,false); }
  FILE *f=fopen(argv[5],"rb"); if(!f || fseek(f,0,SEEK_END))die("feed read failed");
  long length=ftell(f); if(length<0 || (unsigned long)length>MAX_FEED || fseek(f,0,SEEK_SET))die("feed size out of range");
  uint8_t *feed=malloc(length ? (size_t)length : 1); if(!feed || fread(feed,1,(size_t)length,f)!=(size_t)length)die("feed read failed"); fclose(f);
  uint64_t clocks[128]; for(unsigned i=0;i<128;i++) { uint64_t start=now(); clocks[i]=now()-start; }
  uint64_t initial_rss=peak_rss();
  /* Verification walks run once, before warmup, outside all timed samples. */
  terminal t=create(cols,rows,feed,(size_t)length); printf("{\"states\":[\"%016llx\"",(unsigned long long)state(t));
  uint64_t states[MAX_STEPS];
  printf("],\"memory\":["); memory(t);
  for(unsigned i=0;i<steps;i++) { resize(t,widths[i],heights[i]); states[i]=state(t); putchar(','); memory(t); } destroy(t);
  printf("],\"resized_states\":["); for(unsigned i=0;i<steps;i++)printf("%s\"%016llx\"",i ? "," : "",(unsigned long long)states[i]);
  printf("],\"timings_ns\":[");
  for(unsigned sample=0;sample<samples+warmups;sample++) {
    t=create(cols,rows,feed,(size_t)length); uint64_t ns[MAX_STEPS];
    for(unsigned i=0;i<steps;i++) { uint64_t start=now(); resize(t,widths[i],heights[i]); ns[i]=now()-start; }
    destroy(t);
    if(sample>=warmups) { printf("%s[",sample>warmups ? "," : ""); for(unsigned i=0;i<steps;i++)printf("%s%llu",i ? "," : "",(unsigned long long)ns[i]); putchar(']'); }
  }
  printf("],\"clock_probe_ns\":["); for(unsigned i=0;i<128;i++)printf("%s%llu",i ? "," : "",(unsigned long long)clocks[i]);
  printf("],\"initial_peak_rss_bytes\":%llu,\"peak_rss_bytes\":%llu}\n",(unsigned long long)initial_rss,(unsigned long long)peak_rss()); free(feed); return 0;
}
