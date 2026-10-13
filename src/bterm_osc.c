/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/osc/parsers/kitty_desktop_notification.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: host event sinks and eight bounded title/body assemblies.
 */
#include "bterm_internal.h"
#include <stdlib.h>
#include <string.h>
#define NOTIFICATION_SLOTS 8
typedef struct {
  uint8_t id[256], text[BOSC_MAX_PAYLOAD];
  size_t id_length, title_length, body_length;
  unsigned urgency;
  bool used, overflow;
} notification;
struct bt_notifications { notification slots[NOTIFICATION_SLOTS]; bool saturated; };
void bterm_set_event_sink(bterm *t, bterm_event_sink sink, void *context) {
  t->event_sink = sink; t->event_context = context;
}
void bterm_clipboard_policy(bterm *t, bool read, bool write) {
  t->clipboard_read = read; t->clipboard_write = write;
}
void bt_emit(bterm *t, const bosc_command *c) {
  if (t->event_sink) {
    bt_cursor cursor = bt_active(t)->cursor;
    bterm_event event = {*c, cursor.x, cursor.y, t->active != 0};
    t->event_sink(t->event_context, &event);
  }
}
static notification *find(bterm *t, bosc_slice id) {
  if (!t->notifications) return NULL;
  for (size_t i = 0; i < NOTIFICATION_SLOTS; i++) {
    notification *n = &t->notifications->slots[i];
    if (n->used && id.length == n->id_length && (!id.length || !memcmp(id.data, n->id, id.length))) return n;
  }
  return NULL;
}
static void notify(bterm *t, bosc_command *c) {
  notification *n = find(t, c->value.notify.id);
  if (c->value.notify.payload == BOSC_NOTIFY_CLOSE || c->value.notify.payload == BOSC_NOTIFY_QUERY) {
    if (n && c->value.notify.payload == BOSC_NOTIFY_CLOSE) n->used = false;
    bt_emit(t, c); return;
  }
  if (!n && t->notifications && t->notifications->saturated) return;
  if (!n && c->value.notify.done) { bt_emit(t, c); return; }
  if (!n) {
    if (!t->notifications) t->notifications = calloc(1, sizeof *t->notifications);
    if (!t->notifications) return; /* Notification pressure cannot freeze output. */
    for (size_t i = 0; i < NOTIFICATION_SLOTS; i++) if (!t->notifications->slots[i].used) {
      n = &t->notifications->slots[i]; memset(n, 0, sizeof *n); n->used = true; n->urgency = 1;
      n->id_length = c->value.notify.id.length;
      if (n->id_length) memcpy(n->id, c->value.notify.id.data, n->id_length);
      break;
    }
    if (!n) {
      /* Remember lost chunks conservatively until reset. Otherwise a later
       * tail could masquerade as a complete notification after a slot frees. */
      t->notifications->saturated = true; return;
    }
  }
  if (c->value.notify.urgency_set) n->urgency = c->value.notify.urgency;
  size_t added = c->value.notify.title.length + c->value.notify.body.length;
  if (added > BOSC_MAX_PAYLOAD - n->title_length - n->body_length) n->overflow = true;
  if (!n->overflow) {
    bosc_slice title = c->value.notify.title, body = c->value.notify.body;
    if (title.length) {
      memmove(n->text + n->title_length + title.length, n->text + n->title_length, n->body_length);
      memcpy(n->text + n->title_length, title.data, title.length); n->title_length += title.length;
    }
    if (body.length) { memcpy(n->text + n->title_length + n->body_length, body.data, body.length); n->body_length += body.length; }
  }
  if (c->value.notify.done) {
    if (!n->overflow) {
      c->value.notify.id = (bosc_slice){n->id, n->id_length};
      c->value.notify.title = (bosc_slice){n->text, n->title_length};
      c->value.notify.body = (bosc_slice){n->text + n->title_length, n->body_length};
      c->value.notify.urgency = n->urgency;
      bt_emit(t, c);
    }
    n->used = false;
  }
}
void bt_osc(bterm *t, const lvt_event *event) {
  uint8_t scratch[BOSC_MAX_PAYLOAD]; bosc_command c;
  if (!bosc_parse(event->data, event->length, event->final == 7, scratch, &c)) return;
  if (c.type == BOSC_HYPERLINK) {
    bt_set_link(t, (llink_value){ (const char *)c.value.link.id.data, (const char *)c.value.link.uri.data,
      c.value.link.id.length, c.value.link.uri.length });
    if (t->failed) return;
  }
  if (c.type == BOSC_CLIPBOARD && !(c.value.clipboard.query ? t->clipboard_read : t->clipboard_write)) return;
  if (c.type == BOSC_NOTIFY && c.code == 99) notify(t, &c); else bt_emit(t, &c);
}
bool bterm_clipboard_reply(bterm *t, char selection, bool bel, const uint8_t *text, size_t length) {
  if (!t->clipboard_read || t->failed || !selection || !strchr("cps01234567", selection)
      || length > 3072 || !bosc_text((bosc_slice){text, length}, true)) return false;
  static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  char output[4112] = "\033]52;c;"; size_t written = 7; output[5] = selection;
  for (size_t i = 0; i < length; i += 3) {
    size_t remaining = length - i;
    uint32_t v = (uint32_t)text[i] << 16;
    if (remaining > 1) v |= (uint32_t)text[i + 1] << 8;
    if (remaining > 2) v |= text[i + 2];
    output[written++] = alphabet[v >> 18]; output[written++] = alphabet[(v >> 12) & 63];
    output[written++] = remaining > 1 ? alphabet[(v >> 6) & 63] : '=';
    output[written++] = remaining > 2 ? alphabet[v & 63] : '=';
  }
  output[written++] = bel ? '\a' : '\033'; if (!bel) output[written++] = '\\';
  bt_reply(t, output, written); return !t->failed;
}
