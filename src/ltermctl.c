/* ltermctl.c -- the Lua binding for termctl, boggart's full-screen terminal
 * layer (B0 in docs/cli-plan.md). Registered as the global `tc`. This is a
 * thin marshalling shim over src/termctl.c: the mechanism -- raw mode, the
 * cell grid, the diff-based flush, input decoding -- all lives in C already;
 * this file only translates between Lua values and the C ABI.
 *
 * Two translations are the whole point of the binding, and both keep the
 * termctl ABI simple while letting callers speak in the vocabulary they think
 * in:
 *
 *   colour   callers pass hex strings ("7fb77e") or nil; termctl wants a
 *            256-colour palette index (0..255) or -1 for the terminal default.
 *            hex_to_256 does the standard 6x6x6 colour-cube + grayscale-ramp
 *            nearest-match so no caller ever computes an xterm index by hand.
 *
 *   event    tc_poll returns a flat C struct with overloaded fields (mx/my
 *            double as resize w/h); l_poll fans it out into the named Lua
 *            table the cTUI reads -- type/key/char/w/h/mx/my/button -- with the
 *            TCEV_ and TCK_ enums mapped to their string names.
 *
 * One interpreter, one thread, one terminal: termctl keeps process-global
 * state (the grid, the saved termios), so `tc` is a plain function library, not
 * a userdata handle -- there is only ever one terminal to talk to.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"

#include "uv.h"
#include "termctl.h"

/* Each interpreter's libuv loop (defined in the uv binding; also used by
 * lhttp.c). Declared after lua.h so lua_State is a known type. */
extern uv_loop_t *luv_loop(lua_State *L);

/* ---- colour: hex "rrggbb" -> nearest xterm-256 index -------------------- */

/* The six component levels of the 6x6x6 colour cube (indices 16..231). Not
 * evenly spaced: xterm jumps 0->95 then steps by 40, so a nearest-match by
 * value (rather than v/51) is what actually lands on the right cube cell. */
static const int CUBE[6] = {0, 95, 135, 175, 215, 255};

static int nearest_cube(int v) {
  int best = 0, bestd = 1 << 30;
  for (int i = 0; i < 6; i++) {
    int d = v - CUBE[i];
    if (d < 0) d = -d;
    if (d < bestd) { bestd = d; best = i; }
  }
  return best;
}

static int dist2(int r, int g, int b, int r2, int g2, int b2) {
  int dr = r - r2, dg = g - g2, db = b - b2;
  return dr * dr + dg * dg + db * db;
}

/* Map an 8-bit RGB triple to the closest palette index, choosing between the
 * best colour-cube cell and the best grayscale-ramp step (232..255, values
 * 8 + 10*i) by true RGB distance -- a near-grey that the cube would quantise
 * badly then reads correctly off the ramp, and vice versa. */
static int rgb_to_256(int r, int g, int b) {
  int ri = nearest_cube(r), gi = nearest_cube(g), bi = nearest_cube(b);
  int cube_idx = 16 + 36 * ri + 6 * gi + bi;
  int cube_d = dist2(r, g, b, CUBE[ri], CUBE[gi], CUBE[bi]);

  int gi_ramp = (r + g + b) / 3 - 8;
  gi_ramp = (gi_ramp + 5) / 10;            /* round to nearest of the 24 steps */
  if (gi_ramp < 0) gi_ramp = 0;
  if (gi_ramp > 23) gi_ramp = 23;
  int gv = 8 + 10 * gi_ramp;
  int gray_idx = 232 + gi_ramp;
  int gray_d = dist2(r, g, b, gv, gv, gv);

  return gray_d < cube_d ? gray_idx : cube_idx;
}

