/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/mouse_encode.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 */
#ifndef BOGGART_BMOUSE_H
#define BOGGART_BMOUSE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#define BMOUSE_CAPACITY 64
enum { BI_SHIFT = 1u, BI_ALT = 2u, BI_CTRL = 4u };
typedef enum { BM_NONE, BM_X10, BM_NORMAL, BM_BUTTON, BM_ANY } bmouse_mode;
typedef enum { BM_FORMAT_X10, BM_UTF8, BM_SGR, BM_URXVT, BM_PIXELS } bmouse_format;
typedef enum { BM_PRESS, BM_RELEASE, BM_MOTION } bmouse_action;
/* button: 0 none (motion only), 1 left, 2 middle, 3 right, 4/5 wheel
 * up/down, 6/7 wheel left/right, 8/9 extra buttons. Terminal pixel origin
 * is (0,0); host subtracts pane origin/padding and applies scaling first. */
typedef struct { bmouse_action action; unsigned button, modifiers; int32_t x, y; bool any_button_pressed; } bmouse_event;
typedef struct { bmouse_mode mode; bmouse_format format; uint32_t columns, rows, cell_width, cell_height; } bmouse_options;
typedef struct { bool valid; uint32_t column, row; } bmouse_motion;
/* Geometry: rows/columns 1..4096 and cell dimensions 1..65535 pixels.
 * Returns true with length 0 when intentionally suppressed. False rejects
 * invalid arguments or insufficient output capacity without writing output or
 * changing last_cell. Motion state updates only when a report is emitted.
 * last_cell may be NULL to disable deduplication. Encoding never allocates. */
bool bmouse_encode(const bmouse_event *event, const bmouse_options *options,
                     bmouse_motion *last_cell, uint8_t *output, size_t capacity, size_t *length);
#endif
