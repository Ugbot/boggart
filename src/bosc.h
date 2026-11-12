/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 */
#ifndef BOGGART_BOSC_H
#define BOGGART_BOSC_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#define BOSC_MAX_PAYLOAD 4096
typedef struct { const uint8_t *data; size_t length; } bosc_slice;
typedef enum { BOSC_NONE, BOSC_TITLE, BOSC_CWD, BOSC_HYPERLINK, BOSC_NOTIFY,
  BOSC_SHELL, BOSC_CLIPBOARD, BOSC_BELL } bosc_type;
typedef enum { BOSC_NOTIFY_TITLE, BOSC_NOTIFY_BODY, BOSC_NOTIFY_CLOSE, BOSC_NOTIFY_QUERY } bosc_notify_payload;
typedef struct {
  bosc_type type;
  unsigned code;
  union {
    bosc_slice text;
    struct { bosc_slice id, uri; } link;
    struct { bosc_slice id, title, body; bosc_notify_payload payload; bool done, urgency_set; unsigned urgency; } notify;
    struct { char mark; bool has_status; int32_t status; bosc_slice options; } shell;
    struct { char selection; bool query, bel; bosc_slice text; } clipboard;
  } value;
} bosc_command;
/* Slices borrow input or scratch until either buffer is changed. No allocation.
 * Scratch must not overlap input; input is bounded by BOSC_MAX_PAYLOAD.
 * false means malformed/unsupported. Policy and side effects belong to callers. */
bool bosc_parse(const uint8_t *payload, size_t length, bool bel,
                 uint8_t scratch[BOSC_MAX_PAYLOAD], bosc_command *command);
bool bosc_text(bosc_slice text, bool multiline);
bool bosc_uri(bosc_slice uri);
#endif