static int hexnib(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* A colour argument: nil -> TC_DEFAULT (-1); "rrggbb" (optional leading '#')
 * -> nearest palette index. A malformed string also degrades to the default
 * rather than raising -- a paint call must not blow up the frame. */
static int check_colour(lua_State *L, int idx) {
  if (lua_isnoneornil(L, idx)) return TC_DEFAULT;
  size_t len = 0;
  const char *s = lua_tolstring(L, idx, &len);
  if (!s) return TC_DEFAULT;
  if (len == 7 && s[0] == '#') { s++; len = 6; }
  if (len != 6) return TC_DEFAULT;
  int v[6];
  for (int i = 0; i < 6; i++) {
    v[i] = hexnib((unsigned char) s[i]);
    if (v[i] < 0) return TC_DEFAULT;
  }
  int r = v[0] * 16 + v[1];
  int g = v[2] * 16 + v[3];
  int b = v[4] * 16 + v[5];
  return rgb_to_256(r, g, b);
}

/* An attribute argument: nil -> 0; { bold=, dim=, underline=, reverse= } ->
 * the TC_* bitflags. Any truthy field sets its flag. */
static int check_attr(lua_State *L, int idx) {
  if (lua_isnoneornil(L, idx)) return 0;
  luaL_checktype(L, idx, LUA_TTABLE);
  int a = 0;
  lua_getfield(L, idx, "bold");      if (lua_toboolean(L, -1)) a |= TC_BOLD;      lua_pop(L, 1);
  lua_getfield(L, idx, "dim");       if (lua_toboolean(L, -1)) a |= TC_DIM;       lua_pop(L, 1);
  lua_getfield(L, idx, "underline"); if (lua_toboolean(L, -1)) a |= TC_UNDERLINE; lua_pop(L, 1);
  lua_getfield(L, idx, "reverse");   if (lua_toboolean(L, -1)) a |= TC_REVERSE;   lua_pop(L, 1);
  return a;
}

/* ---- utf8 <-> codepoint (only the first scalar; termctl draws one cell) -- */

static uint32_t utf8_first(const char *s, size_t len) {
  if (len == 0) return 0;
  unsigned char c = (unsigned char) s[0];
  if (c < 0x80) return c;
  int n; uint32_t cp;
  if      ((c & 0xE0) == 0xC0) { n = 1; cp = c & 0x1F; }
  else if ((c & 0xF0) == 0xE0) { n = 2; cp = c & 0x0F; }
  else if ((c & 0xF8) == 0xF0) { n = 3; cp = c & 0x07; }
  else return 0xFFFD;
  for (int i = 1; i <= n; i++) {
    if ((size_t) i >= len || ((unsigned char) s[i] & 0xC0) != 0x80) return 0xFFFD;
    cp = (cp << 6) | ((unsigned char) s[i] & 0x3F);
  }
  return cp;
}

static void push_utf8(lua_State *L, uint32_t cp) {
  char b[4];
  int n = 0;
  if (cp < 0x80) {
    b[n++] = (char) cp;
  } else if (cp < 0x800) {
    b[n++] = (char) (0xC0 | (cp >> 6));
    b[n++] = (char) (0x80 | (cp & 0x3F));
  } else if (cp < 0x10000) {
    b[n++] = (char) (0xE0 | (cp >> 12));
    b[n++] = (char) (0x80 | ((cp >> 6) & 0x3F));
    b[n++] = (char) (0x80 | (cp & 0x3F));
  } else {
    b[n++] = (char) (0xF0 | (cp >> 18));
    b[n++] = (char) (0x80 | ((cp >> 12) & 0x3F));
    b[n++] = (char) (0x80 | ((cp >> 6) & 0x3F));
    b[n++] = (char) (0x80 | (cp & 0x3F));
  }
  lua_pushlstring(L, b, (size_t) n);
}

/* ch may be a codepoint integer or a 1-char / UTF-8 string; either way we want
 * the single scalar termctl's tc_set draws into one cell. */
static uint32_t check_codepoint(lua_State *L, int idx) {
  if (lua_type(L, idx) == LUA_TNUMBER)
    return (uint32_t) lua_tointeger(L, idx);
  size_t len = 0;
  const char *s = luaL_checklstring(L, idx, &len);
  return utf8_first(s, len);
}

/* ---- the library -------------------------------------------------------- */

/* tc.init() -> ok:boolean
 * Enter full-screen mode. tc_init itself degrades gracefully with no tty
 * (returns 0 having changed nothing), so we AND its success with an actual tty
 * check: the caller wants a hard false when there is no terminal to render to,
 * which is exactly the piped / </dev/null case. Never wedges. */
static int l_init(lua_State *L) {
  bool tty = isatty(STDIN_FILENO) && isatty(STDOUT_FILENO);
  bool ok = (tc_init() == 0) && tty;
  lua_pushboolean(L, ok);
  return 1;
}

static int l_shutdown(lua_State *L) {
  (void) L;
  tc_shutdown();
  return 0;
}

/* tc.size() -> w, h */
static int l_size(lua_State *L) {
  int w = 0, h = 0;
  tc_size(&w, &h);
  lua_pushinteger(L, w);
  lua_pushinteger(L, h);
  return 2;
}

static int l_clear(lua_State *L) {
  (void) L;
  tc_clear();
  return 0;
}

/* tc.set(x, y, ch, fg, bg, attr) */
static int l_set(lua_State *L) {
  int x = (int) luaL_checkinteger(L, 1);
  int y = (int) luaL_checkinteger(L, 2);
  uint32_t cp = check_codepoint(L, 3);
  int fg = check_colour(L, 4);
  int bg = check_colour(L, 5);
  int attr = check_attr(L, 6);
  tc_set(x, y, cp, fg, bg, attr);
  return 0;
}

/* tc.puts(x, y, s, fg, bg, attr) -> x2 */
static int l_puts(lua_State *L) {
  int x = (int) luaL_checkinteger(L, 1);
  int y = (int) luaL_checkinteger(L, 2);
  const char *s = luaL_checkstring(L, 3);
  int fg = check_colour(L, 4);
  int bg = check_colour(L, 5);
  int attr = check_attr(L, 6);
  int x2 = tc_puts(x, y, s, fg, bg, attr);
  lua_pushinteger(L, x2);
  return 1;
}

static int l_flush(lua_State *L) {
  (void) L;
  tc_flush();
  return 0;
}

/* The logical-key enum, as the string names the cTUI matches on. */
static const char *key_name(int key) {
  switch (key) {
    case TCK_CHAR:      return "char";
    case TCK_ENTER:     return "enter";
    case TCK_TAB:       return "tab";
    case TCK_BACKSPACE: return "backspace";
    case TCK_ESC:       return "esc";
    case TCK_UP:        return "up";
    case TCK_DOWN:      return "down";
    case TCK_LEFT:      return "left";
    case TCK_RIGHT:     return "right";
    case TCK_HOME:      return "home";
    case TCK_END:       return "end";
    case TCK_PAGEUP:    return "pageup";
    case TCK_PAGEDOWN:  return "pagedown";
    case TCK_INSERT:    return "insert";
    case TCK_DELETE:    return "delete";
    case TCK_CTRL:      return "ctrl";
    case TCK_F1:        return "f1";
    case TCK_F2:        return "f2";
    case TCK_F3:        return "f3";
    case TCK_F4:        return "f4";
    case TCK_F5:        return "f5";
    case TCK_F6:        return "f6";
    case TCK_F7:        return "f7";
    case TCK_F8:        return "f8";
    case TCK_F9:        return "f9";
    case TCK_F10:       return "f10";
    case TCK_F11:       return "f11";
    case TCK_F12:       return "f12";
    default:            return "none";
  }
}

/* tc.poll(timeout_ms) -> ev
 * Marshal the flat tc_event into the named table the cTUI reads. Every event
 * carries `type`; the rest are filled per variant:
 *   key    -> key (string), and char (the UTF-8 scalar) for TCK_CHAR/TCK_CTRL
 *   resize -> w, h        (termctl stows these in mx/my)
 *   mouse  -> mx, my, button
 * A NONE (timed-out) poll still returns a table, so the caller can always read
 * ev.type without a nil check. */
static int l_poll(lua_State *L) {
  int timeout = (int) luaL_optinteger(L, 1, 0);
  tc_event ev = tc_poll(timeout);

  lua_createtable(L, 0, 6);

  const char *type =
      ev.type == TCEV_KEY    ? "key"    :
      ev.type == TCEV_RESIZE ? "resize" :
      ev.type == TCEV_MOUSE  ? "mouse"  :
      ev.type == TCEV_PASTE  ? "paste"  : "none";
  lua_pushstring(L, type);
  lua_setfield(L, -2, "type");

  if (ev.type == TCEV_KEY) {
    lua_pushstring(L, key_name(ev.key));
    lua_setfield(L, -2, "key");
    if (ev.key == TCK_CHAR || ev.key == TCK_CTRL) {
      push_utf8(L, ev.codepoint);
      lua_setfield(L, -2, "char");
    }
    if (ev.mods & TC_MOD_SHIFT) { lua_pushboolean(L, 1); lua_setfield(L, -2, "shift"); }
    if (ev.mods & TC_MOD_ALT)   { lua_pushboolean(L, 1); lua_setfield(L, -2, "alt"); }
    if (ev.mods & TC_MOD_CTRL)  { lua_pushboolean(L, 1); lua_setfield(L, -2, "ctrl"); }
  } else if (ev.type == TCEV_RESIZE) {
    lua_pushinteger(L, ev.mx);   /* termctl: width in mx  */
    lua_setfield(L, -2, "w");
    lua_pushinteger(L, ev.my);   /* termctl: height in my */
    lua_setfield(L, -2, "h");
  } else if (ev.type == TCEV_MOUSE) {
    lua_pushinteger(L, ev.mx);
    lua_setfield(L, -2, "mx");
    lua_pushinteger(L, ev.my);
    lua_setfield(L, -2, "my");
    lua_pushinteger(L, ev.mbutton);
    lua_setfield(L, -2, "button");
  } else if (ev.type == TCEV_PASTE) {
    lua_pushlstring(L, tc_paste_text(), tc_paste_len());
    lua_setfield(L, -2, "text");
  }
  return 1;
}

/* tc.snapshot() -> string. The on-screen buffer as UTF-8 rows -- exactly what
 * the terminal is showing, for tests. */
static int l_snapshot(lua_State *L) {
  int w = 0, h = 0;
  tc_size(&w, &h);
  size_t cap = (size_t) (w + 1) * (size_t) (h + 1) * 4 + 64;
  char *buf = (char *) malloc(cap);
  if (!buf) { lua_pushliteral(L, ""); return 1; }
  size_t n = tc_snapshot(buf, cap);
  lua_pushlstring(L, buf, n);
  free(buf);
  return 1;
}

/* tc.attach() -> ok: put stdin on this interpreter's uv loop, so a caller can
 * sleep in uv.run for keyboard, http and timers at once (see termctl.h). */
static int l_attach(lua_State *L) {
  int ok = tc_attach_loop(luv_loop(L)) == 0;
  lua_pushboolean(L, ok);
  return 1;
}
static int l_detach(lua_State *L) {
  (void) L;
  tc_detach_loop();
  return 0;
}

static const luaL_Reg tc_lib[] = {
  {"init",     l_init},
  {"shutdown", l_shutdown},
  {"snapshot", l_snapshot},
  {"size",     l_size},
  {"clear",    l_clear},
  {"set",      l_set},
  {"puts",     l_puts},
  {"flush",    l_flush},
  {"poll",     l_poll},
  {"attach",   l_attach},
  {"detach",   l_detach},
  {NULL, NULL},
};

int luaopen_boggart_termctl(lua_State *L) {
  luaL_newlib(L, tc_lib);
  return 1;
}
