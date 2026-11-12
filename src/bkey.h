/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/key.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/key_mods.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: normalized functional keys and explicit physical/layout scalars.
 */
#ifndef BOGGART_BKEY_H
#define BOGGART_BKEY_H
#include "bmouse.h"
#define BKEY_TEXT_LIMIT 4096
#define BKEY_CAPACITY (BKEY_TEXT_LIMIT * 8 + 96)
enum { BI_SUPER=8u, BI_HYPER=16u, BI_META=32u, BI_CAPS_LOCK=64u, BI_NUM_LOCK=128u };
enum { BK_DISAMBIGUATE=1, BK_EVENTS=2, BK_ALTERNATES=4, BK_ALL=8, BK_ASSOCIATED=16 };
typedef enum {
  BK_TEXT, BK_ESCAPE, BK_ENTER, BK_TAB, BK_BACKSPACE, BK_INSERT, BK_DELETE,
  BK_LEFT, BK_RIGHT, BK_UP, BK_DOWN, BK_PAGE_UP, BK_PAGE_DOWN, BK_HOME, BK_END,
  BK_CAPS_LOCK, BK_SCROLL_LOCK, BK_NUM_LOCK, BK_PRINT_SCREEN, BK_PAUSE,
  BK_F1, BK_F2, BK_F3, BK_F4, BK_F5, BK_F6, BK_F7, BK_F8, BK_F9, BK_F10,
  BK_F11, BK_F12, BK_F13, BK_F14, BK_F15, BK_F16, BK_F17, BK_F18, BK_F19,
  BK_F20, BK_F21, BK_F22, BK_F23, BK_F24, BK_F25,
  BK_KP_0, BK_KP_1, BK_KP_2, BK_KP_3, BK_KP_4, BK_KP_5, BK_KP_6,
  BK_KP_7, BK_KP_8, BK_KP_9, BK_KP_DECIMAL, BK_KP_DIVIDE, BK_KP_MULTIPLY,
  BK_KP_SUBTRACT, BK_KP_ADD, BK_KP_ENTER, BK_KP_EQUAL, BK_KP_SEPARATOR,
  BK_KP_LEFT, BK_KP_RIGHT, BK_KP_UP, BK_KP_DOWN, BK_KP_PAGE_UP, BK_KP_PAGE_DOWN,
  BK_KP_HOME, BK_KP_END, BK_KP_INSERT, BK_KP_DELETE, BK_KP_BEGIN,
  BK_LEFT_SHIFT, BK_LEFT_CTRL, BK_LEFT_ALT, BK_LEFT_SUPER,
  BK_RIGHT_SHIFT, BK_RIGHT_CTRL, BK_RIGHT_ALT, BK_RIGHT_SUPER,
  BK_HELP, BK_MENU, BK_COUNT
} bkey_code;
typedef enum { BK_PRESS, BK_REPEAT, BK_RELEASE } bkey_action;
typedef enum { BK_OPTION_TEXT, BK_OPTION_ALT, BK_OPTION_LEFT, BK_OPTION_RIGHT } bkey_option;
typedef struct {
  bkey_code key; bkey_action action;
  unsigned modifiers, consumed_modifiers, right_modifiers;
  uint32_t unshifted, base_layout;
  bool composing;
  const uint8_t *text; size_t text_length;
} bkey_event;
typedef struct {
  bool application_cursor, application_keypad, backarrow, ignore_keypad_numlock;
  bool alt_prefix, modify_other_keys_2, macos;
  bkey_option option_as_alt;
  unsigned kitty_flags;
} bkey_options;
/* Scalars are Unicode, 0 denotes absent. Right-side bits use SHIFT/ALT/CTRL/
 * SUPER and describe the held modifier side. Held modifier bits must reflect
 * the state after this event, including modifier releases. Consumed modifiers
 * apply only when text is nonempty. Text is borrowed valid UTF-8 <=4096 bytes.
 * Output must not alias text/event/options. Required pointers must be non-NULL.
 * Invalid input or insufficient capacity leaves output unchanged, length=0.
 * Suppressed events succeed with length=0. Encoding never allocates. */
bool bkey_encode(const bkey_event *event, const bkey_options *options,
                  uint8_t *output, size_t capacity, size_t *length);
const char *bkey_name(bkey_code key);
bool bkey_from_name(const char *name, size_t length, bkey_code *key);
#endif
