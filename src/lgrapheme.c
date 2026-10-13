/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/page.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: screen-owned slots; release storage at zero references. A shared
 * glyph is copied before append, keeping snapshots/cell copies independent.
 */
#include "lgrapheme.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
typedef struct { uint32_t *cps; size_t refs; uint32_t next; uint8_t length, capacity; } entry;
struct lgrapheme_pool {
  entry *entries;
  uint32_t capacity, used, free_id;
  size_t live, data_bytes;
};
static bool valid(uint32_t cp) { return cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff); }
lgrapheme_pool *lgrapheme_create(void) { return calloc(1, sizeof(lgrapheme_pool)); }
void lgrapheme_destroy(lgrapheme_pool *p) {
  if (!p) return;
  for (uint32_t i=1;i<=p->used;i++) if (p->entries[i].refs) free(p->entries[i].cps);
  free(p->entries); free(p);
}
lgrapheme_value lgrapheme_get(const lgrapheme_pool *p, uint32_t id) {
  if (!id || id > p->used || !p->entries[id].refs) return (lgrapheme_value){0};
  return (lgrapheme_value){p->entries[id].cps,p->entries[id].length};
}
bool lgrapheme_retain(lgrapheme_pool *p, uint32_t id) {
  if (!lgrapheme_get(p,id).length || p->entries[id].refs==SIZE_MAX) return false;
  p->entries[id].refs++; return true;
}
void lgrapheme_release(lgrapheme_pool *p, uint32_t id) {
  assert(id && id<=p->used && p->entries[id].refs);
  entry *e=&p->entries[id]; if (--e->refs) return;
  p->data_bytes-=(size_t)e->capacity*sizeof(uint32_t);
  free(e->cps); e->cps=NULL; e->length=e->capacity=0;
  e->next=p->free_id; p->free_id=id; p->live--;
}
static bool reserve(lgrapheme_pool *p) {
  if (p->free_id || p->used+1 < p->capacity) return true;
  uint32_t capacity=p->capacity ? p->capacity*2 : 16;
  if (p->capacity > UINT32_MAX/2 || (size_t)capacity > SIZE_MAX/sizeof(entry)) return false;
  entry *entries=realloc(p->entries,(size_t)capacity*sizeof *entries);
  if (!entries) return false;
  p->entries=entries; p->capacity=capacity; return true;
}
static uint8_t capacity_for(size_t length) {
  unsigned capacity=4;
  while (capacity < length) capacity*=2;
  if (capacity > LG_LIMIT) capacity=LG_LIMIT;
  return (uint8_t)capacity;
}
bool lgrapheme_acquire(lgrapheme_pool *p, const uint32_t *cps, size_t length, uint32_t *out) {
  if (!length || !cps || !cps[0]) return false;
  if (length>LG_LIMIT) length=LG_LIMIT;
  for (size_t i=0;i<length;i++) if (!valid(cps[i])) return false;
  uint8_t capacity=capacity_for(length); size_t bytes=(size_t)capacity*sizeof *cps;
  if (bytes>SIZE_MAX-p->data_bytes) return false;
  uint32_t *data=malloc(bytes); if (!data) return false;
  memcpy(data,cps,length*sizeof *data);
  if (!reserve(p)) { free(data); return false; }
  uint32_t id=p->free_id;
  if (id) p->free_id=p->entries[id].next; else id=++p->used;
  p->entries[id]=(entry){data,1,0,(uint8_t)length,capacity};
  p->live++; p->data_bytes+=bytes; *out=id; return true;
}
bool lgrapheme_append(lgrapheme_pool *p, uint32_t id, uint32_t cp, uint32_t *out) {
  lgrapheme_value v=lgrapheme_get(p,id);
  if (!v.length || !valid(cp)) return false;
  if (v.length==LG_LIMIT) { if (!lgrapheme_retain(p,id)) return false; *out=id; return true; }
  entry *e=&p->entries[id];
  if (e->refs>1) {
    uint32_t cps[LG_LIMIT]; memcpy(cps,v.codepoints,v.length*sizeof *cps); cps[v.length]=cp;
    return lgrapheme_acquire(p,cps,v.length+1,out);
  }
  if (e->length==e->capacity) {
    uint8_t capacity=capacity_for((size_t)e->length+1);
    size_t growth=(size_t)(capacity-e->capacity)*sizeof(uint32_t);
    if (growth>SIZE_MAX-p->data_bytes) return false;
    uint32_t *data=realloc(e->cps,(size_t)capacity*sizeof *data); if (!data) return false;
    e->cps=data; e->capacity=capacity; p->data_bytes+=growth;
  }
  e->cps[e->length++]=cp; e->refs++; *out=id; return true;
}
size_t lgrapheme_refs(const lgrapheme_pool *p, uint32_t id) { return id && id<=p->used ? p->entries[id].refs : 0; }
size_t lgrapheme_count(const lgrapheme_pool *p) { return p->live; }
size_t lgrapheme_bytes(const lgrapheme_pool *p) { return sizeof *p+(size_t)p->capacity*sizeof(entry)+p->data_bytes; }
