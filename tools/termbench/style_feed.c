#define _POSIX_C_SOURCE 200809L
#include "bterm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static uint64_t now(void) { struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t)) abort(); return (uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec; }
static uint64_t mix(uint64_t h,uint64_t v) { return (h^v)*UINT64_C(1099511628211); }
int main(int argc,char **argv) {
  if(argc!=3) return 2;
  const char *unit=!strcmp(argv[1],"plain") ? "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij\r\n" :
    !strcmp(argv[1],"sgr") ? "\033[31mred\033[32;1mgreen\033[0mplain\033[38;2;3;6;9mrgb\033[0m|\r\n" :
    "\033[31mé日👩‍💻🇬🇧❤️|\033[0m\r\n";
  size_t unit_bytes=strlen(unit),length=(1048576/unit_bytes)*unit_bytes;
  unsigned samples=(unsigned)strtoul(argv[2],NULL,10);
  unsigned char *bytes=malloc(length); if(!bytes) return 3;
  for(size_t i=0;i<length;i+=unit_bytes) memcpy(bytes+i,unit,unit_bytes);
  for(unsigned sample=0;sample<samples;sample++) {
    bterm *t=bterm_create(80,24,1000,NULL,NULL); if(!t) return 4;
    uint64_t start=now(); if(!bterm_feed(t,bytes,length)) return 5; uint64_t elapsed=now()-start;
    const lpage_screen *s=bterm_screen(t); uint64_t digest=UINT64_C(14695981039346656037);
    for(size_t y=0;y<lpage_history_count(s)+lpage_rows(s);y++) {
      const lpage_row *r=y<lpage_history_count(s) ? lpage_history(s,y) : lpage_visible(s,y-lpage_history_count(s));
      digest=mix(digest,r->wrapped);
      for(size_t x=0;x<r->columns;x++) {
        const lpage_cell *c=&r->cells[x]; lgrapheme_value g=lpage_grapheme(s,c);
        digest=mix(digest,c->width); digest=mix(digest,c->flags);
        for(size_t i=0;i<g.length;i++) digest=mix(digest,g.codepoints[i]);
        const lpage_style *style=lstyle_get(lpage_styles((lpage_screen *)s),c->style);
        digest=mix(digest,style->fg); digest=mix(digest,style->bg); digest=mix(digest,style->underline); digest=mix(digest,style->attrs);
      }
    }
    bterm_status status=bterm_state(t); digest=mix(digest,status.x); digest=mix(digest,status.y); digest=mix(digest,status.pending_wrap);
    printf("%s %zu %llu %zu %llu\n",argv[1],length,(unsigned long long)elapsed,lpage_usage(s).bytes,(unsigned long long)digest);
    bterm_destroy(t);
  }
  free(bytes); return 0;
}
