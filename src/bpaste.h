/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/paste.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 */
#ifndef BOGGART_BPASTE_H
#define BOGGART_BPASTE_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#define BPASTE_FRAME_SIZE 12
/* Binary-safe transform: replace the pinned xterm control-byte set with spaces;
 * preserve LF when bracketed, otherwise convert LF to CR (CRLF becomes CRCR).
 * Maximum output length is input length +12. Output may overlap input; the
 * caller owns sufficient storage. No allocation. Required length pointer must
 * be separate from input/output. NULL input is valid only at length zero.
 * On invalid input/overflow/capacity failure, output is unchanged and *length=0.
 * This low-level encoder frames empty bracketed input. */
bool bpaste_encode(const uint8_t *data, size_t size, bool bracketed,
                    uint8_t *output, size_t capacity, size_t *length);
/* Pinned heuristic only: reject a 7-bit paste terminator in either mode, and LF
 * in unbracketed mode. Does not authorize writes, read the clipboard or require
 * confirmation. Invalid input returns false. */
bool bpaste_safe(const uint8_t *data, size_t size, bool bracketed);
#endif
