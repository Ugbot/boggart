/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Screen.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/style.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: screen-owned link slots; free strings immediately at zero refs.
 * Indexed hash/free-list storage follows Boggart's C style pool.
 */
#include "llink.h"
#include <stdlib.h>
#include <string.h>
#include <assert.h>
typedef struct { llink_value value; size_t refs; uint32_t next, hash; } entry;
struct llink_pool {
  entry *entries;
  uint32_t *buckets;
  uint32_t capacity, used, free_id, bucket_count;
  size_t live, string_bytes;
};
static uint32_t hash(const llink_value *v) {
  uint32_t h = UINT32_C(2166136261);
  for (size_t i=0;i<v->key_length;i++) h = (h ^ (uint8_t)v->key[i]) * UINT32_C(16777619);
  h = (h ^ 0u) * UINT32_C(16777619);
  for (size_t i=0;i<v->uri_length;i++) h = (h ^ (uint8_t)v->uri[i]) * UINT32_C(16777619);
  return h;
}
static bool equal(const llink_value *a, const llink_value *b) {
  return a->key_length == b->key_length && a->uri_length == b->uri_length
    && !memcmp(a->key,b->key,a->key_length) && !memcmp(a->uri,b->uri,a->uri_length);
}
llink_pool *llink_create(void) { return calloc(1,sizeof(llink_pool)); }
void llink_destroy(llink_pool *p) {
  if (!p) return;
  for (uint32_t i=1;i<=p->used;i++) if (p->entries[i].refs) free((void *)p->entries[i].value.key);
  free(p->entries); free(p->buckets); free(p);
}
const llink_value *llink_get(const llink_pool *p, uint32_t id) {
  return id && id <= p->used && p->entries[id].refs ? &p->entries[id].value : NULL;
}
bool llink_retain(llink_pool *p, uint32_t id) {
  if (!id) return true;
  if (!llink_get(p,id) || p->entries[id].refs == SIZE_MAX) return false;
  p->entries[id].refs++; return true;
}
void llink_release(llink_pool *p, uint32_t id) {
  if (!id) return;
  assert(id <= p->used && p->entries[id].refs);
  entry *e = &p->entries[id];
  if (--e->refs) return;
  uint32_t *link = &p->buckets[e->hash & (p->bucket_count-1)];
  while (*link != id) link = &p->entries[*link].next;
  *link = e->next;
  p->string_bytes -= e->value.key_length + e->value.uri_length + 2;
  free((void *)e->value.key); e->value = (llink_value){0};
  e->next = p->free_id; p->free_id = id; p->live--;
}
static bool reserve(llink_pool *p) {
  if (!p->capacity) {
    entry *entries = calloc(16,sizeof *entries);
    uint32_t *buckets = calloc(32,sizeof *buckets);
    if (!entries || !buckets) { free(entries); free(buckets); return false; }
    p->entries=entries; p->buckets=buckets; p->capacity=16; p->bucket_count=32;
  }
  if (p->live >= p->bucket_count) {
    if (p->bucket_count > UINT32_MAX/2 || (size_t)p->bucket_count > SIZE_MAX/sizeof(uint32_t)/2) return false;
    uint32_t count=p->bucket_count*2, *buckets=calloc(count,sizeof *buckets);
    if (!buckets) return false;
    for (uint32_t id=1;id<=p->used;id++) if (p->entries[id].refs) {
      uint32_t b=p->entries[id].hash & (count-1);
      p->entries[id].next=buckets[b]; buckets[b]=id;
    }
    free(p->buckets); p->buckets=buckets; p->bucket_count=count;
  }
  if (!p->free_id && p->used+1 == p->capacity) {
    if (p->capacity > UINT32_MAX/2 || (size_t)p->capacity > SIZE_MAX/sizeof(entry)/2) return false;
    uint32_t capacity=p->capacity*2;
    entry *entries=realloc(p->entries,(size_t)capacity*sizeof *entries);
    if (!entries) return false;
    p->entries=entries; p->capacity=capacity;
  }
  return true;
}
bool llink_acquire(llink_pool *p, const llink_value *source, uint32_t *out) {
  /* Copy descriptors too: source may itself be a borrowed pool value. */
  llink_value v=*source;
  if (v.key_length > 256 || v.uri_length > 4096) return false;
  if (!v.uri_length) { if (v.key_length) return false; *out=0; return true; }
  uint32_t h=hash(&v);
  if (v.key_length && p->bucket_count) {
    for (uint32_t id=p->buckets[h & (p->bucket_count-1)];id;id=p->entries[id].next) {
      if (p->entries[id].hash == h && equal(&v,&p->entries[id].value)) {
        if (!llink_retain(p,id)) return false;
        *out=id; return true;
      }
    }
  }
  size_t n=v.key_length+v.uri_length+2;
  if (n > SIZE_MAX-p->string_bytes) return false;
  char *data=malloc(n);
  if (!data) return false;
  if (v.key_length) memcpy(data,v.key,v.key_length);
  data[v.key_length]=0; memcpy(data+v.key_length+1,v.uri,v.uri_length); data[n-1]=0;
  if (!reserve(p)) { free(data); return false; }
  uint32_t id=p->free_id;
  if (id) p->free_id=p->entries[id].next; else id=++p->used;
  if (!v.key_length) h = (h ^ id) * UINT32_C(16777619);
  uint32_t b=h & (p->bucket_count-1);
  p->entries[id]=(entry){ {data,data+v.key_length+1,v.key_length,v.uri_length},1,p->buckets[b],h };
  p->buckets[b]=id; p->live++; p->string_bytes+=n; *out=id; return true;
}
size_t llink_refs(const llink_pool *p, uint32_t id) { return id && id <= p->used ? p->entries[id].refs : 0; }
size_t llink_count(const llink_pool *p) { return p->live; }
size_t llink_bytes(const llink_pool *p) {
  return sizeof *p + (size_t)p->capacity*sizeof(entry) + (size_t)p->bucket_count*sizeof(uint32_t) + p->string_bytes;
}
