#include "bterm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
typedef struct { char data[32768]; size_t length, events; } capture;
static void bytes(capture *c, const void *s, size_t n) { CHECK(n <= sizeof c->data - c->length); if (n) memcpy(c->data+c->length,s,n); c->length+=n; }
static void slice(capture *c, bosc_slice s) { bytes(c,s.data,s.length); bytes(c,"|",1); }
static void event(void *ctx, const bterm_event *e) {
  capture *c=ctx; c->events++;
  char meta[128]; int n=snprintf(meta,sizeof meta,"%d:%u:%zu:%zu:%d:",e->command.type,e->command.code,e->x,e->y,e->alternate); bytes(c,meta,n);
  const bosc_command *b=&e->command;
  switch (b->type) {
    case BOSC_TITLE: case BOSC_CWD: slice(c,b->value.text); break;
    case BOSC_HYPERLINK: slice(c,b->value.link.id); slice(c,b->value.link.uri); break;
    case BOSC_NOTIFY: slice(c,b->value.notify.id); slice(c,b->value.notify.title); slice(c,b->value.notify.body); break;
    case BOSC_SHELL: bytes(c,&b->value.shell.mark,1); slice(c,b->value.shell.options); break;
    case BOSC_CLIPBOARD: bytes(c,&b->value.clipboard.query,1); slice(c,b->value.clipboard.text); break;
    default: break;
  }
  bytes(c,"\n",1);
}
static bool reply(void *ctx,const uint8_t *p,size_t n) { bytes(ctx,p,n); return true; }
static void feed(bterm *t,const char *s) { CHECK(bterm_feed(t,(const uint8_t *)s,strlen(s))); }
int main(void) {
  const char *stream="x\a\033]2;title caf\xc3\xa9\a\033]7;file:///tmp\033\\\033]8;id=test;https://example.com\a\033]8;;\a\033]9;finished\a\033]777;notify;Title;Body\a\033]133;D;12\a\033]99;i=a:d=0;one\a\033]99;i=b:d=0;other\a\033]99;i=a:p=body:e=1:d=0;Ym9keQ==\a\033]99;i=a;two\a\033]99;i=b;p=title\a\033]52;c;SGVsbG8=\a\033]52;c;?\a\033[?1049h\a";
  capture whole={0}; bterm *t=bterm_create(8,3,2,NULL,NULL); CHECK(t); bterm_set_event_sink(t,event,&whole);
  bterm_clipboard_policy(t,true,true);
  feed(t,stream); CHECK(whole.events==13); CHECK(strstr(whole.data,"a|onetwo|body|"));
  for(size_t chunk=1;chunk<=29;chunk++) {
    capture fragmented={0}; bterm *f=bterm_create(8,3,2,NULL,NULL); CHECK(f); bterm_set_event_sink(f,event,&fragmented);
    bterm_clipboard_policy(f,true,true);
    for(size_t offset=0,n=strlen(stream);offset<n;) { size_t k=n-offset<chunk?n-offset:chunk; CHECK(bterm_feed(f,(const uint8_t *)stream+offset,k)); offset+=k; }
    CHECK(fragmented.events==whole.events && fragmented.length==whole.length && !memcmp(fragmented.data,whole.data,whole.length)); bterm_destroy(f);
  }
  capture clipboard={0}; bterm *p=bterm_create(8,3,0,reply,&clipboard); CHECK(p); bterm_set_event_sink(p,event,&clipboard);
  feed(p,"\033]52;c;SGVsbG8=\a\033]52;c;?\a"); CHECK(clipboard.events==0);
  CHECK(!bterm_clipboard_reply(p,'c',true,(const uint8_t *)"Hello",5));
  bterm_clipboard_policy(p,false,true); feed(p,"\033]52;c;SGVsbG8=\a\033]52;c;?\a"); CHECK(clipboard.events==1);
  CHECK(bterm_reset(p)); feed(p,"\033c\033]52;c;SGVsbG8=\a\033]52;c;?\a"); CHECK(clipboard.events==2);
  bterm_clipboard_policy(p,true,false); feed(p,"\033]52;c;SGVsbG8=\a\033]52;c;?\a"); CHECK(clipboard.events==3);
  clipboard.length=0; CHECK(bterm_clipboard_reply(p,'p',true,(const uint8_t *)"Hello",5));
  CHECK(clipboard.length==16 && !memcmp(clipboard.data,"\033]52;p;SGVsbG8=\a",16));
  clipboard.length=0; CHECK(bterm_clipboard_reply(p,'c',false,(const uint8_t *)"a",1)); CHECK(clipboard.length==13 && !memcmp(clipboard.data,"\033]52;c;YQ==\033\\",13));
  CHECK(!bterm_clipboard_reply(p,'c',true,(const uint8_t *)"\033",1)); bterm_destroy(p);
  CHECK(bterm_reset(t)); whole.events=whole.length=0;
  char large[4020]; memset(large,'x',sizeof large); memcpy(large,"\033]99;i=big:d=0;",15); large[4018]='\a'; large[4019]=0;
  feed(t,large); feed(t,"\033]99;i=big:d=0;more\a"); feed(t,large); feed(t,"\033]99;i=big;end\a"); CHECK(whole.events==0);
  feed(t,"\033]99;i=big;new\a"); CHECK(whole.events==1);
  feed(t,"\033]99;i=reset:d=0;stale\a"); CHECK(bterm_reset(t)); feed(t,"\033]99;i=reset;fresh\a"); CHECK(whole.events==2);
  CHECK(bterm_reset(t)); whole.events=whole.length=0;
  for (unsigned i=0;i<9;i++) { char chunk[64]; snprintf(chunk,sizeof chunk,"\033]99;i=id%u:d=0;first\a",i); feed(t,chunk); }
  feed(t,"\033]99;i=id0;last\a"); CHECK(whole.events==1);
  feed(t,"\033]99;i=id8;tail\a"); feed(t,"\033]99;i=new;new\a"); CHECK(whole.events==1);
  CHECK(bterm_reset(t)); feed(t,"\033]99;i=new;new\a"); CHECK(whole.events==2);
  bterm_destroy(t); puts("terminal events: ordered chunks, clipboard policy/replies and bounded notifications passed"); return 0;
}
