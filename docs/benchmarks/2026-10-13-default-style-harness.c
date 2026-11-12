#define _POSIX_C_SOURCE 200809L
#include "bterm.h"
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
static uint64_t now(void) { struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return (uint64_t)ts.tv_sec*1000000000+ts.tv_nsec; }
int main(int argc,char **argv) {
 if(argc<2)return 2; FILE *f=fopen(argv[1],"rb");if(!f)return 2;
 fseek(f,0,SEEK_END);size_t length=(size_t)ftell(f);rewind(f);
 uint8_t *bytes=malloc(length);if(!bytes || fread(bytes,1,length,f)!=length)return 2;fclose(f);
 unsigned samples=argc>2 ? (unsigned)atoi(argv[2]) : 7,repeat=argc>3 ? (unsigned)atoi(argv[3]) : 1;
 for(unsigned i=0;i<samples+1;i++) {
  bterm *t=bterm_create(80,24,2000,NULL,NULL);if(!t)return 2;
  uint64_t start=now();
  for(unsigned j=0;j<repeat;j++)for(size_t n=0;n<length;n+=4096) {
   size_t size=length-n<4096 ? length-n : 4096;
   if(!bterm_feed(t,bytes+n,size))return 2;
  }
  uint64_t elapsed=now()-start;
  if(i)printf("%llu\n",(unsigned long long)elapsed);
  bterm_destroy(t);
 }
 free(bytes);return 0;
}
