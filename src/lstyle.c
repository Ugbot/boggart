/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/style.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: screen-owned indexed style slots with hash interning and a free
 * list. Cell references keep style IDs stable across row/page movement.
 */
#include "lstyle.h"
#include <stdlib.h>
#include <string.h>
#include <assert.h>
typedef struct { lpage_style value; size_t refs; uint32_t next; } entry;
struct lstyle_pool {
  entry *entries;
  uint32_t *buckets;
  uint32_t capacity, used, free_id, bucket_count;
  size_t live;
};
static bool equal(const lpage_style *a, const lpage_style *b) {
  return a->fg == b->fg && a->bg == b->bg && a->underline == b->underline && a->attrs == b->attrs;
}
static uint32_t hash(const lpage_style *s) {
  uint32_t h = UINT32_C(2166136261);
  h = (h ^ s->fg) * UINT32_C(16777619);
  h = (h ^ s->bg) * UINT32_C(16777619);
  h = (h ^ s->underline) * UINT32_C(16777619);
  return (h ^ s->attrs) * UINT32_C(16777619);
}
lstyle_pool *lstyle_create(void) {
  lstyle_pool *p = calloc(1, sizeof *p);
  if (!p) return NULL;
  p->capacity = 16; p->bucket_count = 32;
  p->entries = calloc(p->capacity, sizeof *p->entries);
  p->buckets = calloc(p->bucket_count, sizeof *p->buckets);
  if (!p->entries || !p->buckets) { lstyle_destroy(p); return NULL; }
  return p;
}
void lstyle_destroy(lstyle_pool *p) {
  if (p) { free(p->entries); free(p->buckets); free(p); }
}
const lpage_style *lstyle_get(const lstyle_pool *p, uint32_t id) {
  return id <= p->used && (id == 0 || p->entries[id].refs) ? &p->entries[id].value : NULL;
}
bool lstyle_retain(lstyle_pool *p, uint32_t id) {
  if (!lstyle_get(p, id)) return false;
  if (id == 0) return true;
  if (p->entries[id].refs == SIZE_MAX) return false;
  p->entries[id].refs++; return true;
}
void lstyle_release(lstyle_pool *p, uint32_t id) {
  if (id == 0) return;
  assert(id <= p->used && p->entries[id].refs);
  entry *e = &p->entries[id];
  if (--e->refs) return;
  uint32_t *link = &p->buckets[hash(&e->value) & (p->bucket_count - 1)];
  while (*link != id) link = &p->entries[*link].next;
  *link = e->next;
  e->next = p->free_id; p->free_id = id; p->live--;
}
static bool grow_buckets(lstyle_pool *p) {
  if (p->live < p->bucket_count) return true;
  if (p->bucket_count > UINT32_MAX / 2 || (size_t)p->bucket_count > SIZE_MAX / sizeof(uint32_t) / 2) return false;
  uint32_t count = p->bucket_count * 2;
  uint32_t *buckets = calloc(count, sizeof *buckets);
  if (!buckets) return false;
  for (uint32_t id = 1; id <= p->used; id++) {
    if (p->entries[id].refs) {
      uint32_t b = hash(&p->entries[id].value) & (count - 1);
      p->entries[id].next = buckets[b]; buckets[b] = id;
    }
  }
  free(p->buckets); p->buckets = buckets; p->bucket_count = count;
  return true;
}
bool lstyle_acquire(lstyle_pool *p, const lpage_style *value, uint32_t *out) {
  if (equal(value, &p->entries[0].value)) { *out = 0; return true; }
  uint32_t b = hash(value) & (p->bucket_count - 1);
  for (uint32_t id = p->buckets[b]; id; id = p->entries[id].next) {
    if (equal(value, &p->entries[id].value)) {
      if (!lstyle_retain(p, id)) return false;
      *out = id; return true;
    }
  }
  if (!grow_buckets(p)) return false;
  uint32_t id = p->free_id;
  if (id) p->free_id = p->entries[id].next;
  else {
    if (p->used + 1 == p->capacity) {
      if (p->capacity > UINT32_MAX / 2 || (size_t)p->capacity > SIZE_MAX / sizeof(entry) / 2) return false;
      uint32_t capacity = p->capacity * 2;
      entry *entries = realloc(p->entries, (size_t)capacity * sizeof *entries);
      if (!entries) return false;
      p->entries = entries; p->capacity = capacity;
    }
    id = ++p->used;
  }
  b = hash(value) & (p->bucket_count - 1);
  p->entries[id] = (entry){ *value, 1, p->buckets[b] };
  p->buckets[b] = id; p->live++; *out = id;
  return true;
}
size_t lstyle_refs(const lstyle_pool *p, uint32_t id) {
  return id && id <= p->used ? p->entries[id].refs : 0;
}
size_t lstyle_count(const lstyle_pool *p) { return p->live + 1; }
size_t lstyle_bytes(const lstyle_pool *p) {
  return sizeof *p + (size_t)p->capacity * sizeof(entry) + (size_t)p->bucket_count * sizeof(uint32_t);
}
