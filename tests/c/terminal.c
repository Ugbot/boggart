#include "bterm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
typedef struct { uint8_t bytes[16384]; size_t length, calls; bool fail; } replies;
static bool reply(void *ctx, const uint8_t *bytes, size_t length) {
  replies *r = ctx; r->calls++;
  if (r->fail || length > sizeof r->bytes - r->length) return false;
  memcpy(r->bytes + r->length, bytes, length); r->length += length; return true;
}
static void feed(bterm *t, const char *bytes) { CHECK(bterm_feed(t, (const uint8_t *)bytes, strlen(bytes))); }
static void row_text(bterm *t, size_t y, const char *expected) {
  const lpage_row *r = lpage_visible(bterm_screen(t), y);
  CHECK(r && strlen(expected) == r->columns);
  for (size_t x = 0; x < r->columns; x++) {
    uint32_t cp = r->cells[x].codepoint;
    if ((cp ? cp : ' ') != (uint8_t)expected[x]) {
      fprintf(stderr, "row %zu, column %zu: wanted '%s', got U+%04x\n", y, x, expected, cp);
      exit(1);
    }
  }
}
static void equal_style(const lpage_style *a, const lpage_style *b) {
  CHECK(a && b && a->fg == b->fg && a->bg == b->bg && a->underline == b->underline && a->attrs == b->attrs);
}
static void equal_row(bterm *a, bterm *b, const lpage_row *ra, const lpage_row *rb) {
  CHECK(ra && rb && ra->columns == rb->columns && ra->wrapped == rb->wrapped);
  for (size_t x = 0; x < ra->columns; x++) {
    const lpage_cell *ca = &ra->cells[x], *cb = &rb->cells[x];
    lgrapheme_value ga=lpage_grapheme(bterm_screen(a),ca),gb=lpage_grapheme(bterm_screen(b),cb);
    CHECK(ga.length==gb.length && (!ga.length || !memcmp(ga.codepoints,gb.codepoints,ga.length*sizeof(uint32_t))));
    CHECK(ca->width == cb->width && ca->flags == cb->flags && ca->hyperlink == cb->hyperlink);
    equal_style(bterm_style(a, ca->style), bterm_style(b, cb->style));
    const llink_value *la = bterm_link(a, ca->hyperlink), *lb = bterm_link(b, cb->hyperlink);
    CHECK((la != NULL) == (lb != NULL));
    if (la) CHECK(la->key_length == lb->key_length && la->uri_length == lb->uri_length
      && !memcmp(la->key, lb->key, la->key_length) && !memcmp(la->uri, lb->uri, la->uri_length));
  }
}
static void equal_terminal(bterm *a, bterm *b) {
  bterm_status sa = bterm_state(a), sb = bterm_state(b);
  CHECK(sa.x == sb.x && sa.y == sb.y && sa.top == sb.top && sa.bottom == sb.bottom && sa.modes == sb.modes);
  CHECK(sa.cursor_style == sb.cursor_style && sa.alternate == sb.alternate && sa.pending_wrap == sb.pending_wrap);
  equal_style(&sa.pen, &sb.pen);
  const lpage_screen *ga = bterm_screen(a), *gb = bterm_screen(b);
  CHECK(lpage_rows(ga) == lpage_rows(gb) && lpage_history_count(ga) == lpage_history_count(gb));
  for (size_t y = 0; y < lpage_rows(ga); y++) {
    equal_row(a, b, lpage_visible(ga, y), lpage_visible(gb, y));
    CHECK(lpage_dirty(ga, y) == lpage_dirty(gb, y));
  }
  for (size_t y = 0; y < lpage_history_count(ga); y++) equal_row(a, b, lpage_history(ga, y), lpage_history(gb, y));
}
static void basic(void) {
  bterm *t = bterm_create(5, 3, 4, NULL, NULL); CHECK(t);
  feed(t, "abcde"); row_text(t, 0, "abcde"); CHECK(bterm_state(t).pending_wrap && bterm_state(t).y == 0);
  feed(t, "f"); row_text(t, 1, "f    "); CHECK(lpage_visible(bterm_screen(t), 0)->wrapped);
  feed(t, "\r\n12345\r\n");
  CHECK(lpage_history_count(bterm_screen(t)) == 1);
  CHECK(lpage_history(bterm_screen(t), 0)->cells[0].codepoint == 'a');
  row_text(t, 0, "f    "); row_text(t, 1, "12345");
  CHECK(bterm_reset(t)); feed(t, "abcde\033[?7lfgh"); row_text(t, 0, "abcdh"); CHECK(!bterm_state(t).pending_wrap);
  feed(t, "\033[H\033[?7hX\033[2;3HY\033[999;999HZ");
  row_text(t, 0, "Xbcdh"); row_text(t, 1, "  Y  "); row_text(t, 2, "    Z");
  feed(t, "\033[1;2;3H\033[?2J"); /* Invalid CUP and unsupported selective erase are ignored. */
  row_text(t, 2, "    Z"); CHECK(bterm_state(t).y == 2);
  feed(t, "\033[2J\033[H\033[4habcd\033[1;2HZ"); row_text(t, 0, "aZbcd");
  feed(t, "\033[4l\033[2P"); row_text(t, 0, "aZd  ");
  CHECK(bterm_reset(t)); feed(t, "abcde\033[1;2H\033[2@Q"); row_text(t, 0, "aQ bc");
  feed(t, "\033[2X"); row_text(t, 0, "aQ  c");
  feed(t, "\033[1K"); row_text(t, 0, "    c");
  feed(t, "\033[1;1HA\033[3b"); row_text(t, 0, "AAAAc");
  bterm_ack_damage(t); CHECK(!lpage_dirty(bterm_screen(t), 0));
  feed(t, "\033[2;1HB"); CHECK(lpage_dirty(bterm_screen(t), 1) && !lpage_dirty(bterm_screen(t), 0));
  feed(t, "\033[3J"); CHECK(!lpage_history_count(bterm_screen(t)));
  CHECK(bterm_reset(t)); feed(t, "\033[20hA\nB"); row_text(t, 0, "A    "); row_text(t, 1, "B    ");
  bterm_destroy(t);
}
static void regions(void) {
  bterm *t = bterm_create(5, 4, 10, NULL, NULL); CHECK(t);
  feed(t, "AAAAA\033[2;1HBBBBB\033[3;1HCCCCC\033[4;1HDDDDD\033[2;3r\033[3;1H\n");
  row_text(t, 0, "AAAAA"); row_text(t, 1, "CCCCC"); row_text(t, 2, "     "); row_text(t, 3, "DDDDD");
  CHECK(!lpage_history_count(bterm_screen(t)));
  feed(t, "\033[2;1H\033M"); row_text(t, 1, "     "); row_text(t, 2, "CCCCC");
  feed(t, "\033[?6hX\033[999;999HY"); row_text(t, 1, "X    "); row_text(t, 2, "CCCCY");
  CHECK(bterm_state(t).y == 2 && bterm_state(t).x == 4);
  feed(t, "\033[999AZ"); row_text(t, 1, "X   Z"); CHECK(bterm_state(t).y == 1);
  feed(t, "\033[?6l\033[4;1HX\nY"); row_text(t, 3, "XYDDD");
  feed(t, "\033[2;1H\033[L"); row_text(t, 1, "     "); row_text(t, 2, "X   Z"); row_text(t, 3, "XYDDD");
  feed(t, "\033[M"); row_text(t, 1, "X   Z"); row_text(t, 2, "     ");
  feed(t, "\033[4;2r"); CHECK(bterm_state(t).top == 1 && bterm_state(t).bottom == 2);
  feed(t, "\033[r"); CHECK(bterm_state(t).top == 0 && bterm_state(t).bottom == 3 && bterm_state(t).y == 0);
  bterm_destroy(t);
}
static void styles_and_saves(void) {
  bterm *t = bterm_create(12, 3, 2, NULL, NULL); CHECK(t);
  feed(t, "\033[1;2;3;4;5;7;8;9;53;31;104mA\033[38;5;200;48;2;1;2;3;58:2::4:5:6;4:3mB");
  const lpage_cell *a = lpage_get(bterm_screen(t), 0, 0), *b = lpage_get(bterm_screen(t), 0, 1);
  const lpage_style *sa = bterm_style(t, a->style), *sb = bterm_style(t, b->style);
  CHECK(sa->fg == (LP_COLOR_INDEXED | 1) && sa->bg == (LP_COLOR_INDEXED | 12));
  CHECK((sa->attrs & ~LP_UNDERLINE_MASK) == (LP_BOLD | LP_FAINT | LP_ITALIC | LP_BLINK | LP_INVERSE | LP_INVISIBLE | LP_STRIKE | LP_OVERLINE));
  CHECK(sb->fg == (LP_COLOR_INDEXED | 200) && sb->bg == (LP_COLOR_RGB | 0x010203));
  CHECK(sb->underline == (LP_COLOR_RGB | 0x040506) && (sb->attrs & LP_UNDERLINE_MASK) == (3u << LP_UNDERLINE_SHIFT));
  feed(t, "\033[22;23;24;25;27;28;29;55;39;49;59mC"); CHECK(lpage_get(bterm_screen(t), 0, 2)->style == 0);
  feed(t, "\033[38:2:7:8:9;48:5:12;4:5mD\033[38:2:1:2:3:4:5;4:2:3mE");
  bterm_status state = bterm_state(t);
  CHECK(state.pen.fg == (LP_COLOR_RGB | 0x070809) && state.pen.bg == (LP_COLOR_INDEXED | 12));
  CHECK((state.pen.attrs & LP_UNDERLINE_MASK) == (5u << LP_UNDERLINE_SHIFT));
  feed(t, "\033[38;2;257;258;259mF\0337\033[0m\033[3;4HG\0338H");
  CHECK(bterm_state(t).pen.fg == (LP_COLOR_RGB | 0x010203)); row_text(t, 0, "ABCDEFH     ");
  feed(t, "\033[44m\033[2K");
  for (size_t x = 0; x < 12; x++) {
    const lpage_style *s = bterm_style(t, lpage_get(bterm_screen(t), 0, x)->style);
    CHECK(s->bg == (LP_COLOR_INDEXED | 4) && !s->fg && !s->attrs);
  }
  uint32_t attrs = bterm_state(t).pen.attrs;
  feed(t, "\033[58:4:m"); CHECK(bterm_state(t).pen.attrs == attrs);
  bterm_destroy(t);
}
static void alternate_and_replies(void) {
  replies r = {0}; bterm *t = bterm_create(6, 3, 2, reply, &r); CHECK(t);
  feed(t, "normal\033[2;3H\033[32m\033[?1049hALT\r\n1\r\n2\r\n3");
  CHECK(bterm_state(t).alternate && !lpage_history_count(bterm_screen(t)));
  feed(t, "\033[?1049h"); row_text(t, 2, "3     "); /* Repeated set must not clear or overwrite the save. */
  feed(t, "\033[?1049l"); row_text(t, 0, "normal"); CHECK(!bterm_state(t).alternate);
  CHECK(bterm_state(t).x == 2 && bterm_state(t).y == 1 && bterm_state(t).pen.fg == (LP_COLOR_INDEXED | 2));
  feed(t, "\033[?47h"); row_text(t, 2, "3     "); feed(t, "\033[?1047l\033[?47h"); row_text(t, 2, "      ");
  feed(t, "\033[?47l\033[?1048h\033[H\033[?1048l"); CHECK(bterm_state(t).x == 2 && bterm_state(t).y == 1);
  feed(t, "\033[c\033[>c\033[5n\033[6n\033[?6n\033[2;3r\033[?6h\033[6n");
  const char *expected = "\033[?1;2c\033[>0;1;0c\033[0n\033[2;3R\033[?2;3R\033[1;1R";
  CHECK(r.length == strlen(expected) && !memcmp(r.bytes, expected, r.length));
  feed(t, "\033[?1;25;1004;2004h\033=\033[5 q");
  CHECK((bterm_state(t).modes & (BT_APP_CURSOR | BT_CURSOR_VISIBLE | BT_FOCUS | BT_BRACKETED_PASTE | BT_APP_KEYPAD))
    == (BT_APP_CURSOR | BT_CURSOR_VISIBLE | BT_FOCUS | BT_BRACKETED_PASTE | BT_APP_KEYPAD));
  CHECK(bterm_state(t).cursor_style == 5);
  r.fail = true; CHECK(!bterm_feed(t, (const uint8_t *)"\033[6nX", 5));
  size_t calls = r.calls; CHECK(!bterm_feed(t, (const uint8_t *)"X", 1) && r.calls == calls);
  CHECK(bterm_reset(t)); row_text(t, 0, "      ");
  r.fail = false; feed(t, "\033[6n"); CHECK(r.calls == calls + 1);
  feed(t, "\033[?1049hX\033cY"); CHECK(!bterm_state(t).alternate); row_text(t, 0, "Y     ");
  bterm_destroy(t);
}
static void tabs(void) {
  bterm *t = bterm_create(20, 2, 0, NULL, NULL); CHECK(t);
  feed(t, "A\tB\tC"); row_text(t, 0, "A       B       C   ");
  feed(t, "\033[Zx"); row_text(t, 0, "A       B       x   ");
  feed(t, "\033[3g\033[H\tY"); CHECK(bterm_state(t).x == 19);
  feed(t, "\033[1;4H\033H\033[H\tZ"); CHECK(lpage_get(bterm_screen(t), 0, 3)->codepoint == 'Z');
  feed(t, "\033[g\033[65535I"); CHECK(bterm_state(t).x == 19);
  bterm_destroy(t);
}
static void fragmentation(void) {
  static const char stream[] = "hello\r\n\033[38;2;2;3;4mworld\033[0m\r\n"
    "\xe2\x82\xac\xf0\x9f\x99\x82\033[2;4r\033[?6h\033[2;3HZ\033[?6l"
    "\033[?1049hALT\033[48:2::5:6:7m\033[2J\033[6n\033[?1049l\033[6n"
    "\033[r\033[H\033[2@X\033[2P\033[3b\033[5 q\033[?2004h\033[999:1:2m"
    "\033]0;ignored title\007\033Pignored data\033\\"
    "\033]8;id=explicit;https://example.com/%C3%A9\aLINK\033]8;;\a"
    "\033]8;;https://implicit.com\aAB\033[2@\033[1P\033]8;;\a\xff\xe2";
  replies full_reply = {0}; bterm *full = bterm_create(9, 4, 3, reply, &full_reply); CHECK(full);
  CHECK(bterm_feed(full, (const uint8_t *)stream, sizeof stream - 1) && bterm_finish(full));
  for (size_t chunk = 1; chunk <= 17; chunk++) {
    replies r = {0}; bterm *t = bterm_create(9, 4, 3, reply, &r); CHECK(t);
    for (size_t offset = 0; offset < sizeof stream - 1; offset += chunk) {
      size_t n = sizeof stream - 1 - offset; if (n > chunk) n = chunk;
      CHECK(bterm_feed(t, (const uint8_t *)stream + offset, n));
    }
    CHECK(bterm_finish(t)); equal_terminal(full, t);
    CHECK(r.length == full_reply.length && !memcmp(r.bytes, full_reply.bytes, r.length));
    bterm_destroy(t);
  }
  bterm_destroy(full);
}
static void adversarial(void) {
  uint8_t bytes[131072]; uint32_t random = 0x72534;
  for (size_t i = 0; i < sizeof bytes; i++) {
    random ^= random << 13; random ^= random >> 17; random ^= random << 5;
    bytes[i] = (uint8_t)random;
  }
  bterm *a = bterm_create(13, 7, 17, NULL, NULL), *b = bterm_create(13, 7, 17, NULL, NULL);
  CHECK(a && b && bterm_feed(a, bytes, sizeof bytes) && bterm_finish(a));
  for (size_t i = 0; i < sizeof bytes; i++) CHECK(bterm_feed(b, bytes + i, 1));
  CHECK(bterm_finish(b)); equal_terminal(a, b);
  /* Returning through reset also releases history and non-default cell styles. */
  CHECK(bterm_reset(a) && bterm_reset(b)); equal_terminal(a, b);
  CHECK(lpage_usage(bterm_screen(a)).styles == 1);
  bterm_destroy(a); bterm_destroy(b);
}
int main(void) {
  CHECK(!bterm_create(0, 3, 0, NULL, NULL));
  basic(); regions(); styles_and_saves(); alternate_and_replies(); tabs(); fragmentation(); adversarial();
  bterm *tiny = bterm_create(1, 1, 1, NULL, NULL); CHECK(tiny);
  feed(tiny, "abc\033[999S\033[999T\033[0;0H\033[0mX"); CHECK(bterm_state(tiny).x == 0);
  CHECK(lpage_history_count(bterm_screen(tiny)) == 1); bterm_destroy(tiny);
  puts("Terminal dispatch: grids, margins, SGR, modes, replies and fragmentation passed");
  return 0;
}
