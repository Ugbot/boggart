/* Adapted from Ben Gamble's Venus src/core/venus_ds.h; see THIRD_PARTY/venus-map.md. */
#ifndef LIDMAP_H
#define LIDMAP_H
#include <stdbool.h>
#include <stdint.h>
/* Single-owner u64 -> u32 Swiss table. Init is the only allocating operation;
 * initialize a fresh object (never reinitialize a live map). All keys/values
 * are valid, including zero and maximum integers. No implicit growth.
 * New inserts at the 7/8 load limit return false, preserving the map.
 * Failed init leaves a zero object; invalid hint leaves output untouched. */
typedef struct lidmap {
    uint8_t *ctrl;     /* capacity + LIDMAP_GROUP bytes, tail-mirrored */
    uint64_t *keys;    /* capacity entries */
    uint32_t *values;  /* capacity entries */
    uint32_t capacity; /* power of two >= LIDMAP_MIN_CAPACITY */
    uint32_t mask;     /* capacity - 1 */
    uint32_t count;    /* live entries */
    uint32_t tombstones;
} lidmap;
bool lidmap_init(lidmap *m, uint32_t capacity_hint);
void lidmap_free(lidmap *m);
void lidmap_clear(lidmap *m);
bool lidmap_find(const lidmap *m, uint64_t key, uint32_t *value_out);
uint32_t lidmap_get(const lidmap *m, uint64_t key, uint32_t missing);
void lidmap_rehash_in_place(lidmap *m);
bool lidmap_insert(lidmap *m, uint64_t key, uint32_t value);
bool lidmap_erase(lidmap *m, uint64_t key);
#endif
