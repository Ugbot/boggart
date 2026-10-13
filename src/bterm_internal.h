/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Screen.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Private state shared by terminal lifecycle, CSI dispatch and SGR parsing.
 */
#ifndef BOGGART_BTERM_INTERNAL_H
#define BOGGART_BTERM_INTERNAL_H
#include "bterm.h"
#include "lvt.h"
typedef struct { size_t x, y; bool pending_wrap; } bt_cursor;
typedef struct { bt_cursor cursor; lpage_style pen; bool origin, valid; } bt_saved;
typedef struct {
  lpage_screen *screen;
  bt_cursor cursor;
  bt_saved saved;
  uint32_t pen_id;
  uint32_t hyperlink_id;
  bool pen_valid;
} bt_buffer;
typedef struct bt_notifications bt_notifications;
struct bterm {
  lvt_parser parser;
  bt_buffer buffers[2];
  unsigned active;
  size_t columns, rows, top, bottom;
  uint32_t modes, last_printed;
  unsigned cursor_style;
  bmouse_mode mouse_mode;
  bmouse_format mouse_format;
  bmouse_motion mouse_motion;
  uint32_t mouse_cell_width, mouse_cell_height;
  lpage_style pen;
  bool tabs[4096], failed;
  bterm_reply reply;
  void *reply_context;
  bterm_event_sink event_sink;
  void *event_context;
  bool clipboard_read, clipboard_write;
  bt_notifications *notifications;
};
static inline bt_buffer *bt_active(bterm *t) { return &t->buffers[t->active]; }
void bt_set_pen(bterm *t, lpage_style pen);
void bt_set_link(bterm *t, llink_value value);
void bt_end_link(bterm *t);
void bt_print(bterm *t, uint32_t codepoint);
void bt_index(bterm *t, bool reverse);
void bt_home(bterm *t);
void bt_move(bterm *t, int dy, int dx);
void bt_position(bterm *t, size_t y, size_t x);
void bt_save(bterm *t);
void bt_restore(bterm *t);
void bt_alternate(bterm *t, bool enabled, unsigned mode);
void bt_erase(bterm *t, size_t row, size_t column, size_t count);
void bt_scroll(bterm *t, size_t top, size_t bottom, int amount, bool history);
void bt_edit(bterm *t, size_t count, bool insert);
void bt_tab(bterm *t, size_t count, bool backward);
void bt_reply(bterm *t, const char *bytes, size_t length);
void bt_csi(bterm *t, const lvt_event *event);
void bt_sgr(bterm *t, const lvt_event *event);
void bt_osc(bterm *t, const lvt_event *event);
void bt_emit(bterm *t, const bosc_command *command);
#endif
