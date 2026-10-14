/* SDL event injection for the existing BOGGART_STUDIO_SCRIPT test entry point.
 * Not registered in ordinary app sessions. Payload storage is bounded to 64
 * queued text events per batch; tests drain each batch before reusing it. */
#include "api.h"
#include <SDL3/SDL.h>
#include <string.h>
#include "terminalkeys.h"
extern SDL_Window *window;
static char texts[64][4097]; static unsigned text_slot;
static int integer_field(lua_State *L,const char *field,int fallback) {
  lua_getfield(L,1,field); int n=(int)luaL_optinteger(L,-1,fallback); lua_pop(L,1); return n;
}
static int push_event(lua_State *L) {
  luaL_checktype(L,1,LUA_TTABLE); lua_getfield(L,1,"type"); const char *type=luaL_checkstring(L,-1); lua_pop(L,1);
  SDL_Event event={0}; Uint32 id=SDL_GetWindowID(window);
  int width=0,height=0,pixels_w=0,pixels_h=0;
  SDL_GetWindowSize(window,&width,&height); SDL_GetWindowSizeInPixels(window,&pixels_w,&pixels_h);
  float point_x=pixels_w>0 ? (float)width/pixels_w : 1,point_y=pixels_h>0 ? (float)height/pixels_h : 1;
  if (!strcmp(type,"keypressed") || !strcmp(type,"keyreleased")) {
    event.type=!strcmp(type,"keypressed") ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    lua_getfield(L,1,"key"); const char *name=luaL_checkstring(L,-1);
    event.key.scancode=SDL_GetScancodeFromName(name);
    /* SDL names GUI/Alt keys Command/Option on macOS; fixture names stay
     * physical and platform-independent. */
    if (!event.key.scancode) {
      if (!strcmp(name,"Left GUI")) event.key.scancode=SDL_SCANCODE_LGUI;
      else if (!strcmp(name,"Right GUI")) event.key.scancode=SDL_SCANCODE_RGUI;
      else if (!strcmp(name,"Left Alt")) event.key.scancode=SDL_SCANCODE_LALT;
      else if (!strcmp(name,"Right Alt")) event.key.scancode=SDL_SCANCODE_RALT;
    }
    lua_pop(L,1);
    if (!event.key.scancode) return luaL_error(L,"unknown test scancode");
    event.key.windowID=id; event.key.key=SDL_GetKeyFromScancode(event.key.scancode,SDL_KMOD_NONE,false);
    unsigned mods=(unsigned)integer_field(L,"modifiers",0),right=(unsigned)integer_field(L,"right_modifiers",0);
    SDL_Keymod sdl=SDL_KMOD_NONE;
    if (mods&BI_SHIFT) sdl|=(right&BI_SHIFT) ? SDL_KMOD_RSHIFT : SDL_KMOD_LSHIFT;
    if (mods&BI_ALT) sdl|=(right&BI_ALT) ? SDL_KMOD_RALT : SDL_KMOD_LALT;
    if (mods&BI_CTRL) sdl|=(right&BI_CTRL) ? SDL_KMOD_RCTRL : SDL_KMOD_LCTRL;
    if (mods&BI_SUPER) sdl|=(right&BI_SUPER) ? SDL_KMOD_RGUI : SDL_KMOD_LGUI;
    if (mods&BI_CAPS_LOCK) sdl|=SDL_KMOD_CAPS; if (mods&BI_NUM_LOCK) sdl|=SDL_KMOD_NUM;
    event.key.mod=sdl; event.key.repeat=integer_field(L,"repeat",0)!=0; event.key.down=event.type==SDL_EVENT_KEY_DOWN;
  } else if (!strcmp(type,"textinput") || !strcmp(type,"textediting")) {
    lua_getfield(L,1,"text"); size_t n; const char *text=luaL_checklstring(L,-1,&n);
    if (n>4096 || memchr(text,0,n)) return luaL_error(L,"invalid test text");
    char *storage=texts[text_slot++%64]; memcpy(storage,text,n+1); lua_pop(L,1);
    event.type=!strcmp(type,"textinput") ? SDL_EVENT_TEXT_INPUT : SDL_EVENT_TEXT_EDITING;
    if (event.type==SDL_EVENT_TEXT_INPUT) { event.text.windowID=id; event.text.text=storage; }
    else { event.edit.windowID=id; event.edit.text=storage; }
  } else if (!strcmp(type,"focus")) {
    event.type=integer_field(L,"focused",0) ? SDL_EVENT_WINDOW_FOCUS_GAINED : SDL_EVENT_WINDOW_FOCUS_LOST; event.window.windowID=id;
  } else if (!strcmp(type,"mousepressed") || !strcmp(type,"mousereleased")) {
    event.type=!strcmp(type,"mousepressed") ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
    event.button.windowID=id; event.button.button=(Uint8)integer_field(L,"button",1); event.button.clicks=1;
    event.button.x=(float)integer_field(L,"x",0)*point_x; event.button.y=(float)integer_field(L,"y",0)*point_y;
  } else if (!strcmp(type,"mousewheel")) {
    event.type=SDL_EVENT_MOUSE_WHEEL; event.wheel.windowID=id;
    event.wheel.x=(float)integer_field(L,"horizontal",0); event.wheel.y=(float)integer_field(L,"amount",1);
    event.wheel.mouse_x=(float)integer_field(L,"x",0)*point_x; event.wheel.mouse_y=(float)integer_field(L,"y",0)*point_y;
  } else return luaL_error(L,"unknown test SDL event");
  if (!SDL_PushEvent(&event)) return luaL_error(L,"SDL event injection failed: %s",SDL_GetError());
  return 0;
}
void system_test_open(lua_State *L) { lua_pushcfunction(L,push_event); lua_setfield(L,-2,"_test_event"); }
