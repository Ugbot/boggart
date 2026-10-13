/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/page.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: screen-owned slots, with copy-on-write for shared cells.
 */
#ifndef BOGGART_LGRAPHEME_H
#define BOGGART_LGRAPHEME_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define LG_SUFFIX_LIMIT 64
#define LG_LIMIT (LG_SUFFIX_LIMIT + 1)
typedef struct { const uint32_t *codepoints; size_t length; } lgrapheme_value;
typedef struct lgrapheme_pool lgrapheme_pool;
lgrapheme_pool *lgrapheme_create(void);
void lgrapheme_destroy(lgrapheme_pool *pool);
/* Successful acquire/append owns one reference. Input is copied and length is
 * capped at one base plus 64 suffix scalars. IDs recycle after last release.
 * append changes an unshared slot in place, or copies a shared slot. */
bool lgrapheme_acquire(lgrapheme_pool *pool, const uint32_t *codepoints, size_t length, uint32_t *id);
bool lgrapheme_append(lgrapheme_pool *pool, uint32_t id, uint32_t cp, uint32_t *result);
bool lgrapheme_retain(lgrapheme_pool *pool, uint32_t id);
void lgrapheme_release(lgrapheme_pool *pool, uint32_t id);
/* Borrowed slices expire on pool mutation; dead/zero IDs return {NULL,0}. */
lgrapheme_value lgrapheme_get(const lgrapheme_pool *pool, uint32_t id);
size_t lgrapheme_refs(const lgrapheme_pool *pool, uint32_t id);
size_t lgrapheme_count(const lgrapheme_pool *pool);
size_t lgrapheme_bytes(const lgrapheme_pool *pool);
#endif
