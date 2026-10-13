/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/bitmap_allocator.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: bitmap-only ownership, checked public inputs and bounded scans.
 */
#include "lbitmap.h"
#include <stdlib.h>
#include <string.h>
#if defined(_MSC_VER)
#include <intrin.h>
#endif
static unsigned trailing(uint64_t n) {
  if (!n) return 64;
#if defined(_MSC_VER) && defined(_WIN64)
  unsigned long i; _BitScanForward64(&i,n); return (unsigned)i;
#elif defined(_MSC_VER)
  unsigned long i;
  if ((uint32_t)n) { _BitScanForward(&i,(uint32_t)n); return (unsigned)i; }
  _BitScanForward(&i,(uint32_t)(n>>32)); return (unsigned)i+32;
#else
  return (unsigned)__builtin_ctzll(n);
#endif
}
static unsigned leading(uint64_t n) {
  if (!n) return 64;
#if defined(_MSC_VER) && defined(_WIN64)
  unsigned long i; _BitScanReverse64(&i,n); return 63-(unsigned)i;
#elif defined(_MSC_VER)
  unsigned long i;
  if (n>>32) { _BitScanReverse(&i,(uint32_t)(n>>32)); return 31-(unsigned)i; }
  _BitScanReverse(&i,(uint32_t)n); return 63-(unsigned)i;
#else
  return (unsigned)__builtin_clzll(n);
#endif
}
static uint64_t mask(unsigned bit,unsigned n) {
  return (UINT64_MAX>>(64-n))<<bit;
}
bool lbitmap_init(lbitmap *out,uint32_t bytes,unsigned chunk) {
  if (!out || (chunk!=16 && chunk!=32)) return false;
  uint64_t chunks=((uint64_t)bytes+chunk-1)/chunk,words=(chunks+63)/64;
  lbitmap b={0}; b.words=(uint32_t)words; b.chunk_bytes=chunk;
  if (words && !(b.bits=calloc((size_t)words,sizeof *b.bits))) return false;
  *out=b; return true;
}
void lbitmap_destroy(lbitmap *b) {
  if (b) { free(b->bits); memset(b,0,sizeof *b); }
}
void lbitmap_clear(lbitmap *b) {
  if (!b) return;
  if (b->words) memset(b->bits,0,(size_t)b->words*sizeof *b->bits);
  b->search_start=b->used_chunks=0;
}
uint64_t lbitmap_capacity(const lbitmap *b) {
  return b ? (uint64_t)b->words*64*b->chunk_bytes : 0;
}
uint64_t lbitmap_used(const lbitmap *b) {
  return b ? (uint64_t)b->used_chunks*b->chunk_bytes : 0;
}
static void mark(lbitmap *b,uint32_t start,uint32_t n,bool allocate) {
  while (n) {
    unsigned bit=start%64,take=n<64-bit ? n : 64-bit;
    uint64_t m=mask(bit,take);
    if (allocate) b->bits[start/64]|=m; else b->bits[start/64]&=~m;
    start+=take; n-=take;
  }
}
bool lbitmap_alloc(lbitmap *b,uint32_t bytes,uint32_t *out) {
  if (!b || !out || !bytes || (b->chunk_bytes!=16 && b->chunk_bytes!=32)) return false;
  uint32_t n=(uint32_t)(((uint64_t)bytes+b->chunk_bytes-1)/b->chunk_bytes);
  if ((uint64_t)n+b->used_chunks>(uint64_t)b->words*64) return false;
  uint32_t found=0; bool available=false;
  if (n<=64) {
    for (uint32_t i=b->search_start;i<b->words;i++) {
      uint64_t free_bits=~b->bits[i],starts=free_bits;
      for (unsigned k=1;k<n;k++) starts&=free_bits>>k;
      if (starts) { found=i*64+trailing(starts); available=true; break; }
    }
  } else {
    uint32_t i=b->search_start;
    while (i<b->words) {
      unsigned prefix=leading(b->bits[i]);
      if (!prefix) { i++; continue; }
      uint32_t start=i*64+64-prefix,remaining=n-prefix,j=i+1;
      while (remaining>64 && j<b->words && !b->bits[j]) { remaining-=64; j++; }
      if (j>=b->words) break;
      if (remaining>64 || trailing(b->bits[j])<remaining) { i=j; continue; }
      found=start; available=true; break;
    }
  }
  if (!available) return false;
  mark(b,found,n,true); b->used_chunks+=n;
  while (b->search_start<b->words && b->bits[b->search_start]==UINT64_MAX) b->search_start++;
  *out=found*b->chunk_bytes; return true;
}
bool lbitmap_free(lbitmap *b,uint32_t offset,uint32_t bytes) {
  if (!b || !bytes || (b->chunk_bytes!=16 && b->chunk_bytes!=32) || offset%b->chunk_bytes) return false;
  uint32_t start=offset/b->chunk_bytes,n=(uint32_t)(((uint64_t)bytes+b->chunk_bytes-1)/b->chunk_bytes);
  if ((uint64_t)start+n>(uint64_t)b->words*64 || n>b->used_chunks) return false;
  uint32_t at=start,left=n;
  while (left) {
    unsigned bit=at%64,take=left<64-bit ? left : 64-bit;
    uint64_t m=mask(bit,take);
    if ((b->bits[at/64]&m)!=m) return false;
    at+=take; left-=take;
  }
  mark(b,start,n,false); b->used_chunks-=n;
  if (start/64<b->search_start) b->search_start=start/64;
  return true;
}
