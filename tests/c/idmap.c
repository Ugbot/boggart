#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#if defined(_WIN32)
#include <malloc.h>
#endif
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static size_t allocations,live,fail_at;
static void *fault_aligned_alloc(size_t alignment,size_t size) {
  allocations++;
  if (fail_at && allocations==fail_at) return NULL;
  void *p;
#if defined(_WIN32)
  p=_aligned_malloc(size,alignment);
#else
  p=aligned_alloc(alignment,size);
#endif
  if (p) live++;
  return p;
}
static void fault_free(void *p) {
  if (p) { CHECK(live); live--; }
#if defined(_WIN32)
  _aligned_free(p);
#else
  free(p);
#endif
}
#if defined(_WIN32)
static void *fault_win_alloc(size_t size,size_t alignment) { return fault_aligned_alloc(alignment,size); }
#define _aligned_malloc fault_win_alloc
#define _aligned_free fault_free
#endif
#define aligned_alloc fault_aligned_alloc
#define free fault_free
#define LIDMAP_TESTING 1
#include "../../src/lidmap.c"
#undef aligned_alloc
#undef free
#if defined(_WIN32)
#undef _aligned_malloc
#undef _aligned_free
#endif

static uint64_t seed=UINT64_C(0x724d5efa81c90113);
static uint64_t random64(void) { seed^=seed<<13; seed^=seed>>7; seed^=seed<<17; return seed; }
static void mirror(const lidmap *m) {
  CHECK(!memcmp(m->ctrl,m->ctrl+m->capacity,LIDMAP_GROUP));
  uint32_t count=0,tombs=0;
  for (uint32_t i=0;i<m->capacity;i++) {
    if (!(m->ctrl[i]&0x80)) { count++; CHECK(lidmap_get(m,m->keys[i],~m->values[i])==m->values[i]); }
    else if (m->ctrl[i]==LIDMAP_CTRL_TOMBSTONE) tombs++;
    else CHECK(m->ctrl[i]==LIDMAP_CTRL_EMPTY);
  }
  CHECK(count==m->count && tombs==m->tombstones);
}
static void masks(void) {
  uint8_t ctrl[64];
  for (size_t trial=0;trial<20000;trial++) {
    for (size_t i=0;i<sizeof ctrl;i++) ctrl[i]=(uint8_t)random64();
    uint32_t base=(uint32_t)(random64()%48); uint8_t tag=(uint8_t)(random64()&127);
    lidmap_masks a=lidmap_match2_(ctrl,base,tag),b=lidmap_match2_scalar_(ctrl,base,tag);
    CHECK(a.tag==b.tag && a.empty==b.empty);
    CHECK(lidmap_match_(ctrl,base,tag)==lidmap_match_scalar_(ctrl,base,tag));
    CHECK(lidmap_match_(ctrl,base,LIDMAP_CTRL_EMPTY)==lidmap_match_scalar_(ctrl,base,LIDMAP_CTRL_EMPTY));
  }
}
static void failure(void) {
  for (size_t index=1;index<=3;index++) {
    lidmap m; memset(&m,0xa5,sizeof m); allocations=0; fail_at=index;
    CHECK(!lidmap_init(&m,8)); fail_at=0;
    lidmap zero={0}; CHECK(!memcmp(&m,&zero,sizeof m) && live==0);
    lidmap_free(&m); CHECK(live==0);
  }
  lidmap m,old; memset(&m,0xa5,sizeof m); old=m;
  CHECK(!lidmap_init(&m,0) && !memcmp(&m,&old,sizeof m));
  CHECK(!lidmap_init(&m,UINT32_C(1073741825)) && !memcmp(&m,&old,sizeof m));
  CHECK(!lidmap_init(&m,UINT32_MAX) && !memcmp(&m,&old,sizeof m));
  CHECK(!lidmap_init(NULL,8));
}
static void limits(void) {
  lidmap m; CHECK(lidmap_init(&m,8));
  CHECK(!((uintptr_t)m.ctrl&63) && !((uintptr_t)m.keys&63) && !((uintptr_t)m.values&63));
  uint64_t keys[14]; keys[0]=0; keys[1]=UINT64_MAX;
  /* Deliberately start all remaining probe sequences in the tail-mirror region. */
  uint64_t candidate=1;
  for (unsigned i=2;i<14;i++) {
    while ((lidmap_hash_u64(candidate)&m.mask)!=m.mask) candidate++;
    keys[i]=candidate++;
  }
  for (unsigned i=0;i<14;i++) CHECK(lidmap_insert(&m,keys[i],i));
  size_t before=allocations; uint8_t ctrl[32]; uint64_t saved_keys[16]; uint32_t values[16];
  memcpy(ctrl,m.ctrl,sizeof ctrl); memcpy(saved_keys,m.keys,sizeof saved_keys); memcpy(values,m.values,sizeof values);
  CHECK(!lidmap_insert(&m,candidate+1000,123));
  CHECK(!memcmp(ctrl,m.ctrl,sizeof ctrl) && !memcmp(saved_keys,m.keys,sizeof saved_keys) && !memcmp(values,m.values,sizeof values));
  CHECK(lidmap_insert(&m,keys[13],UINT32_MAX) && m.count==14);
  CHECK(lidmap_get(&m,keys[13],0)==UINT32_MAX);
  for (unsigned i=0;i<7;i++) CHECK(lidmap_erase(&m,keys[i]));
  lidmap_rehash_in_place(&m); CHECK(m.tombstones==0); mirror(&m);
  for (unsigned i=7;i<14;i++) CHECK(lidmap_find(&m,keys[i],NULL));
  CHECK(allocations==before); lidmap_clear(&m); CHECK(m.count==0 && m.tombstones==0); mirror(&m);
  lidmap_free(&m); CHECK(live==0);
}
static void churn(void) {
  enum { DOMAIN=512 }; bool present[DOMAIN]={0}; uint32_t values[DOMAIN]={0};
  lidmap m; CHECK(lidmap_init(&m,DOMAIN)); size_t before=allocations,operations=0;
  struct timespec start,now; CHECK(timespec_get(&start,TIME_UTC)==TIME_UTC);
  do {
    for (size_t batch=0;batch<4096;batch++) {
      uint64_t r=random64(); unsigned index=(unsigned)(r%DOMAIN),op=(unsigned)(r>>10)%4;
      uint64_t key=UINT64_C(0xfede000000000000)+index;
      if (op==0) { uint32_t v=(uint32_t)random64(); CHECK(lidmap_insert(&m,key,v)); present[index]=true; values[index]=v; }
      else if (op==1) { CHECK(lidmap_erase(&m,key)==present[index]); present[index]=false; }
      else { uint32_t v=0; CHECK(lidmap_find(&m,key,&v)==present[index]); if (present[index]) CHECK(v==values[index]); }
      operations++;
    }
    mirror(&m); uint32_t count=0;
    for (unsigned i=0;i<DOMAIN;i++) { uint32_t v=0; CHECK(lidmap_find(&m,UINT64_C(0xfede000000000000)+i,&v)==present[i]); if (present[i]) { CHECK(v==values[i]); count++; } }
    CHECK(count==m.count && allocations==before);
    CHECK(timespec_get(&now,TIME_UTC)==TIME_UTC);
  } while ((double)(now.tv_sec-start.tv_sec)+(double)(now.tv_nsec-start.tv_nsec)/1e9<20.0);
  lidmap_free(&m); CHECK(live==0);
  printf("idmap: %zu model-checked operations, 20-second soak, no operation allocations\n",operations);
}
int main(void) { failure(); masks(); limits(); churn(); return 0; }
