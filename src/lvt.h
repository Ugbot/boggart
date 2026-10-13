/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Parser.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 */
#ifndef BOGGART_LVT_H
#define BOGGART_LVT_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef enum {
  LVT_GROUND, LVT_ESCAPE, LVT_ESCAPE_INTERMEDIATE, LVT_CSI_ENTRY,
  LVT_CSI_INTERMEDIATE, LVT_CSI_PARAM, LVT_CSI_IGNORE, LVT_DCS_ENTRY,
  LVT_DCS_PARAM, LVT_DCS_INTERMEDIATE, LVT_DCS_PASSTHROUGH, LVT_DCS_IGNORE,
  LVT_OSC_STRING, LVT_SOS_PM_APC_STRING, LVT_STATE_COUNT
} lvt_state;
typedef enum {
  LVT_A_NONE, LVT_A_IGNORE, LVT_A_PRINT, LVT_A_EXECUTE, LVT_A_COLLECT,
  LVT_A_PARAM, LVT_A_ESC_DISPATCH, LVT_A_CSI_DISPATCH, LVT_A_PUT,
  LVT_A_OSC_PUT, LVT_A_APC_PUT, LVT_ACTION_COUNT
} lvt_action;
typedef struct { lvt_state state; lvt_action action; } lvt_effect;
typedef enum {
  LVT_NONE, LVT_PRINT, LVT_EXECUTE, LVT_CSI, LVT_ESC, LVT_OSC,
  LVT_DCS_HOOK, LVT_DCS_PUT, LVT_DCS_UNHOOK,
  LVT_APC_START, LVT_APC_PUT, LVT_APC_END
} lvt_event_type;

#define LVT_MAX_INTERMEDIATES 4
#define LVT_MAX_PARAMS 24
#define LVT_OSC_CAPACITY 4096
typedef struct {
  lvt_event_type type;
  uint32_t codepoint, separators;
  uint8_t final;
  const uint8_t *intermediates, *data;
  const uint16_t *params;
  size_t nintermediates, nparams, length;
} lvt_event;
typedef struct {
  lvt_state state;
  uint8_t intermediates[LVT_MAX_INTERMEDIATES], nintermediates;
  uint16_t params[LVT_MAX_PARAMS], param_acc;
  uint8_t nparams, param_digits;
  uint32_t separators;
  uint8_t osc[LVT_OSC_CAPACITY];
  size_t osc_length;
  bool osc_overflow;
  uint32_t utf8_acc;
  uint8_t utf8_need, utf8_low, utf8_high;
} lvt_parser;

/* Events borrow parser storage until the next byte. Consume/copy them in order;
 * callbacks must not re-enter this parser. Independent instances share only
 * immutable tables and may run on different threads. No function allocates.
 * OSC events here contain raw bounded payloads; command handling is separate. */
typedef void (*lvt_emit)(void *context, const lvt_event *event);
void lvt_init(lvt_parser *parser);
lvt_effect lvt_transition(lvt_state state, uint8_t byte);
void lvt_next(lvt_parser *parser, uint8_t byte, lvt_event actions[3]);
void lvt_feed(lvt_parser *parser, const uint8_t *data, size_t length,
              lvt_emit emit, void *context);
/* Flush an incomplete UTF-8 scalar at process EOF; chunk boundaries are not EOF. */
void lvt_finish(lvt_parser *parser, lvt_emit emit, void *context);
#endif
