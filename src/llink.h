/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Screen.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 */
#ifndef BOGGART_LLINK_H
#define BOGGART_LLINK_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct { const char *key, *uri; size_t key_length, uri_length; } llink_value;
typedef struct llink_pool llink_pool;
llink_pool *llink_create(void);
void llink_destroy(llink_pool *pool);
/* acquire copies at most 256 key and 4096 URI bytes and owns one reference.
 * An empty key creates a new implicit identity on each acquire; explicit keys
 * intern the (key, URI) pair. Validation of URI/text belongs to the OSC parser.
 * Empty key + URI yields ID 0 (no link). IDs may be reused after last release. */
bool llink_acquire(llink_pool *pool, const llink_value *value, uint32_t *id);
bool llink_retain(llink_pool *pool, uint32_t id);
void llink_release(llink_pool *pool, uint32_t id);
/* Borrow expires on the next pool mutation. ID 0 or a dead ID returns NULL. */
const llink_value *llink_get(const llink_pool *pool, uint32_t id);
size_t llink_refs(const llink_pool *pool, uint32_t id);
size_t llink_count(const llink_pool *pool);
size_t llink_bytes(const llink_pool *pool);
#endif
