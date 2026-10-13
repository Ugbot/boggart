#include "bterm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static void feed(bterm *t,const char *s) { CHECK(bterm_feed(t,(const uint8_t *)s,strlen(s))); }
static uint32_t id(bterm *t,size_t y,size_t x) { return lpage_get(bterm_screen(t),y,x)->hyperlink; }
static bool text(const char *p,size_t n,const char *expected) { return n==strlen(expected) && (!n || !memcmp(p,expected,n)); }
static void uri(bterm *t,uint32_t n,const char *expected) { const llink_value *v=bterm_link(t,n); CHECK(v && text(v->uri,v->uri_length,expected)); }
static void pool_test(void) {
  llink_pool *p=llink_create(); CHECK(p && !llink_count(p)); uint32_t a,b,c;
  llink_value empty={0}; CHECK(llink_acquire(p,&empty,&a) && a==0 && !llink_get(p,0));
  CHECK(llink_retain(p,0)); llink_release(p,0); CHECK(!llink_retain(p,1));
  char key[]="key", url[]="https://example.com";
  llink_value v={key,url,3,19}; CHECK(llink_acquire(p,&v,&a));
  key[0]='z'; url[8]='z'; CHECK(text(llink_get(p,a)->key,3,"key") && text(llink_get(p,a)->uri,19,"https://example.com"));
  key[0]='k'; url[8]='e'; CHECK(llink_acquire(p,&v,&b) && a==b && llink_refs(p,a)==2);
  llink_value changed={"key","https://other.com",3,17}; CHECK(llink_acquire(p,&changed,&c) && c!=a);
  CHECK(llink_count(p)==2 && text(llink_get(p,a)->uri,19,"https://example.com"));
  llink_release(p,a); llink_release(p,b); CHECK(!llink_get(p,a)); llink_release(p,c); CHECK(!llink_count(p));
  v.key_length=0; CHECK(llink_acquire(p,&v,&a)); CHECK(llink_acquire(p,&v,&b) && a!=b);
  CHECK(llink_acquire(p,llink_get(p,a),&c) && c!=a && c!=b);
  llink_release(p,a); llink_release(p,b); llink_release(p,c);
  uint32_t ids[200];
  for(size_t i=0;i<200;i++) {
    /* The sixteenth acquire grows entries while source borrows that array. */
    const llink_value *source=i==15 ? llink_get(p,ids[0]) : &v;
    CHECK(llink_acquire(p,source,&ids[i]));
  }
  for(size_t i=0;i<200;i++) { CHECK(text(llink_get(p,ids[i])->uri,19,"https://example.com")); llink_release(p,ids[i]); }
  CHECK(!llink_count(p)); size_t bytes=llink_bytes(p);
  for(size_t i=0;i<10000;i++) { CHECK(llink_acquire(p,&v,&a)); llink_release(p,a); }
  CHECK(llink_bytes(p)==bytes);
  v.uri_length=4097; CHECK(!llink_acquire(p,&v,&a)); v.uri_length=19; v.key_length=257; CHECK(!llink_acquire(p,&v,&a));
  llink_destroy(p);
}
static void storage_test(void) {
  lpage_screen *s=lpage_create(4,2,1); CHECK(s); llink_pool *p=lpage_links(s);
  llink_value v={"id","https://example.com",2,19}; uint32_t n;
  CHECK(llink_acquire(p,&v,&n)); CHECK(lpage_put(s,0,0,(lpage_cell){'A',0,n,1,0,0})); llink_release(p,n);
  CHECK(llink_refs(p,n)==1); lstyle_pool *styles=lpage_styles(s); uint32_t style;
  lpage_style red={LP_COLOR_INDEXED|1,0,0,0}; CHECK(lstyle_acquire(styles,&red,&style));
  CHECK(!lpage_put(s,0,0,(lpage_cell){'B',style,UINT32_MAX,1,0,0}));
  CHECK(lpage_get(s,0,0)->codepoint=='A' && lstyle_refs(styles,style)==1 && llink_refs(p,n)==1);
  lstyle_release(styles,style);
  CHECK(lpage_insert_cells(s,0,0,1,0)); CHECK(lpage_get(s,0,1)->hyperlink==n && llink_refs(p,n)==1);
  CHECK(lpage_delete_cells(s,0,0,1,0)); CHECK(lpage_get(s,0,0)->hyperlink==n && llink_refs(p,n)==1);
  CHECK(lpage_scroll(s,0,1,1,true,0)); CHECK(lpage_history(s,0)->cells[0].hyperlink==n && llink_refs(p,n)==1);
  CHECK(lpage_scroll(s,0,1,1,true,0)); CHECK(!llink_get(p,n) && !lpage_usage(s).links);
  size_t warm=0;
  for(size_t i=0;i<10000;i++) {
    char url[64]; snprintf(url,sizeof url,"https://example.com/%06zu",i);
    llink_value value={NULL,url,0,strlen(url)};
    CHECK(llink_acquire(p,&value,&n)); CHECK(lpage_put(s,1,0,(lpage_cell){'Z',0,n,1,0,0})); llink_release(p,n);
    CHECK(lpage_scroll(s,0,1,1,true,0));
    CHECK(lpage_usage(s).links<=2);
    if(i==10) warm=lpage_usage(s).bytes;
    if(i>10) CHECK(lpage_usage(s).bytes==warm);
  }
  lpage_clear_history(s); CHECK(lpage_usage(s).links==1); CHECK(lpage_erase(s,0,0,4,0)); CHECK(!lpage_usage(s).links);
  lpage_destroy(s);
}
static void terminal_test(void) {
  bterm *t=bterm_create(12,2,2,NULL,NULL); CHECK(t);
  feed(t,"\033]8;id=key;https://example.com\aAB\033]8;;\aC");
  uint32_t first=id(t,0,0); CHECK(first && id(t,0,1)==first && id(t,0,2)==0); uri(t,first,"https://example.com");
  feed(t,"\033]8;id=key;https://example.com\aD\033]8;;\a"); CHECK(id(t,0,3)==first);
  feed(t,"\033]8;id=key;https://other.com\aE\033]8;;\a"); CHECK(id(t,0,4)!=first); uri(t,id(t,0,4),"https://other.com");
  feed(t,"\033]8;;https://example.com\aF\033]8;;\a\033]8;;https://example.com\aG\033]8;;\a");
  CHECK(id(t,0,5)!=id(t,0,6) && id(t,0,5)!=first);
  feed(t,"\033]8;;https://pending.com\a\033]8;;relative\aH\033]8;;\a"); uri(t,id(t,0,7),"https://pending.com");
  feed(t,"\033]8;;https://pending.com\a\033[?1049hI\033]8;id=alt;https://alt.com\aJ\033[?1049lK");
  CHECK(id(t,0,8)==0); uri(t,first,"https://example.com");
  feed(t,"\033[?47h"); CHECK(id(t,0,0)==0); uri(t,id(t,0,1),"https://alt.com"); feed(t,"L"); CHECK(id(t,0,2)==0);
  feed(t,"\033[?47l\033[2K"); CHECK(lpage_usage(bterm_screen(t)).links==0);
  feed(t,"\033]8;;https://save.com\aA\0337B\0338C"); CHECK(id(t,0,10)==0);
  feed(t,"\033[?1049h\033]8;;https://active.com\a\033c"); CHECK(!bterm_state(t).alternate && !lpage_usage(bterm_screen(t)).links);
  feed(t,"\033[?47h"); CHECK(!lpage_usage(bterm_screen(t)).links); bterm_destroy(t);
  t=bterm_create(3,2,1,NULL,NULL); CHECK(t);
  feed(t,"\033]8;id=wrapped;https://wrap.com\aabcdefghi\033]8;;\a");
  const lpage_screen *s=bterm_screen(t); CHECK(lpage_history_count(s)==1);
  uint32_t link=lpage_history(s,0)->cells[0].hyperlink;
  for(size_t x=0;x<3;x++) CHECK(lpage_history(s,0)->cells[x].hyperlink==link && id(t,0,x)==link && id(t,1,x)==link);
  feed(t,"\033[2J\033[3J"); CHECK(!lpage_usage(bterm_screen(t)).links);
  bterm_destroy(t);
}
int main(void) { pool_test(); storage_test(); terminal_test(); puts("Links: identity, cell/history ownership, reclamation, edits and alternate screens passed"); return 0; }
