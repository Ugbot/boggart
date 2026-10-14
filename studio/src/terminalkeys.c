#include "terminalkeys.h"
unsigned terminal_modifiers(SDL_Keymod mods) {
  return ((mods&SDL_KMOD_SHIFT) ? BI_SHIFT : 0) | ((mods&SDL_KMOD_ALT) ? BI_ALT : 0)
    | ((mods&SDL_KMOD_CTRL) ? BI_CTRL : 0) | ((mods&SDL_KMOD_GUI) ? BI_SUPER : 0)
    | ((mods&SDL_KMOD_CAPS) ? BI_CAPS_LOCK : 0) | ((mods&SDL_KMOD_NUM) ? BI_NUM_LOCK : 0);
}
static bkey_code functional(SDL_Scancode code) {
  if (code>=SDL_SCANCODE_F1 && code<=SDL_SCANCODE_F12) return (bkey_code)(BK_F1+code-SDL_SCANCODE_F1);
  if (code>=SDL_SCANCODE_F13 && code<=SDL_SCANCODE_F24) return (bkey_code)(BK_F13+code-SDL_SCANCODE_F13);
  if (code>=SDL_SCANCODE_KP_1 && code<=SDL_SCANCODE_KP_9) return (bkey_code)(BK_KP_1+code-SDL_SCANCODE_KP_1);
  switch (code) {
    case SDL_SCANCODE_ESCAPE:return BK_ESCAPE; case SDL_SCANCODE_RETURN:return BK_ENTER;
    case SDL_SCANCODE_TAB:return BK_TAB; case SDL_SCANCODE_BACKSPACE:return BK_BACKSPACE;
    case SDL_SCANCODE_INSERT:return BK_INSERT; case SDL_SCANCODE_DELETE:return BK_DELETE;
    case SDL_SCANCODE_LEFT:return BK_LEFT; case SDL_SCANCODE_RIGHT:return BK_RIGHT;
    case SDL_SCANCODE_UP:return BK_UP; case SDL_SCANCODE_DOWN:return BK_DOWN;
    case SDL_SCANCODE_PAGEUP:return BK_PAGE_UP; case SDL_SCANCODE_PAGEDOWN:return BK_PAGE_DOWN;
    case SDL_SCANCODE_HOME:return BK_HOME; case SDL_SCANCODE_END:return BK_END;
    case SDL_SCANCODE_CAPSLOCK:return BK_CAPS_LOCK; case SDL_SCANCODE_SCROLLLOCK:return BK_SCROLL_LOCK;
    case SDL_SCANCODE_NUMLOCKCLEAR:return BK_NUM_LOCK; case SDL_SCANCODE_PRINTSCREEN:return BK_PRINT_SCREEN;
    case SDL_SCANCODE_PAUSE:return BK_PAUSE; case SDL_SCANCODE_KP_0:return BK_KP_0;
    case SDL_SCANCODE_KP_PERIOD:return BK_KP_DECIMAL; case SDL_SCANCODE_KP_DIVIDE:return BK_KP_DIVIDE;
    case SDL_SCANCODE_KP_MULTIPLY:return BK_KP_MULTIPLY; case SDL_SCANCODE_KP_MINUS:return BK_KP_SUBTRACT;
    case SDL_SCANCODE_KP_PLUS:return BK_KP_ADD; case SDL_SCANCODE_KP_ENTER:return BK_KP_ENTER;
    case SDL_SCANCODE_KP_EQUALS:return BK_KP_EQUAL; case SDL_SCANCODE_KP_COMMA:return BK_KP_SEPARATOR;
    case SDL_SCANCODE_LSHIFT:return BK_LEFT_SHIFT; case SDL_SCANCODE_RSHIFT:return BK_RIGHT_SHIFT;
    case SDL_SCANCODE_LCTRL:return BK_LEFT_CTRL; case SDL_SCANCODE_RCTRL:return BK_RIGHT_CTRL;
    case SDL_SCANCODE_LALT:return BK_LEFT_ALT; case SDL_SCANCODE_RALT:return BK_RIGHT_ALT;
    case SDL_SCANCODE_LGUI:return BK_LEFT_SUPER; case SDL_SCANCODE_RGUI:return BK_RIGHT_SUPER;
    case SDL_SCANCODE_HELP:return BK_HELP; case SDL_SCANCODE_APPLICATION:return BK_MENU;
    default:return BK_TEXT;
  }
}
static uint32_t base_layout(SDL_Scancode code) {
  if (code>=SDL_SCANCODE_A && code<=SDL_SCANCODE_Z) return (uint32_t)('a'+code-SDL_SCANCODE_A);
  if (code>=SDL_SCANCODE_1 && code<=SDL_SCANCODE_9) return (uint32_t)('1'+code-SDL_SCANCODE_1);
  switch(code) {
    case SDL_SCANCODE_0:return '0'; case SDL_SCANCODE_SPACE:return ' ';
    case SDL_SCANCODE_MINUS:return '-'; case SDL_SCANCODE_EQUALS:return '=';
    case SDL_SCANCODE_LEFTBRACKET:return '['; case SDL_SCANCODE_RIGHTBRACKET:return ']';
    case SDL_SCANCODE_BACKSLASH:return '\\'; case SDL_SCANCODE_SEMICOLON:return ';';
    case SDL_SCANCODE_APOSTROPHE:return '\''; case SDL_SCANCODE_GRAVE:return '`';
    case SDL_SCANCODE_COMMA:return ','; case SDL_SCANCODE_PERIOD:return '.'; case SDL_SCANCODE_SLASH:return '/';
    default:return 0;
  }
}
bkey_event terminal_keyboard_event(const SDL_KeyboardEvent *event) {
  bkey_event out={0}; out.key=functional(event->scancode);
  out.action=event->type==SDL_EVENT_KEY_UP ? BK_RELEASE : (event->repeat ? BK_REPEAT : BK_PRESS);
  out.modifiers=terminal_modifiers(event->mod);
  out.right_modifiers=((event->mod&SDL_KMOD_RSHIFT) ? BI_SHIFT : 0) | ((event->mod&SDL_KMOD_RALT) ? BI_ALT : 0)
    | ((event->mod&SDL_KMOD_RCTRL) ? BI_CTRL : 0) | ((event->mod&SDL_KMOD_RGUI) ? BI_SUPER : 0);
  SDL_Keycode key=SDL_GetKeyFromScancode(event->scancode,SDL_KMOD_NONE,false);
  if (!key) key=event->key;
  if (!(key&SDLK_SCANCODE_MASK) && key<=0x10ffff && !(key>=0xd800 && key<=0xdfff)) out.unshifted=key;
  out.base_layout=base_layout(event->scancode); return out;
}
