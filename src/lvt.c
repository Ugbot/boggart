/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Parser.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: ordered raw OSC events with bounded payload storage; typed OSC
 * dispatch is a separate layer. UTF-8 decoding uses scalar range checks rather
 * than copying the upstream decoder's third-party DFA tables.
 */
#include "lvt.h"
#include <string.h>
#include "vt_table.h"

void lvt_init(lvt_parser *p) { memset(p, 0, sizeof *p); }
lvt_effect lvt_transition(lvt_state state, uint8_t byte) {
  if ((unsigned)state >= LVT_STATE_COUNT) return (lvt_effect){ LVT_GROUND, LVT_A_IGNORE };
  unsigned char packed = lvt_table[state][byte];
  return (lvt_effect){ (lvt_state)(packed >> 4), (lvt_action)(packed & 15) };
}
static void clear(lvt_parser *p) {
  p->nintermediates = p->nparams = p->param_digits = 0;
  p->param_acc = 0; p->separators = 0;
}
static void sequence(lvt_parser *p, lvt_event *e, lvt_event_type type, uint8_t final) {
  e->type = type; e->final = final;
  e->intermediates = p->intermediates; e->nintermediates = p->nintermediates;
  e->params = p->params; e->nparams = p->nparams; e->separators = p->separators;
}
static bool finalize(lvt_parser *p) {
  if (p->nparams >= LVT_MAX_PARAMS) return false;
  if (p->param_digits) p->params[p->nparams++] = p->param_acc;
  return true;
}
static void action(lvt_parser *p, lvt_action a, uint8_t c, lvt_event *e) {
  switch (a) {
    case LVT_A_PRINT: e->type = LVT_PRINT; e->codepoint = c; break;
    case LVT_A_EXECUTE: e->type = LVT_EXECUTE; e->codepoint = c; break;
    case LVT_A_COLLECT:
      if (p->nintermediates < LVT_MAX_INTERMEDIATES) p->intermediates[p->nintermediates++] = c;
      break;
    case LVT_A_PARAM:
      if (c == ';' || c == ':') {
        if (p->nparams >= LVT_MAX_PARAMS) break;
        p->params[p->nparams] = p->param_acc;
        if (c == ':') p->separators |= UINT32_C(1) << p->nparams;
        p->nparams++; p->param_acc = 0; p->param_digits = 0;
      } else {
        uint32_t value = (uint32_t)p->param_acc * 10 + c - '0';
        p->param_acc = (uint16_t)(value > UINT16_MAX ? UINT16_MAX : value);
        p->param_digits++; /* Match the pinned parser's bounded digit counter. */
      }
      break;
    case LVT_A_ESC_DISPATCH: sequence(p, e, LVT_ESC, c); break;
    case LVT_A_CSI_DISPATCH:
      if (finalize(p) && (c == 'm' || p->separators == 0)) sequence(p, e, LVT_CSI, c);
      break;
    case LVT_A_PUT: e->type = LVT_DCS_PUT; e->codepoint = c; break;
    case LVT_A_APC_PUT: e->type = LVT_APC_PUT; e->codepoint = c; break;
    case LVT_A_OSC_PUT:
      if (p->osc_length < LVT_OSC_CAPACITY) p->osc[p->osc_length++] = c;
      else p->osc_overflow = true;
      break;
    default: break;
  }
}
void lvt_next(lvt_parser *p, uint8_t c, lvt_event events[3]) {
  lvt_effect effect = lvt_transition(p->state, c);
  memset(events, 0, 3 * sizeof *events);
  bool changed = effect.state != p->state;
  if (changed) {
    switch (p->state) {
      case LVT_OSC_STRING:
        if (c != 0x18 && c != 0x1a && !p->osc_overflow && p->osc_length) {
          events[0].type = LVT_OSC; events[0].data = p->osc;
          events[0].length = p->osc_length; events[0].final = c;
        }
        break;
      case LVT_DCS_PASSTHROUGH: events[0].type = LVT_DCS_UNHOOK; break;
      case LVT_SOS_PM_APC_STRING: events[0].type = LVT_APC_END; break;
      default: break;
    }
  }
  action(p, effect.action, c, &events[1]);
  if (changed) {
    switch (effect.state) {
      case LVT_ESCAPE: case LVT_CSI_ENTRY: case LVT_DCS_ENTRY: clear(p); break;
      case LVT_OSC_STRING: p->osc_length = 0; p->osc_overflow = false; break;
      case LVT_DCS_PASSTHROUGH:
        if (finalize(p)) sequence(p, &events[2], LVT_DCS_HOOK, c);
        break;
      case LVT_SOS_PM_APC_STRING: events[2].type = LVT_APC_START; break;
      default: break;
    }
  }
  p->state = effect.state;
}
static void print(lvt_emit emit, void *context, uint32_t cp) {
  if (emit) { lvt_event e = {0}; e.type = LVT_PRINT; e.codepoint = cp; emit(context, &e); }
}
void lvt_feed(lvt_parser *p, const uint8_t *data, size_t length, lvt_emit emit, void *context) {
  for (size_t i = 0; i < length; i++) {
    uint8_t c = data[i];
    if (p->state == LVT_GROUND) {
      if (p->utf8_need) {
        if (c >= p->utf8_low && c <= p->utf8_high) {
          p->utf8_acc = (p->utf8_acc << 6) | (c & 63);
          p->utf8_low = 0x80; p->utf8_high = 0xbf;
          if (--p->utf8_need == 0) { print(emit, context, p->utf8_acc); p->utf8_acc = 0; }
          continue;
        }
        /* Reject without consuming the offending byte: ESC/C0 must still
         * reach the state machine when a producer truncates a UTF-8 scalar. */
        p->utf8_need = 0; p->utf8_acc = 0; print(emit, context, 0xfffd);
      }
      if (c >= 0x80) {
        p->utf8_low = 0x80; p->utf8_high = 0xbf;
        if (c >= 0xc2 && c <= 0xdf) { p->utf8_need = 1; p->utf8_acc = c & 31; }
        else if (c >= 0xe0 && c <= 0xef) {
          p->utf8_need = 2; p->utf8_acc = c & 15;
          if (c == 0xe0) p->utf8_low = 0xa0;
          if (c == 0xed) p->utf8_high = 0x9f;
        } else if (c >= 0xf0 && c <= 0xf4) {
          p->utf8_need = 3; p->utf8_acc = c & 7;
          if (c == 0xf0) p->utf8_low = 0x90;
          if (c == 0xf4) p->utf8_high = 0x8f;
        } else print(emit, context, 0xfffd);
        continue;
      }
      if (c >= 0x20 && c < 0x7f) { print(emit, context, c); continue; }
      if (c == 0x7f) continue; /* Ground DEL is ignored by UTF-8 terminals. */
    }
    lvt_event events[3]; lvt_next(p, c, events);
    if (emit) for (int j = 0; j < 3; j++) if (events[j].type != LVT_NONE) emit(context, &events[j]);
  }
}
void lvt_finish(lvt_parser *p, lvt_emit emit, void *context) {
  if (p->utf8_need) { p->utf8_need = 0; p->utf8_acc = 0; print(emit, context, 0xfffd); }
}
