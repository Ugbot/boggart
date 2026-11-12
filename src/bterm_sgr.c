/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/sgr.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: colour/attribute values applied to a C pen. Malformed colon
 * groups are ignored as a unit instead of applying their remaining subparams.
 */
#include "bterm_internal.h"
static bool colon(const lvt_event *e, size_t i) { return (e->separators & (UINT32_C(1) << i)) != 0; }
static uint32_t rgb(const uint16_t *p) {
  return LP_COLOR_RGB | ((uint32_t)(uint8_t)p[0] << 16) | ((uint32_t)(uint8_t)p[1] << 8) | (uint8_t)p[2];
}
void bt_sgr(bterm *t, const lvt_event *e) {
  lpage_style pen = t->pen;
  if (!e->nparams) pen = (lpage_style){0, 0, 0, 0};
  for (size_t i = 0; i < e->nparams; i++) {
    unsigned p = e->params[i];
    size_t end = i;
    while (end + 1 < e->nparams && colon(e, end)) end++;
    bool sub = colon(e, i), trailing = colon(e, end);
    size_t group = end - i + 1;
    if (sub && p != 4 && p != 38 && p != 48 && p != 58) { i = end; continue; }
    if (p == 38 || p == 48 || p == 58) {
      uint32_t value = 0; size_t consumed = 0;
      if (i + 1 < e->nparams) {
        unsigned kind = e->params[i + 1];
        if (kind == 5 && i + 2 < e->nparams && (!sub || (group == 3 && !trailing))) {
          value = LP_COLOR_INDEXED | (uint8_t)e->params[i + 2]; consumed = 2;
        } else if (kind == 2) {
          if (!sub && i + 4 < e->nparams) { value = rgb(e->params + i + 2); consumed = 4; }
          else if (sub && !trailing && (group == 5 || group == 6)) {
            consumed = group - 1; value = rgb(e->params + end - 2);
          }
        }
      }
      if (consumed) {
        if (p == 38) pen.fg = value; else if (p == 48) pen.bg = value; else pen.underline = value;
        i += consumed;
      } else if (sub) i = end;
      continue;
    }
    if (p == 4) {
      unsigned underline = 1;
      if (sub) {
        if (group != 2 || trailing) { i = end; continue; }
        underline = e->params[++i]; if (underline > 5) underline = 1;
      }
      pen.attrs = (pen.attrs & ~LP_UNDERLINE_MASK) | (underline << LP_UNDERLINE_SHIFT);
      continue;
    }
    if (p >= 30 && p <= 37) pen.fg = LP_COLOR_INDEXED | (p - 30);
    else if (p >= 40 && p <= 47) pen.bg = LP_COLOR_INDEXED | (p - 40);
    else if (p >= 90 && p <= 97) pen.fg = LP_COLOR_INDEXED | (p - 82);
    else if (p >= 100 && p <= 107) pen.bg = LP_COLOR_INDEXED | (p - 92);
    else switch (p) {
      case 0: pen = (lpage_style){0, 0, 0, 0}; break;
      case 1: pen.attrs |= LP_BOLD; break;
      case 2: pen.attrs |= LP_FAINT; break;
      case 3: pen.attrs |= LP_ITALIC; break;
      case 5: case 6: pen.attrs |= LP_BLINK; break;
      case 7: pen.attrs |= LP_INVERSE; break;
      case 8: pen.attrs |= LP_INVISIBLE; break;
      case 9: pen.attrs |= LP_STRIKE; break;
      case 21: pen.attrs = (pen.attrs & ~LP_UNDERLINE_MASK) | (2u << LP_UNDERLINE_SHIFT); break;
      case 22: pen.attrs &= ~(LP_BOLD | LP_FAINT); break;
      case 23: pen.attrs &= ~LP_ITALIC; break;
      case 24: pen.attrs &= ~LP_UNDERLINE_MASK; break;
      case 25: pen.attrs &= ~LP_BLINK; break;
      case 27: pen.attrs &= ~LP_INVERSE; break;
      case 28: pen.attrs &= ~LP_INVISIBLE; break;
      case 29: pen.attrs &= ~LP_STRIKE; break;
      case 39: pen.fg = 0; break;
      case 49: pen.bg = 0; break;
      case 53: pen.attrs |= LP_OVERLINE; break;
      case 55: pen.attrs &= ~LP_OVERLINE; break;
      case 59: pen.underline = 0; break;
      default: break;
    }
  }
  bt_set_pen(t, pen);
}
