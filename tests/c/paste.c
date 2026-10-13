#include "bpaste.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
static uint8_t out[512];static size_t n;
static void expect(const char *input,bool bracketed,const char *expected) {
  CHECK(bpaste_encode((const uint8_t *)input,strlen(input),bracketed,out,sizeof out,&n));
  CHECK(n==strlen(expected)&&!memcmp(out,expected,n));
}
int main(void) {
  expect("hello",false,"hello");expect("hello",true,"\033[200~hello\033[201~");
  expect("a\r\nb\n",false,"a\r\rb\r");expect("a\r\nb\n",true,"\033[200~a\r\nb\n\033[201~");
  expect("a\033[201~b",true,"\033[200~a [201~b\033[201~");
  expect("漢字😀",false,"漢字😀");expect("漢字😀",true,"\033[200~漢字😀\033[201~");
  expect("",true,"\033[200~\033[201~");CHECK(bpaste_encode(NULL,0,false,NULL,0,&n)&&!n);
  uint8_t every[256];for(size_t i=0;i<256;i++)every[i]=(uint8_t)i;
  const uint8_t replace[]={0,8,5,4,27,127,3,28,21,26,17,19,23,22,18,15};
  for(unsigned bracketed=0;bracketed<2;bracketed++) {
    CHECK(bpaste_encode(every,sizeof every,bracketed,out,sizeof out,&n));
    CHECK(n==sizeof every+(bracketed?12:0));
    for(unsigned i=0;i<256;i++) {
      uint8_t expected=(uint8_t)i;
      for(size_t j=0;j<sizeof replace;j++)if(expected==replace[j]){expected=' ';break;}
      if(!bracketed && i==10)expected=13;
      CHECK(out[(bracketed?6:0)+i]==expected && every[i]==i);
    }
  }
  /* memmove must preserve the source even where the prefix would overwrite it. */
  memcpy(out,"a\033b\n",4);CHECK(bpaste_encode(out,4,true,out,sizeof out,&n));CHECK(n==16&&!memcmp(out,"\033[200~a b\n\033[201~",n));
  memcpy(out+10,"\na\0b",4);CHECK(bpaste_encode(out+10,4,false,out+11,sizeof out-11,&n));CHECK(n==4&&!memcmp(out+11,"\ra b",n));
  for(size_t capacity=0;capacity<17;capacity++) {
    memset(out,0xa5,sizeof out);CHECK(!bpaste_encode((const uint8_t *)"hello",5,true,out,capacity,&n)&&!n);
    for(size_t j=0;j<sizeof out;j++)CHECK(out[j]==0xa5);
  }
  CHECK(!bpaste_encode(NULL,1,false,out,sizeof out,&n)&&!n);
  CHECK(!bpaste_encode((const uint8_t *)"x",SIZE_MAX,true,out,sizeof out,&n)&&!n);
  CHECK(!bpaste_encode((const uint8_t *)"x",1,false,NULL,1,&n)&&!n);
  CHECK(bpaste_safe(NULL,0,false));CHECK(!bpaste_safe(NULL,1,false));
  CHECK(bpaste_safe((const uint8_t *)"a\nb",3,true));CHECK(!bpaste_safe((const uint8_t *)"a\nb",3,false));
  CHECK(!bpaste_safe((const uint8_t *)"\033[201~",6,true));CHECK(!bpaste_safe((const uint8_t *)"a\033[201~b",8,false));
  CHECK(bpaste_safe((const uint8_t *)"\033[201",5,true));
  uint32_t seed=71;
  for(size_t trial=0;trial<10000;trial++) {
    uint8_t data[64];for(size_t i=0;i<sizeof data;i++){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;data[i]=(uint8_t)seed;}
    size_t size=seed%sizeof data;bool bracketed=(seed&128)!=0;
    CHECK(bpaste_encode(data,size,bracketed,out,sizeof out,&n)&&n==size+(bracketed?12:0));
  }
  puts("Paste encoding: framing/newlines/control bytes/Unicode/overlap/atomic capacity passed");return 0;
}
