/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/bitmap_allocator.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE. */
#ifndef BOGGART_LBITMAP_H
#define BOGGART_LBITMAP_H
#include <stdbool.h>
#include <stdint.h>
/* Single-owner allocation metadata for the SDK's 16/32-byte chunk arenas.
 * Only init allocates host memory. Requests of <=64 chunks stay within one
 * bitmap word, matching the SDK's placement and fragmentation. Larger spans
 * may cross words. Data storage is owned by the caller, not this bitmap. */
typedef struct {
  uint64_t *bits;
  uint32_t words, search_start, chunk_bytes, used_chunks;
} lbitmap;
/* Initialize a fresh object; failure preserves it. Requested byte capacity
 * rounds up to full 64-chunk words, including the SDK's extra usable space. */
bool lbitmap_init(lbitmap *bitmap, uint32_t bytes, unsigned chunk_bytes);
void lbitmap_destroy(lbitmap *bitmap);
void lbitmap_clear(lbitmap *bitmap);
/* Failure preserves the bitmap and output. Offset is relative to chunk data. */
bool lbitmap_alloc(lbitmap *bitmap, uint32_t bytes, uint32_t *offset);
/* Caller must pass the exact returned extent. Reject empty, unaligned,
 * out-of-range or already-free extents before changing any bits. */
bool lbitmap_free(lbitmap *bitmap, uint32_t offset, uint32_t bytes);
uint64_t lbitmap_capacity(const lbitmap *bitmap);
uint64_t lbitmap_used(const lbitmap *bitmap);
#endif
