/* Boggart's headless terminal: one owner thread, no Lua/PTY/window dependency. */
#ifndef BOGGART_BTERM_H
#define BOGGART_BTERM_H
#include "lpage.h"
#include "lvt.h"
#include "bosc.h"
#include "bmouse.h"
#include "bkey.h"
#include "bpaste.h"
typedef struct bterm bterm;
enum {
  BT_AUTOWRAP = 1u << 0, BT_ORIGIN = 1u << 1, BT_CURSOR_VISIBLE = 1u << 2,
  BT_INSERT = 1u << 3, BT_NEWLINE = 1u << 4, BT_APP_CURSOR = 1u << 5,
  BT_APP_KEYPAD = 1u << 6, BT_BRACKETED_PASTE = 1u << 7, BT_FOCUS = 1u << 8,
  BT_REVERSE_VIDEO = 1u << 9, BT_GRAPHEME = 1u << 10
};
typedef struct {
  size_t x, y, top, bottom;
  uint32_t modes;
  unsigned cursor_style;
  bool alternate, pending_wrap;
  lpage_style pen;
} bterm_status;
typedef struct {
  bmouse_mode mouse_mode; bmouse_format mouse_format;
  unsigned kitty_flags;
  bool backarrow, ignore_keypad_numlock, alt_prefix, modify_other_keys_2;
  bool bracketed_paste, focus_reporting, focused;
} bterm_input_status;
bterm_input_status bterm_input_state(const bterm *terminal);
bkey_options bterm_key_options(const bterm *terminal, bool macos, bkey_option option_as_alt);
bool bterm_key(const bterm *terminal, const bkey_event *event, bool macos, bkey_option option_as_alt,
                uint8_t *output, size_t capacity, size_t *length);
/* Paste transforms bytes for the child using negotiated mode 2004; empty text
 * emits nothing. It does not consult the optional safety heuristic or any
 * clipboard policy. The host decides whether/when to send the returned bytes. */
bool bterm_paste(const bterm *terminal, const uint8_t *data, size_t size,
                  uint8_t *output, size_t capacity, size_t *length);
bool bterm_paste_safe(const bterm *terminal, const uint8_t *data, size_t size);
/* Focus is host state and survives RIS. Successful calls update it even with
 * mode 1004 off; with reporting on they return CSI I/O (3 bytes). Capacity
 * failure changes neither output nor focus. Enabling 1004 emits current host
 * focus through the reply sink. Calls never infer/deduplicate OS transitions. */
bool bterm_focus(bterm *terminal, bool focused, uint8_t *output, size_t capacity, size_t *length);
/* Uses current negotiated mouse modes and terminal geometry. Output is input
 * for the child PTY, distinct from the reply sink. Failure does not fail feed. */
bool bterm_mouse(bterm *terminal, const bmouse_event *event, uint32_t cell_width, uint32_t cell_height,
                  uint8_t *output, size_t capacity, size_t *length);
/* Consume/copy the borrowed reply synchronously. Never re-enter the terminal
 * from this callback. A NULL sink intentionally discards replies. */
typedef bool (*bterm_reply)(void *context, const uint8_t *bytes, size_t length);
typedef struct { bosc_command command; size_t x, y; bool alternate; } bterm_event;
/* Events borrow payloads only during this callback. Copy synchronously; never
 * re-enter the terminal. Delivery is optional and does not imply side effects. */
typedef void (*bterm_event_sink)(void *context, const bterm_event *event);
void bterm_set_event_sink(bterm *terminal, bterm_event_sink sink, void *context);
/* Host policy defaults to deny and survives reset/RIS. */
void bterm_clipboard_policy(bterm *terminal, bool read, bool write);
/* Respond to an allowed OSC 52 query. Denial/invalid text returns false without
 * failing the terminal. The usual reply sink handles successful responses. */
bool bterm_clipboard_reply(bterm *terminal, char selection, bool bel,
                           const uint8_t *text, size_t length);
bterm *bterm_create(size_t columns, size_t rows, size_t history_limit,
                    bterm_reply reply, void *context);
void bterm_destroy(bterm *terminal);
/* false means allocation/reply failure: later feed/finish fail until reset.
 * Stream consumption and grid mutations before failure are not rolled back. */
bool bterm_feed(bterm *terminal, const uint8_t *bytes, size_t length);
bool bterm_finish(bterm *terminal);
bool bterm_reset(bterm *terminal);
/* Resize both allocated screens, reflowing primary when autowrap is enabled.
 * Dimensions are in 1..4096; same geometry is a no-op. Allocation/validation
 * failure preserves both screens and all state, and does not poison feed.
 * Success resets margins and width-dependent tabs, damages both screens, and
 * invalidates mouse motion. Parser fragments, queues and modes survive. */
bool bterm_resize(bterm *terminal, size_t columns, size_t rows);
/* Prepare both screens, then check the host resize before allocation-free
 * commit. The check may update host geometry, but must not mutate/reenter the
 * terminal. Failure preserves terminal geometry and ownership. */
bool bterm_resize_guarded(bterm *terminal, size_t columns, size_t rows, bool (*check)(void *), void *context);
bterm_status bterm_state(const bterm *terminal);
/* Screen/style borrows expire on mutation. IDs belong to the active screen. */
const lpage_screen *bterm_screen(const bterm *terminal);
const lpage_style *bterm_style(const bterm *terminal, uint32_t id);
const llink_value *bterm_link(const bterm *terminal, uint32_t id);
/* Diagnostic stream state, borrowed until the next feed/reset. */
const lvt_parser *bterm_parser(const bterm *terminal);
void bterm_ack_damage(bterm *terminal);
#endif
