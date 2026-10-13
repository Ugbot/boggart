#include "bunicode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)

static void conformance(const char *path) {
  FILE *f = fopen(path, "rb"); CHECK(f);
  char line[4096]; size_t number = 0, cases = 0, boundaries = 0;
  while (fgets(line, sizeof line, f)) {
    number++; CHECK(strchr(line, '\n') || feof(f));
    char *comment = strchr(line, '#'); if (comment) *comment = 0;
    char *p = line; bunicode_grapheme_state state = {0}; size_t scalars = 0;
    while (*p) {
      while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
      if (!*p) break;
      bool expected;
      if (!strncmp(p, "\xc3\xb7", 2)) expected = true;
      else { CHECK(!strncmp(p, "\xc3\x97", 2)); expected = false; }
      p += 2;
      while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
      if (!*p) { CHECK(expected); break; }
      char *end; unsigned long cp = strtoul(p, &end, 16);
      CHECK(end != p && cp <= 0x10ffff); p = end;
      bool actual = bunicode_grapheme_break(&state, (uint32_t)cp);
      if (actual != expected) {
        fprintf(stderr, "%s:%zu: boundary before U+%04lX: expected %d got %d\n",
                path, number, cp, expected, actual); exit(1);
      }
      scalars++; boundaries++;
    }
    if (scalars) cases++;
  }
  CHECK(!ferror(f)); fclose(f); CHECK(cases > 1000);
  printf("Unicode %s: %zu official cases, %zu boundaries\n", BUNICODE_VERSION, cases, boundaries);
}

static void width(const uint32_t *cps, size_t length, int expected, size_t count) {
  size_t consumed = 999; CHECK(bunicode_grapheme_width(cps, length, &consumed) == expected);
  CHECK(consumed == count);
}
#define WIDTH(expected, count, ...) do { const uint32_t cps[] = {__VA_ARGS__}; width(cps, sizeof cps / sizeof *cps, expected, count); } while (0)
static void decoding(void) {
  const char *s = "aé日😀"; const char *p = s, *end = s + strlen(s);
  const uint32_t expected[] = {'a', 0xe9, 0x65e5, 0x1f600};
  for (size_t i = 0; i < 4; i++) {
    uint32_t bounded, terminated;
    const char *next = bunicode_utf8_next(p, end, &bounded);
    CHECK(next == bunicode_utf8_next(p, NULL, &terminated));
    CHECK(bounded == expected[i] && terminated == bounded); p = next;
  }
  uint32_t cp;
  CHECK(p == end && bunicode_utf8_next(p, end, &cp) == p && cp == 0);
  CHECK(bunicode_utf8_next(p, NULL, &cp) == p && cp == 0);
  const char *invalid[] = {"\x80", "\xc0\xaf", "\xc1\xbf", "\xe0\x80\xaf", "\xed\xa0\x80",
    "\xf0\x80\x80\xaf", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xff", "\xe2", "\xe2\x82", "\xe2x"};
  for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++) {
    s = invalid[i];
    CHECK(bunicode_utf8_next(s, s + strlen(s), &cp) == s + 1 && cp == 0xfffd);
    CHECK(bunicode_utf8_next(s, NULL, &cp) == s + 1 && cp == 0xfffd);
  }
  /* A bounded unterminated tail must not read adjacent bytes. */
  for (size_t n = 1; n < 4; n++) {
    char *tail = malloc(n); CHECK(tail); memcpy(tail, "\xf0\x9f\x98", n);
    CHECK(bunicode_utf8_next(tail, tail + n, &cp) == tail + 1 && cp == 0xfffd); free(tail);
  }
  const char nul[] = {'a', 0, 'b'};
  CHECK(bunicode_str_width(nul, sizeof nul) == 2);
  CHECK(bunicode_str_width(NULL, 0) == 0);
  CHECK(bunicode_str_width("日本語", strlen("日本語")) == 6);
  CHECK(bunicode_str_width("e\xcc\x81", 3) == 1);
  CHECK(bunicode_str_width("👩‍💻", strlen("👩‍💻")) == 4); /* scalar compatibility */
  CHECK(bunicode_str_width("\x80\xe2\x82", 3) == 3);
  s = "日本語a"; int used;
  CHECK(bunicode_str_take(s, strlen(s), 3, &used) == strlen("日") && used == 2);
  CHECK(bunicode_str_take(s, strlen(s), INT_MAX, &used) == strlen(s) && used == 7);
  CHECK(bunicode_str_take(s, strlen(s), -1, &used) == 0 && used == 0);
  CHECK(bunicode_str_take(NULL, 0, 0, &used) == 0 && used == 0);
  CHECK(bunicode_str_take("e\xcc\x81x", 4, 1, &used) == 3 && used == 1);
}
int main(int argc, char **argv) {
  CHECK(argc == 2); conformance(argv[1]);
  CHECK(bunicode_width('a') == 1 && bunicode_width(0) == 0);
  CHECK(bunicode_width(0x301) == 0 && bunicode_width(0x200d) == 0);
  CHECK(bunicode_width(0xad) == 1 && bunicode_width(0x4e00) == 2);
  CHECK(bunicode_width(0x1160) == 0 && bunicode_width(0x1fae9) == 2);
  CHECK(bunicode_width(0xd800) == 1 && bunicode_width(UINT32_MAX) == 1);
  for (uint32_t cp = 0; cp <= 0x10ffff; cp++) {
    uint16_t props = bunicode_properties(cp);
    CHECK((props & BU_WIDTH_MASK) <= 2);
    CHECK(((props >> BU_GCB_SHIFT) & BU_GCB_MASK) <= BU_LVT);
    CHECK(bunicode_width(cp) == (props & BU_WIDTH_MASK));
  }
  width(NULL, 0, 0, 0);
  WIDTH(1, 2, 'e', 0x301, 'x');
  WIDTH(2, 3, 0x1f469, 0x200d, 0x1f4bb, 'x');
  WIDTH(2, 2, 0x1f1ec, 0x1f1e7, 0x1f1fa, 0x1f1f8);
  WIDTH(2, 2, 0x1f44d, 0x1f3ff, 'x');
  WIDTH(2, 3, 0x1100, 0x1161, 0x11a8, 'x');
  WIDTH(2, 2, 0x2764, 0xfe0f, 'x');
  WIDTH(1, 2, 0x231a, 0xfe0e, 'x');
  WIDTH(1, 3, 'a', 0xfe0f, 0xfe0f, 'x');
  WIDTH(0, 2, '\r', '\n', 'x');
  WIDTH(1, 1, UINT32_MAX, 0x301);
  WIDTH(1, 1, 'a', UINT32_MAX);
  WIDTH(2, 3, 0x915, 0x94d, 0x915, 'x');
  CHECK(bunicode_grapheme_width_effect('a', 0xfe0f) == BU_WIDTH_IGNORE);
  CHECK(bunicode_grapheme_width_effect(0x2764, 0xfe0f) == BU_WIDTH_WIDE);
  CHECK(bunicode_grapheme_width_effect(0x231a, 0xfe0e) == BU_WIDTH_NARROW);
  CHECK(bunicode_grapheme_width_effect('e', 0x301) == BU_WIDTH_UNCHANGED);
  /* More than a byte of RI pairs must not overflow state or flip parity. */
  bunicode_grapheme_state state = {0};
  for (unsigned i = 0; i < 10000; i++) CHECK(bunicode_grapheme_break(&state, 0x1f1ec) == !(i & 1));
  decoding();
  puts("Unicode scalar properties, terminal widths and bounded UTF-8 passed"); return 0;
}
