#include "bunicode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
  puts("Unicode scalar properties and terminal width vectors passed"); return 0;
}
