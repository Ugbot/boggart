/* Boggart's headless terminal: one owner thread, no Lua/PTY/window dependency. */
#ifndef BOGGART_BTERM_H
#define BOGGART_BTERM_H
#include "lpage.h"
#include "lvt.h"
typedef struct bterm bterm;
enum {
  BT_AUTOWRAP = 1u << 0, BT_ORIGIN = 1u << 1, BT_CURSOR_VISIBLE = 1u << 2,
  BT_INSERT = 1u << 3, BT_NEWLINE = 1u << 4, BT_APP_CURSOR = 1u << 5,
  BT_APP_KEYPAD = 1u << 6, BT_BRACKETED_PASTE = 1u << 7, BT_FOCUS = 1u << 8,
  BT_REVERSE_VIDEO = 1u << 9
};
typedef struct {
  size_t x, y, top, bottom;
  uint32_t modes;
  unsigned cursor_style;
  bool alternate, pending_wrap;
  lpage_style pen;
} bterm_status;
/* Consume/copy the borrowed reply synchronously. Never re-enter the terminal
 * from this callback. A NULL sink intentionally discards replies. */
typedef bool (*bterm_reply)(void *context, const uint8_t *bytes, size_t length);
bterm *bterm_create(size_t columns, size_t rows, size_t history_limit,
                    bterm_reply reply, void *context);
void bterm_destroy(bterm *terminal);
/* false means allocation/reply failure: later feed/finish fail until reset.
 * Stream consumption and grid mutations before failure are not rolled back. */
bool bterm_feed(bterm *terminal, const uint8_t *bytes, size_t length);
bool bterm_finish(bterm *terminal);
bool bterm_reset(bterm *terminal);
bterm_status bterm_state(const bterm *terminal);
/* Screen/style borrows expire on mutation. IDs belong to the active screen. */
const lpage_screen *bterm_screen(const bterm *terminal);
const lpage_style *bterm_style(const bterm *terminal, uint32_t id);
/* Diagnostic stream state, borrowed until the next feed/reset. */
const lvt_parser *bterm_parser(const bterm *terminal);
void bterm_ack_damage(bterm *terminal);
#endif
