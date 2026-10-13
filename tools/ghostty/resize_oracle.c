/* Original test adapter for the pinned libghostty-vt C API. Never linked into
 * either product. Output contains values, not upstream internal IDs/pointers. */
#include <ghostty/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#define MAX_FEED (1024u * 1024u)
static void fail(const char *why) { fprintf(stderr,"resize oracle: %s\n",why); exit(2); }
static void success(GhosttyResult result) { if(result!=GHOSTTY_SUCCESS)fail("VT API call failed"); }
static unsigned number(const char *s,unsigned max) {
  char *end;errno=0;if(!s[0] || s[0]<'0' || s[0]>'9')fail("invalid number");
  unsigned long n=strtoul(s,&end,10);if(errno || *end || !n || n>max)fail("number out of range");return (unsigned)n;
}
static unsigned nibble(char c) {
  if(c>='0' && c<='9')return (unsigned)(c-'0');
  if(c>='a' && c<='f')return (unsigned)(c-'a'+10);
  if(c>='A' && c<='F')return (unsigned)(c-'A'+10);fail("invalid hex feed");return 0;
}
static void feed(GhosttyTerminal t,const char *hex) {
  size_t n=strlen(hex);if(n%2 || n/2>MAX_FEED)fail("invalid feed length");
  uint8_t *bytes=malloc(n ? n/2 : 1);if(!bytes)fail("allocation failed");
  for(size_t i=0;i<n/2;i++)bytes[i]=(uint8_t)((nibble(hex[2*i])<<4)|nibble(hex[2*i+1]));
  ghostty_terminal_vt_write(t,bytes,n/2);free(bytes);
}
static unsigned color(GhosttyStyleColor c) {
  if(c.tag==GHOSTTY_STYLE_COLOR_NONE)return 0;
  if(c.tag==GHOSTTY_STYLE_COLOR_PALETTE)return 0x01000000u | c.value.palette;
  if(c.tag==GHOSTTY_STYLE_COLOR_RGB)return 0x02000000u | ((unsigned)c.value.rgb.r<<16) | ((unsigned)c.value.rgb.g<<8) | c.value.rgb.b;
  fail("unknown style color");return 0;
}
static void rows(GhosttyTerminal t,uint16_t columns,size_t count,GhosttyPointTag tag) {
  putchar('[');
  for(size_t y=0;y<count;y++) {
    if(y)putchar(',');GhosttyPoint point={0};point.tag=tag;point.value.coordinate.y=(uint32_t)y;
    GhosttyGridRef ref;GhosttyRow row;bool wrap;
    success(ghostty_terminal_grid_ref(t,point,&ref));success(ghostty_grid_ref_row(&ref,&row));
    success(ghostty_row_get(row,GHOSTTY_ROW_DATA_WRAP,&wrap));
    printf("{\"wrapped\":%s,\"cells\":[",wrap ? "true" : "false");
    for(uint16_t x=0;x<columns;x++) {
      if(x)putchar(',');point.value.coordinate.x=x;success(ghostty_terminal_grid_ref(t,point,&ref));
      GhosttyCell cell;GhosttyCellWide wide;bool protected_cell;
      success(ghostty_grid_ref_cell(&ref,&cell));success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_WIDE,&wide));
      success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_PROTECTED,&protected_cell));
      uint32_t cps[65];size_t length;success(ghostty_grid_ref_graphemes(&ref,cps,65,&length));
      printf("{\"cps\":[");for(size_t i=0;i<length;i++)printf("%s%u",i ? "," : "",cps[i]);
      printf("],\"width\":%u,\"head\":%s,\"protected\":%s,\"style\":[",wide==GHOSTTY_CELL_WIDE_WIDE ? 2 : wide==GHOSTTY_CELL_WIDE_SPACER_TAIL ? 0 : 1,
        wide==GHOSTTY_CELL_WIDE_SPACER_HEAD ? "true" : "false",protected_cell ? "true" : "false");
      GhosttyStyle style=GHOSTTY_INIT_SIZED(GhosttyStyle);success(ghostty_grid_ref_style(&ref,&style));
      /* Background-only cells have no style ID. Resolve their content color
       * explicitly rather than losing it through the default style lookup. */
      GhosttyCellContentTag content;success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_CONTENT_TAG,&content));
      if(content==GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
        style.bg_color.tag=GHOSTTY_STYLE_COLOR_PALETTE;
        success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_COLOR_PALETTE,&style.bg_color.value.palette));
      } else if(content==GHOSTTY_CELL_CONTENT_BG_COLOR_RGB) {
        style.bg_color.tag=GHOSTTY_STYLE_COLOR_RGB;
        success(ghostty_cell_get(cell,GHOSTTY_CELL_DATA_COLOR_RGB,&style.bg_color.value.rgb));
      }
      unsigned attrs=(style.bold ? 1u : 0) | (style.italic ? 2u : 0) | (style.faint ? 4u : 0) | (style.blink ? 8u : 0)
        | (style.inverse ? 16u : 0) | (style.invisible ? 32u : 0) | (style.strikethrough ? 64u : 0) | (style.overline ? 128u : 0) | ((unsigned)style.underline<<8);
      printf("%u,%u,%u,%u],\"uri\":[",color(style.fg_color),color(style.bg_color),color(style.underline_color),attrs);
      uint8_t uri[4096];success(ghostty_grid_ref_hyperlink_uri(&ref,uri,sizeof uri,&length));
      for(size_t i=0;i<length;i++)printf("%s%u",i ? "," : "",uri[i]);printf("]}");
    }
    printf("]}");
  }
  putchar(']');
}
static void snapshot(GhosttyTerminal t) {
  uint16_t columns,height,x,y;bool pending;size_t history;GhosttyTerminalScreen active;
  success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_COLS,&columns));success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_ROWS,&height));
  success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_CURSOR_X,&x));success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_CURSOR_Y,&y));
  success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP,&pending));success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,&history));
  success(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN,&active));
  if(history>1000000/columns || (history+height)*columns>1000000)fail("snapshot exceeds cell limit");
  printf("{\"cols\":%u,\"rows\":%u,\"x\":%u,\"y\":%u,\"pending_wrap\":%s,\"alternate\":%s,\"screen\":",columns,height,x,y,pending ? "true" : "false",active==GHOSTTY_TERMINAL_SCREEN_ALTERNATE ? "true" : "false");
  rows(t,columns,height,GHOSTTY_POINT_TAG_ACTIVE);printf(",\"scrollback\":");rows(t,columns,history,GHOSTTY_POINT_TAG_HISTORY);printf("}\n");
}
int main(int argc,char **argv) {
  if(argc<3)fail("usage: resize-oracle COLS ROWS [feed HEX | resize COLS ROWS | snapshot]...");
  uint16_t columns=(uint16_t)number(argv[1],4096),height=(uint16_t)number(argv[2],4096);
  GhosttyTerminal t;success(ghostty_terminal_new(NULL,&t,columns,height));
  size_t limit=2000;success(ghostty_terminal_set(t,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,&limit));
  /* Align the explicit Boggart Unicode mode policy before observing reflow. */
  const uint8_t unicode_mode[]={27,'[','?','2','0','2','7','h'};ghostty_terminal_vt_write(t,unicode_mode,sizeof unicode_mode);
  for(int i=3;i<argc;i++) {
    if(!strcmp(argv[i],"feed") && i+1<argc)feed(t,argv[++i]);
    else if(!strcmp(argv[i],"resize") && i+2<argc) {
      columns=(uint16_t)number(argv[++i],4096);height=(uint16_t)number(argv[++i],4096);
      success(ghostty_terminal_resize(t,columns,height,0,0));
    } else if(!strcmp(argv[i],"snapshot"))snapshot(t);
    else fail("unknown or incomplete operation");
  }
  ghostty_terminal_free(t);return 0;
}
