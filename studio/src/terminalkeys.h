#ifndef BOGGART_STUDIO_TERMINALKEYS_H
#define BOGGART_STUDIO_TERMINALKEYS_H
#include <SDL3/SDL.h>
#include "bkey.h"
unsigned terminal_modifiers(SDL_Keymod mods);
/* Normalize physical/layout metadata. SDL text input is associated by the
 * main-thread input controller, not inferred from a keyboard event. */
bkey_event terminal_keyboard_event(const SDL_KeyboardEvent *event);
#endif
