/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/style.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 */
#ifndef BOGGART_LSTYLE_H
#define BOGGART_LSTYLE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* Tags preserve palette identity rather than prematurely resolving to RGB. */
#define LP_COLOR_INDEXED UINT32_C(0x01000000)
#define LP_COLOR_RGB UINT32_C(0x02000000)
#define LP_BOLD (UINT32_C(1) << 0)
#define LP_ITALIC (UINT32_C(1) << 1)
#define LP_FAINT (UINT32_C(1) << 2)
#define LP_BLINK (UINT32_C(1) << 3)
#define LP_INVERSE (UINT32_C(1) << 4)
#define LP_INVISIBLE (UINT32_C(1) << 5)
#define LP_STRIKE (UINT32_C(1) << 6)
#define LP_OVERLINE (UINT32_C(1) << 7)
#define LP_UNDERLINE_SHIFT 8
#define LP_UNDERLINE_MASK (UINT32_C(7) << LP_UNDERLINE_SHIFT)
typedef struct { uint32_t fg, bg, underline, attrs; } lpage_style;
typedef struct lstyle_pool lstyle_pool;
lstyle_pool *lstyle_create(void);
void lstyle_destroy(lstyle_pool *pool);
/* acquire owns one reference. Cells own their references independently. ID 0
 * is the permanent default. Non-default IDs may be reused after last release. */
bool lstyle_acquire(lstyle_pool *pool, const lpage_style *style, uint32_t *id);
bool lstyle_retain(lstyle_pool *pool, uint32_t id);
void lstyle_release(lstyle_pool *pool, uint32_t id);
/* Borrowed value is valid until the next mutation of the pool. */
const lpage_style *lstyle_get(const lstyle_pool *pool, uint32_t id);
size_t lstyle_refs(const lstyle_pool *pool, uint32_t id);
size_t lstyle_count(const lstyle_pool *pool);
size_t lstyle_bytes(const lstyle_pool *pool);
#endif
