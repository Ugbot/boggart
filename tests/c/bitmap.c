#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lbitmap.h"
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static size_t allocations;
static bool fail_init;
static void *test_calloc(size_t count,size_t size) { allocations++; return fail_init ? NULL : calloc(count,size); }
#define calloc test_calloc
#include "../../src/lbitmap.c"
#undef calloc
#include "../fixtures/ghostty-bitmap.h"
typedef struct { uint32_t offset, bytes; bool live; } slot;
static void captured(void) {
  size_t count=sizeof sdk_bitmap_cases/sizeof *sdk_bitmap_cases;
  for (size_t i=0;i<count;i++) {
    lbitmap b; CHECK(lbitmap_init(&b,sdk_bitmap_cases[i].capacity,sdk_bitmap_cases[i].chunk));
    slot slots[256]={0}; size_t before=allocations;
    for (size_t j=0;j<sdk_bitmap_cases[i].count;j++) {
      size_t k=sdk_bitmap_cases[i].first+j;
      unsigned from=sdk_bitmap_steps[k].from,to=sdk_bitmap_steps[k].to;
      if (sdk_bitmap_steps[k].operation==0) {
        CHECK(!slots[from].live); uint32_t offset=0xa5a5a5a5;
        bool ok=lbitmap_alloc(&b,sdk_bitmap_steps[k].bytes,&offset);
        CHECK(ok==sdk_bitmap_steps[k].success);
        CHECK(offset==(ok ? sdk_bitmap_steps[k].offset : UINT32_C(0xa5a5a5a5)));
        if (ok) slots[from]=(slot){offset,sdk_bitmap_steps[k].bytes,true};
      } else if (sdk_bitmap_steps[k].operation==1) {
        CHECK(slots[from].live && lbitmap_free(&b,slots[from].offset,slots[from].bytes)); slots[from].live=false;
      } else if (sdk_bitmap_steps[k].operation==2) {
        CHECK(slots[from].live && !slots[to].live); slots[to]=slots[from]; slots[from].live=false;
      } else { CHECK(slots[from].live); slots[from].live=false; }
      CHECK(b.words==sdk_bitmap_steps[k].words && b.search_start==sdk_bitmap_steps[k].search_start);
      CHECK(lbitmap_capacity(&b)==sdk_bitmap_steps[k].capacity && lbitmap_used(&b)==sdk_bitmap_steps[k].used);
      CHECK(!memcmp(b.bits,sdk_bitmap_steps[k].bits,(size_t)b.words*sizeof *b.bits));
    }
    CHECK(allocations==before); lbitmap_destroy(&b);
  }
  printf("%zu SDK bitmap cases / %zu exact placements, bitmaps and search hints match\n",count,sizeof sdk_bitmap_steps/sizeof *sdk_bitmap_steps);
}
static uint32_t random_state=0x7ea81;
static uint32_t random_value(void) { uint32_t n=random_state; n^=n<<13; n^=n>>17; n^=n<<5; return random_state=n; }
static bool reference(bool *bits,unsigned total,unsigned n,unsigned *out) {
  for (unsigned i=0;i+n<=total;i++) {
    if (n<=64 && i/64!=(i+n-1)/64) continue;
    unsigned j=0; while (j<n && !bits[i+j]) j++;
    if (j==n) { for (j=0;j<n;j++) bits[i+j]=true; *out=i; return true; }
  }
  return false;
}
static void mixed(void) {
  for (unsigned chunk=16;chunk<=32;chunk*=2) {
    lbitmap b; CHECK(lbitmap_init(&b,320*chunk,chunk)); bool bits[320]={0}; slot slots[64]={0};
    size_t before=allocations;
    for (unsigned step=0;step<200000;step++) {
      unsigned i=random_value()%64;
      if (slots[i].live) {
        CHECK(lbitmap_free(&b,slots[i].offset,slots[i].bytes));
        unsigned start=slots[i].offset/chunk,n=(slots[i].bytes+chunk-1)/chunk;
        for (unsigned j=0;j<n;j++) { CHECK(bits[start+j]); bits[start+j]=false; }
        slots[i].live=false;
      } else {
        uint32_t bytes=1+random_value()%(137*chunk),offset=0xa5a5a5a5; unsigned expected=0;
        bool want=reference(bits,320,(bytes+chunk-1)/chunk,&expected),got=lbitmap_alloc(&b,bytes,&offset);
        CHECK(got==want && offset==(got ? expected*chunk : UINT32_C(0xa5a5a5a5)));
        if (got) slots[i]=(slot){offset,bytes,true};
      }
      uint32_t used=0;
      for (unsigned j=0;j<320;j++) { CHECK(((b.bits[j/64]>>(j%64))&1)==bits[j]); used+=bits[j]; }
      CHECK(b.used_chunks==used);
      for (unsigned j=0;j<b.search_start;j++) CHECK(b.bits[j]==UINT64_MAX);
    }
    CHECK(allocations==before); lbitmap_destroy(&b);
  }
  puts("400000 mixed bitmap operations match a bit-by-bit placement model without allocation");
}
static void failures(void) {
  lbitmap unchanged,original; memset(&unchanged,0xa5,sizeof unchanged); original=unchanged;
  CHECK(!lbitmap_init(&unchanged,100,8) && !memcmp(&unchanged,&original,sizeof original));
  fail_init=true; CHECK(!lbitmap_init(&unchanged,8192,16) && !memcmp(&unchanged,&original,sizeof original)); fail_init=false;
  lbitmap b; CHECK(lbitmap_init(&b,128*16,16)); uint32_t offset;
  CHECK(lbitmap_alloc(&b,64*16,&offset) && offset==0);
  uint64_t saved[2]; memcpy(saved,b.bits,sizeof saved); lbitmap state=b;
  offset=0xa5a5a5a5;
  /* Exhaust a >64-chunk search at the final word without reading past it. */
  CHECK(!lbitmap_alloc(&b,65*16,&offset)); CHECK(offset==0xa5a5a5a5);
  CHECK(!lbitmap_alloc(&b,0,&offset) && !lbitmap_alloc(&b,16,NULL));
  CHECK(!lbitmap_free(&b,1,16) && !lbitmap_free(&b,0,0));
  CHECK(!lbitmap_free(&b,63*16,2*16) && !lbitmap_free(&b,128*16,16));
  CHECK(!memcmp(&b,&state,sizeof b) && !memcmp(b.bits,saved,sizeof saved));
  CHECK(lbitmap_free(&b,0,64*16)); CHECK(!lbitmap_free(&b,0,16));
  lbitmap_clear(&b); CHECK(!b.used_chunks && !b.search_start && !b.bits[0] && !b.bits[1]); lbitmap_destroy(&b);
  CHECK(lbitmap_init(&b,0,32)); CHECK(!lbitmap_alloc(&b,1,&offset) && !lbitmap_capacity(&b)); lbitmap_destroy(&b);
}
int main(void) { captured(); mixed(); failures(); return 0; }
