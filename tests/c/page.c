#include "lpage.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
/* An intentionally simple shifting reference screen exercises the paged and
 * ring-backed implementation across allocation, eviction and history-clear. */
typedef struct { lpage_cell cells[9]; bool wrapped; } reference_row;
static uint32_t random_state = 1;
static uint32_t random_next(void) {
  random_state ^= random_state << 13; random_state ^= random_state >> 17;
  return random_state ^= random_state << 5;
}
static void blank(reference_row *r, uint32_t style) {
  r->wrapped = false;
  for (size_t x = 0; x < 9; x++) r->cells[x] = (lpage_cell){0, style, 0, 1, 0, 0};
}
static void compare_row(const lpage_row *actual, const reference_row *expected, size_t refs[9]) {
  CHECK(actual && actual->columns == 9 && actual->wrapped == expected->wrapped);
  for (size_t x = 0; x < 9; x++) {
    CHECK(!memcmp(&actual->cells[x], &expected->cells[x], sizeof(lpage_cell)));
    CHECK(actual->cells[x].style < 9); refs[actual->cells[x].style]++;
  }
}
static void model_test(size_t rows, size_t limit) {
  lpage_screen *s = lpage_create(9, rows, limit);
  CHECK(s);
  lstyle_pool *styles = lpage_styles(s);
  uint32_t ids[9] = {0};
  for (uint32_t i = 1; i < 9; i++) {
    lpage_style style = { LP_COLOR_RGB | i, 0, 0, i & 1 ? LP_BOLD : LP_ITALIC };
    CHECK(lstyle_acquire(styles, &style, &ids[i]) && ids[i] == i);
  }
  reference_row visible[20], history[37]; size_t history_count = 0;
  for (size_t y = 0; y < rows; y++) blank(&visible[y], 0);
  for (size_t step = 0; step < 10000; step++) {
    unsigned op = random_next() % 8;
    size_t y = random_next() % rows, x = random_next() % 10, n = random_next() % 12;
    uint32_t style = ids[random_next() % 9];
    size_t count = n > 9 - x ? 9 - x : n;
    if (op == 0 && x < 9) {
      lpage_cell cell = { random_next(), style, random_next(), 1, 0, 0 };
      CHECK(lpage_put(s, y, x, cell)); visible[y].cells[x] = cell;
    } else if (op == 1) {
      CHECK(lpage_erase(s, y, x, n, style));
      for (size_t i = x; i < x + count; i++) visible[y].cells[i] = (lpage_cell){0, style, 0, 1, 0, 0};
      if (x == 0 && count == 9) visible[y].wrapped = false;
    } else if (op == 2 || op == 3) {
      CHECK(op == 2 ? lpage_insert_cells(s, y, x, n, style) : lpage_delete_cells(s, y, x, n, style));
      reference_row old = visible[y];
      for (size_t i = x; i < 9; i++) {
        bool retained = op == 2 ? i >= x + count : i < 9 - count;
        visible[y].cells[i] = retained ? old.cells[op == 2 ? i - count : i + count]
          : (lpage_cell){0, style, 0, 1, 0, 0};
      }
      visible[y].wrapped = false;
    } else if (op == 4 || op == 5) {
      size_t top = op == 4 ? 0 : y, bottom = op == 4 ? rows - 1 : y + random_next() % (rows - y);
      bool up = random_next() & 1, save = random_next() & 1;
      int amount = (int)n;
      CHECK(lpage_scroll(s, top, bottom, up ? amount : -amount, save, style));
      if (n > bottom - top + 1) n = bottom - top + 1;
      for (size_t i = 0; i < n; i++) {
        if (up) {
          if (save && !top && bottom + 1 == rows && limit) {
            if (history_count == limit) {
              for (size_t j = 1; j < history_count; j++) history[j - 1] = history[j];
              history_count--;
            }
            history[history_count++] = visible[top];
          }
          for (size_t j = top; j < bottom; j++) visible[j] = visible[j + 1];
          blank(&visible[bottom], style);
        } else {
          for (size_t j = bottom; j > top; j--) visible[j] = visible[j - 1];
          blank(&visible[top], style);
        }
      }
    } else if (op == 6) {
      bool wrapped = random_next() & 1;
      lpage_wrap(s, y, wrapped); visible[y].wrapped = wrapped;
    } else if (op == 7) {
      lpage_clear_history(s); history_count = 0;
    }
    size_t refs[9] = {0};
    CHECK(lpage_history_count(s) == history_count);
    for (size_t i = 0; i < rows; i++) compare_row(lpage_visible(s, i), &visible[i], refs);
    for (size_t i = 0; i < history_count; i++) compare_row(lpage_history(s, i), &history[i], refs);
    for (size_t i = 1; i < 9; i++) CHECK(lstyle_refs(styles, ids[i]) == refs[i] + 1);
  }
  for (size_t i = 1; i < 9; i++) lstyle_release(styles, ids[i]);
  lpage_destroy(s);
}
int main(void) {
  lstyle_pool *styles = lstyle_create();
  CHECK(styles);
  lpage_style red = { LP_COLOR_INDEXED | 1, LP_COLOR_RGB | 0x123456, 0, LP_BOLD };
  uint32_t a, b;
  CHECK(lstyle_acquire(styles, &red, &a) && lstyle_acquire(styles, &red, &b));
  CHECK(a == b && lstyle_refs(styles, a) == 2);
  lstyle_release(styles, a); CHECK(lstyle_refs(styles, b) == 1);
  lstyle_release(styles, b); CHECK(!lstyle_get(styles, b) && lstyle_count(styles) == 1);
  for (uint32_t i = 1; i <= 1000; i++) {
    lpage_style unique = { LP_COLOR_RGB | i, 0, 0, 0 };
    CHECK(lstyle_acquire(styles, &unique, &a)); lstyle_release(styles, a);
  }
  CHECK(lstyle_count(styles) == 1 && lstyle_bytes(styles) < 2048);
  uint32_t ids[200];
  for (uint32_t i = 0; i < 200; i++) {
    lpage_style unique = { LP_COLOR_RGB | i, 0, 0, LP_ITALIC };
    CHECK(lstyle_acquire(styles, &unique, &ids[i]));
  }
  for (uint32_t i = 0; i < 200; i++) {
    CHECK(lstyle_get(styles, ids[i])->fg == (LP_COLOR_RGB | i));
    lstyle_release(styles, ids[i]);
  }
  lstyle_destroy(styles);

  lpage_screen *s = lpage_create(8, 3, 2);
  CHECK(s && lpage_columns(s) == 8 && lpage_rows(s) == 3);
  styles = lpage_styles(s);
  CHECK(lstyle_acquire(styles, &red, &a));
  lpage_cell cell = { 'A', a, 0, 1, 0, 0 };
  CHECK(lpage_put(s, 0, 0, cell));
  CHECK(lstyle_refs(styles, a) == 2);
  lstyle_release(styles, a);
  CHECK(lstyle_refs(styles, a) == 1);
  CHECK(lpage_get(s, 0, 0)->codepoint == 'A');
  lpage_ack_damage(s);
  CHECK(!lpage_dirty(s, 0));
  CHECK(lpage_put(s, 1, 0, (lpage_cell){ 'B', 0, 0, 1, 0, 0 }));
  CHECK(lpage_dirty(s, 1) && !lpage_dirty(s, 0));
  CHECK(lpage_put(s, 2, 0, (lpage_cell){ 'C', 0, 0, 1, 0, 0 }));
  lpage_wrap(s, 0, true);
  CHECK(lpage_scroll(s, 0, 2, 1, true, 0));
  CHECK(lpage_history_count(s) == 1 && lpage_history(s, 0)->cells[0].codepoint == 'A');
  CHECK(lpage_history(s, 0)->wrapped);
  CHECK(lpage_get(s, 0, 0)->codepoint == 'B' && lpage_get(s, 1, 0)->codepoint == 'C');
  CHECK(lpage_dirty(s, 0) && lpage_dirty(s, 2));
  CHECK(lpage_scroll(s, 0, 2, 1, true, 0));
  CHECK(lpage_scroll(s, 0, 2, 1, true, 0));
  CHECK(lpage_history_count(s) == 2 && lpage_history(s, 0)->cells[0].codepoint == 'B');
  CHECK(lstyle_count(styles) == 1); /* A's style died with the evicted history. */
  lpage_stats warm = lpage_usage(s);
  for (int i = 0; i < 10000; i++) {
    CHECK(lpage_put(s, 2, 0, (lpage_cell){ (uint32_t)i, 0, 0, 1, 0, 0 }));
    CHECK(lpage_scroll(s, 0, 2, 1, true, 0));
  }
  CHECK(lpage_usage(s).bytes == warm.bytes && lpage_history_count(s) == 2);
  CHECK(lpage_put(s, 0, 0, (lpage_cell){ 'x', 0, 0, 1, 0, 0 }));
  CHECK(lpage_put(s, 1, 0, (lpage_cell){ 'y', 0, 0, 1, 0, 0 }));
  CHECK(lpage_put(s, 2, 0, (lpage_cell){ 'z', 0, 0, 1, 0, 0 }));
  CHECK(lpage_scroll(s, 1, 2, -1, false, 0));
  CHECK(lpage_get(s, 0, 0)->codepoint == 'x' && lpage_get(s, 2, 0)->codepoint == 'y');
  CHECK(lpage_get(s, 1, 0)->codepoint == 0 && lpage_history_count(s) == 2);
  CHECK(lstyle_acquire(styles, &red, &a));
  CHECK(lpage_erase(s, 0, 0, 8, a));
  CHECK(lstyle_refs(styles, a) == 9);
  lstyle_release(styles, a);
  CHECK(lpage_insert_cells(s, 0, 2, 3, 0));
  CHECK(lstyle_refs(styles, a) == 5);
  CHECK(lpage_delete_cells(s, 0, 1, 4, 0));
  CHECK(lstyle_refs(styles, a) == 4);
  lpage_clear_history(s);
  CHECK(lpage_history_count(s) == 0);
  CHECK(!lpage_put(s, 3, 0, cell) && !lpage_get(s, 0, 8));
  CHECK(!lpage_create(0, 3, 2));
  lpage_destroy(s);
  model_test(1, 0); model_test(5, 1); model_test(20, 37);
  puts("Page storage: style ownership, scrollback recycling, region edits and damage passed");
  return 0;
}
