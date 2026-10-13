/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Screen.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/stream.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/key_encode.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/modes.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: fixed geometry and scalar cells; Unicode/reflow follow separately.
 */
#include "bterm_internal.h"
#include <stdlib.h>
#include <string.h>
static void require(bterm *t, bool ok) { if (!ok) t->failed = true; }
void bt_end_link(bterm *t) {
  bt_buffer *b = bt_active(t);
  if (b->hyperlink_id) llink_release(lpage_links(b->screen), b->hyperlink_id);
  b->hyperlink_id = 0;
}
void bt_set_link(bterm *t, llink_value value) {
  uint32_t id;
  if (!llink_acquire(lpage_links(bt_active(t)->screen), &value, &id)) { t->failed = true; return; }
  bt_end_link(t); bt_active(t)->hyperlink_id = id;
}
void bt_set_pen(bterm *t, lpage_style pen) {
  for (unsigned i = 0; i < 2; i++) {
    bt_buffer *b = &t->buffers[i];
    if (b->pen_valid) lstyle_release(lpage_styles(b->screen), b->pen_id);
    b->pen_valid = false;
  }
  t->pen = pen;
}
static bool pen_id(bterm *t, uint32_t *id) {
  bt_buffer *b = bt_active(t);
  if (!b->pen_valid) {
    if (!lstyle_acquire(lpage_styles(b->screen), &t->pen, &b->pen_id)) { t->failed = true; return false; }
    b->pen_valid = true;
  }
  *id = b->pen_id; return true;
}
static bool blank_id(bterm *t, uint32_t *id) {
  lpage_style blank = {0, t->pen.bg, 0, 0};
  bool ok = lstyle_acquire(lpage_styles(bt_active(t)->screen), &blank, id);
  require(t, ok); return ok;
}
void bt_erase(bterm *t, size_t y, size_t x, size_t n) {
  uint32_t id; if (!blank_id(t, &id)) return;
  lpage_screen *s = bt_active(t)->screen;
  require(t, lpage_erase(s, y, x, n, id)); lstyle_release(lpage_styles(s), id);
}
void bt_scroll(bterm *t, size_t top, size_t bottom, int amount, bool history) {
  uint32_t id; if (!blank_id(t, &id)) return;
  lpage_screen *s = bt_active(t)->screen;
  require(t, lpage_scroll(s, top, bottom, amount, history && !t->active, id));
  lstyle_release(lpage_styles(s), id);
}
void bt_edit(bterm *t, size_t n, bool insert) {
  uint32_t id; if (!blank_id(t, &id)) return;
  bt_buffer *b = bt_active(t);
  require(t, insert ? lpage_insert_cells(b->screen, b->cursor.y, b->cursor.x, n, id)
    : lpage_delete_cells(b->screen, b->cursor.y, b->cursor.x, n, id));
  lstyle_release(lpage_styles(b->screen), id);
}
void bt_home(bterm *t) { bt_active(t)->cursor = (bt_cursor){0, t->modes & BT_ORIGIN ? t->top : 0, false}; }
void bt_position(bterm *t, size_t y, size_t x) {
  size_t top = t->modes & BT_ORIGIN ? t->top : 0;
  size_t bottom = t->modes & BT_ORIGIN ? t->bottom : t->rows - 1;
  if (y > bottom - top) y = bottom - top;
  bt_active(t)->cursor = (bt_cursor){ x < t->columns ? x : t->columns - 1, top + y, false };
}
void bt_move(bterm *t, int dy, int dx) {
  bt_cursor *c = &bt_active(t)->cursor;
  size_t top = 0, bottom = t->rows - 1;
  if (t->modes & BT_ORIGIN || (c->y >= t->top && c->y <= t->bottom)) { top = t->top; bottom = t->bottom; }
  int64_t y = (int64_t)c->y + dy, x = (int64_t)c->x + dx;
  c->y = y < (int64_t)top ? top : y > (int64_t)bottom ? bottom : (size_t)y;
  c->x = x < 0 ? 0 : x >= (int64_t)t->columns ? t->columns - 1 : (size_t)x;
  c->pending_wrap = false;
}
void bt_index(bterm *t, bool reverse) {
  bt_cursor *c = &bt_active(t)->cursor;
  c->pending_wrap = false;
  if (reverse) {
    if (c->y == t->top) bt_scroll(t, t->top, t->bottom, -1, false);
    else if (c->y) c->y--;
  } else {
    if (c->y == t->bottom) bt_scroll(t, t->top, t->bottom, 1, true);
    else if (c->y + 1 < t->rows) c->y++;
  }
}
void bt_print(bterm *t, uint32_t cp) {
  bt_buffer *b = bt_active(t); bt_cursor *c = &b->cursor;
  if (c->pending_wrap) {
    if (t->modes & BT_AUTOWRAP) {
      lpage_wrap(b->screen, c->y, true); bt_index(t, false); c->x = 0;
    } else c->pending_wrap = false;
  }
  if (t->modes & BT_INSERT) bt_edit(t, 1, true);
  uint32_t id; if (t->failed || !pen_id(t, &id)) return;
  require(t, lpage_put(b->screen, c->y, c->x, (lpage_cell){cp, id, b->hyperlink_id, 1, 0, 0}));
  t->last_printed = cp;
  if (c->x + 1 == t->columns) c->pending_wrap = (t->modes & BT_AUTOWRAP) != 0;
  else c->x++;
}
void bt_tab(bterm *t, size_t n, bool backward) {
  bt_cursor *c = &bt_active(t)->cursor; c->pending_wrap = false;
  /* At most columns traversals, even for a saturated repeat parameter. */
  while (n--) {
    size_t x = c->x;
    do { if (backward) { if (!x) break; x--; } else { if (x + 1 == t->columns) break; x++; } }
    while (!t->tabs[x]);
    if (x == c->x) break;
    c->x = x;
  }
}
void bt_save(bterm *t) {
  bt_buffer *b = bt_active(t);
  b->saved = (bt_saved){ b->cursor, t->pen, (t->modes & BT_ORIGIN) != 0, true };
}
void bt_restore(bterm *t) {
  bt_end_link(t);
  bt_buffer *b = bt_active(t);
  if (!b->saved.valid) { bt_home(t); return; }
  b->cursor = b->saved.cursor; bt_set_pen(t, b->saved.pen);
  if (b->saved.origin) t->modes |= BT_ORIGIN; else t->modes &= ~BT_ORIGIN;
}
void bt_alternate(bterm *t, bool enabled, unsigned mode) {
  if (enabled == (t->active != 0)) return;
  if (enabled) {
    if (!t->buffers[1].screen) {
      t->buffers[1].screen = lpage_create(t->columns, t->rows, 0);
      if (!t->buffers[1].screen) { t->failed = true; return; }
    }
    if (mode == 1049) bt_save(t);
    bt_end_link(t);
    t->active = 1;
    if (mode == 1049) {
      for (size_t y = 0; y < t->rows; y++) bt_erase(t, y, 0, t->columns);
      bt_home(t);
    }
  } else {
    bt_end_link(t);
    if (mode == 1047) for (size_t y = 0; y < t->rows; y++) bt_erase(t, y, 0, t->columns);
    t->active = 0;
    if (mode == 1049) bt_restore(t);
  }
  lpage_damage_all(bt_active(t)->screen);
  t->mouse_motion.valid = false;
}
void bt_reply(bterm *t, const char *bytes, size_t length) {
  if (t->reply) require(t, t->reply(t->reply_context, (const uint8_t *)bytes, length));
}
static void escape(bterm *t, const lvt_event *e) {
  if (e->nintermediates) return;
  switch (e->final) {
    case 'D': bt_index(t, false); break;
    case 'E': bt_index(t, false); bt_active(t)->cursor.x = 0; break;
    case 'M': bt_index(t, true); break;
    case 'H': t->tabs[bt_active(t)->cursor.x] = true; break;
    case '7': bt_save(t); break;
    case '8': bt_restore(t); break;
    case '=': t->modes |= BT_APP_KEYPAD; break;
    case '>': t->modes &= ~BT_APP_KEYPAD; break;
    case 'c': require(t, bterm_reset(t)); break;
    default: break;
  }
}
static void event(void *context, const lvt_event *e) {
  bterm *t = context;
  if (t->failed) return;
  switch (e->type) {
    case LVT_PRINT: bt_print(t, e->codepoint); break;
    case LVT_ESC: escape(t, e); break;
    case LVT_CSI: bt_csi(t, e); break;
    case LVT_OSC: bt_osc(t, e); break;
    case LVT_EXECUTE:
      switch (e->codepoint) {
        case 0x07: { bosc_command c = {0}; c.type = BOSC_BELL; bt_emit(t, &c); break; }
        case 0x08: bt_move(t, 0, -1); break;
        case 0x09: bt_tab(t, 1, false); break;
        case 0x0a: case 0x0b: case 0x0c: case 0x84:
          bt_index(t, false); if (t->modes & BT_NEWLINE) bt_active(t)->cursor.x = 0; break;
        case 0x0d: bt_active(t)->cursor.x = 0; bt_active(t)->cursor.pending_wrap = false; break;
        case 0x85: bt_index(t, false); bt_active(t)->cursor.x = 0; break;
        case 0x8d: bt_index(t, true); break;
        default: break;
      }
      break;
    default: break; /* DCS and APC have separate tickets. */
  }
}
bterm *bterm_create(size_t columns, size_t rows, size_t history_limit, bterm_reply reply, void *context) {
  bterm *t = calloc(1, sizeof *t);
  if (!t) return NULL;
  t->buffers[0].screen = lpage_create(columns, rows, history_limit);
  if (!t->buffers[0].screen) { free(t); return NULL; }
  t->columns = columns; t->rows = rows; t->reply = reply; t->reply_context = context;
  t->bottom = rows - 1; t->modes = BT_AUTOWRAP | BT_CURSOR_VISIBLE;
  t->ignore_keypad_numlock = t->alt_prefix = true;
  for (size_t x = 8; x < columns; x += 8) t->tabs[x] = true;
  lvt_init(&t->parser); return t;
}
void bterm_destroy(bterm *t) {
  if (t) { lpage_destroy(t->buffers[0].screen); lpage_destroy(t->buffers[1].screen); free(t->notifications); free(t); }
}
bool bterm_feed(bterm *t, const uint8_t *bytes, size_t length) {
  if (t->failed) return false;
  lvt_feed(&t->parser, bytes, length, event, t); return !t->failed;
}
bool bterm_finish(bterm *t) { if (t->failed) return false; lvt_finish(&t->parser, event, t); return !t->failed; }
bool bterm_reset(bterm *t) {
  free(t->notifications); t->notifications = NULL;
  t->failed = false; bt_set_pen(t, (lpage_style){0, 0, 0, 0});
  for (unsigned i = 0; i < 2; i++) {
    bt_buffer *b = &t->buffers[i];
    memset(b->kitty_flags, 0, sizeof b->kitty_flags); b->kitty_index = 0;
    if (!b->screen) continue;
    if (b->hyperlink_id) llink_release(lpage_links(b->screen), b->hyperlink_id);
    b->hyperlink_id = 0;
    b->cursor = (bt_cursor){0, 0, false}; b->saved.valid = false;
    lpage_clear_history(b->screen);
    for (size_t y = 0; y < t->rows; y++) require(t, lpage_erase(b->screen, y, 0, t->columns, 0));
    lpage_damage_all(b->screen);
  }
  t->active = 0; t->top = 0; t->bottom = t->rows - 1;
  t->modes = BT_AUTOWRAP | BT_CURSOR_VISIBLE; t->last_printed = t->cursor_style = 0;
  t->mouse_mode = BM_NONE; t->mouse_format = BM_FORMAT_X10;
  t->mouse_motion.valid = false; t->mouse_cell_width = t->mouse_cell_height = 0;
  t->backarrow = t->modify_other_keys_2 = false;
  t->ignore_keypad_numlock = t->alt_prefix = true;
  memset(t->tabs, 0, sizeof t->tabs);
  for (size_t x = 8; x < t->columns; x += 8) t->tabs[x] = true;
  lvt_init(&t->parser); return !t->failed;
}
bterm_status bterm_state(const bterm *t) {
  const bt_cursor *c = &t->buffers[t->active].cursor;
  return (bterm_status){ c->x, c->y, t->top, t->bottom, t->modes, t->cursor_style, t->active != 0, c->pending_wrap, t->pen };
}
const lpage_screen *bterm_screen(const bterm *t) { return t->buffers[t->active].screen; }
const llink_value *bterm_link(const bterm *t, uint32_t id) { return lpage_link(bterm_screen(t), id); }
const lpage_style *bterm_style(const bterm *t, uint32_t id) { return lstyle_get(lpage_styles(t->buffers[t->active].screen), id); }
void bterm_ack_damage(bterm *t) { lpage_ack_damage(bt_active(t)->screen); }
const lvt_parser *bterm_parser(const bterm *t) { return &t->parser; }
bterm_input_status bterm_input_state(const bterm *t) {
  const bt_buffer *b=&t->buffers[t->active];
  return (bterm_input_status){t->mouse_mode,t->mouse_format,b->kitty_flags[b->kitty_index],t->backarrow,t->ignore_keypad_numlock,t->alt_prefix,t->modify_other_keys_2};
}
bkey_options bterm_key_options(const bterm *t, bool macos, bkey_option option) {
  bterm_input_status s=bterm_input_state(t);
  return (bkey_options){(t->modes&BT_APP_CURSOR)!=0,(t->modes&BT_APP_KEYPAD)!=0,s.backarrow,s.ignore_keypad_numlock,s.alt_prefix,s.modify_other_keys_2,macos,option,s.kitty_flags};
}
bool bterm_key(const bterm *t,const bkey_event *event,bool macos,bkey_option option,uint8_t *output,size_t capacity,size_t *length){
  bkey_options o=bterm_key_options(t,macos,option);return bkey_encode(event,&o,output,capacity,length);
}
bool bterm_mouse(bterm *t, const bmouse_event *event, uint32_t width, uint32_t height,
                  uint8_t *output, size_t capacity, size_t *length) {
  bmouse_options options = { t->mouse_mode, t->mouse_format, (uint32_t)t->columns, (uint32_t)t->rows, width, height };
  bmouse_motion last = t->mouse_motion;
  if (width != t->mouse_cell_width || height != t->mouse_cell_height) last.valid = false;
  if (!bmouse_encode(event, &options, &last, output, capacity, length)) return false;
  t->mouse_motion = last; t->mouse_cell_width = width; t->mouse_cell_height = height;
  return true;
}
