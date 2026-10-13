/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/stream.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: focused CSI commands, C screen operations and an explicit reply
 * sink. Unimplemented extensions do not reach the application or renderer.
 */
#include "bterm_internal.h"
#include <stdio.h>
static size_t parameter(const lvt_event *e, size_t i, size_t fallback) {
  return i < e->nparams && e->params[i] ? e->params[i] : fallback;
}
static void mode(bterm *t, unsigned p, bool private_mode, bool enabled) {
  uint32_t bit = 0;
  if (private_mode) switch (p) {
    case 1: bit = BT_APP_CURSOR; break;
    case 5: bit = BT_REVERSE_VIDEO; lpage_damage_all(bt_active(t)->screen); break;
    case 6: bit = BT_ORIGIN; break;
    case 7: bit = BT_AUTOWRAP; bt_active(t)->cursor.pending_wrap = false; break;
    case 25: bit = BT_CURSOR_VISIBLE; break;
    case 47: case 1047: case 1049: bt_alternate(t, enabled, p); return;
    case 1048: if (enabled) bt_save(t); else bt_restore(t); return;
    case 1004: bit = BT_FOCUS; break;
    case 2004: bit = BT_BRACKETED_PASTE; break;
    default: return;
  } else switch (p) {
    case 4: bit = BT_INSERT; break;
    case 20: bit = BT_NEWLINE; break;
    default: return;
  }
  if (enabled) t->modes |= bit; else t->modes &= ~bit;
  if (bit == BT_ORIGIN) bt_home(t);
}
static void display_erase(bterm *t, unsigned p) {
  bt_cursor c = bt_active(t)->cursor;
  if (p == 3) { lpage_clear_history(t->buffers[0].screen); return; }
  if (p > 2) return;
  if (p == 0) {
    bt_erase(t, c.y, c.x, t->columns - c.x);
    for (size_t y = c.y + 1; y < t->rows; y++) bt_erase(t, y, 0, t->columns);
  } else if (p == 1) {
    for (size_t y = 0; y < c.y; y++) bt_erase(t, y, 0, t->columns);
    bt_erase(t, c.y, 0, c.x + 1);
  } else for (size_t y = 0; y < t->rows; y++) bt_erase(t, y, 0, t->columns);
}
static void device_reply(bterm *t, const lvt_event *e, uint8_t prefix) {
  unsigned p = e->nparams ? e->params[0] : 0;
  if (e->final == 'c') {
    if (p) return;
    if (!prefix) bt_reply(t, "\033[?1;2c", 7);
    else if (prefix == '>') bt_reply(t, "\033[>0;1;0c", 9);
  } else if (p == 5 && !prefix) bt_reply(t, "\033[0n", 4);
  else if (p == 6 && (!prefix || prefix == '?')) {
    bt_cursor c = bt_active(t)->cursor;
    size_t row = c.y + 1;
    if (t->modes & BT_ORIGIN) row -= t->top;
    char bytes[64];
    int n = snprintf(bytes, sizeof bytes, "\033[%s%zu;%zuR", prefix ? "?" : "", row, c.x + 1);
    if (n > 0 && (size_t)n < sizeof bytes) bt_reply(t, bytes, (size_t)n);
  }
}
void bt_csi(bterm *t, const lvt_event *e) {
  uint8_t prefix = e->nintermediates == 1 ? e->intermediates[0] : 0;
  if (e->nintermediates > 1) return;
  if (e->final == 'h' || e->final == 'l') {
    if (e->nintermediates && prefix != '?') return;
    for (size_t i = 0; i < e->nparams && !t->failed; i++) mode(t, e->params[i], prefix == '?', e->final == 'h');
    return;
  }
  if (e->final == 'm') { if (!e->nintermediates) bt_sgr(t, e); return; }
  if (e->final == 'c' || e->final == 'n') {
    if (e->nparams <= 1 && (!e->nintermediates || prefix == '?' || prefix == '>')) device_reply(t, e, prefix);
    return;
  }
  if (e->final == 'q' && prefix == ' ' && e->nparams <= 1) {
    unsigned style = e->nparams ? e->params[0] : 0;
    if (style <= 6) t->cursor_style = style;
    return;
  }
  if (e->nintermediates) return;
  bt_cursor *c = &bt_active(t)->cursor;
  int n = (int)parameter(e, 0, 1);
  /* CUP/margins take at most two values, other commands at most one. */
  if (e->nparams > (e->final == 'H' || e->final == 'f' || e->final == 'r' ? 2u : 1u)) return;
  switch (e->final) {
    case 'A': case 'k': bt_move(t, -n, 0); break;
    case 'B': case 'e': bt_move(t, n, 0); break;
    case 'C': case 'a': bt_move(t, 0, n); break;
    case 'D': case 'j': bt_move(t, 0, -n); break;
    case 'E': bt_move(t, n, 0); c->x = 0; break;
    case 'F': bt_move(t, -n, 0); c->x = 0; break;
    case 'G': case '`': c->x = (size_t)n < t->columns ? (size_t)n - 1 : t->columns - 1; c->pending_wrap = false; break;
    case 'd': bt_position(t, (size_t)n - 1, c->x); break;
    case 'H': case 'f': bt_position(t, parameter(e, 0, 1) - 1, parameter(e, 1, 1) - 1); break;
    case 'J': display_erase(t, e->nparams ? e->params[0] : 0); break;
    case 'K': {
      unsigned p = e->nparams ? e->params[0] : 0;
      if (p == 0) bt_erase(t, c->y, c->x, t->columns - c->x);
      else if (p == 1) bt_erase(t, c->y, 0, c->x + 1);
      else if (p == 2) bt_erase(t, c->y, 0, t->columns);
      break;
    }
    case 'X': bt_erase(t, c->y, c->x, (size_t)n); break;
    case '@': bt_edit(t, (size_t)n, true); c->pending_wrap = false; break;
    case 'P': bt_edit(t, (size_t)n, false); c->pending_wrap = false; break;
    case 'L': case 'M':
      if (c->y >= t->top && c->y <= t->bottom) {
        bt_scroll(t, c->y, t->bottom, e->final == 'L' ? -n : n, false);
        c->x = 0; c->pending_wrap = false;
      }
      break;
    case 'S': bt_scroll(t, t->top, t->bottom, n, true); c->pending_wrap = false; break;
    case 'T': bt_scroll(t, t->top, t->bottom, -n, false); c->pending_wrap = false; break;
    case 'I': bt_tab(t, (size_t)n, false); break;
    case 'Z': bt_tab(t, (size_t)n, true); break;
    case 'g': {
      unsigned p = e->nparams ? e->params[0] : 0;
      if (p == 0) t->tabs[c->x] = false;
      else if (p == 3) for (size_t x = 0; x < t->columns; x++) t->tabs[x] = false;
      break;
    }
    case 'r': {
      size_t top = parameter(e, 0, 1), bottom = parameter(e, 1, t->rows);
      if (top < bottom && bottom <= t->rows) { t->top = top - 1; t->bottom = bottom - 1; bt_home(t); }
      break;
    }
    case 's': if (!e->nparams) bt_save(t); break;
    case 'u': if (!e->nparams) bt_restore(t); break;
    case 'b': if (t->last_printed) for (int i = 0; i < n && !t->failed; i++) bt_print(t, t->last_printed); break;
    default: break;
  }
}
