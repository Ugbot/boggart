#include "lpage.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static void narrow(lpage_screen *s, size_t x, uint32_t cp) {
  CHECK(lpage_put(s, 0, x, (lpage_cell){cp, 0, 0, 1, 0, 0}));
}
static void wide(lpage_screen *s, size_t x) {
  CHECK(lpage_put(s, 0, x, (lpage_cell){0x65e5, 0, 0, 2, 0, 0}));
}
static void shape(lpage_screen *s, const char *expected) {
  CHECK(strlen(expected) == lpage_columns(s));
  for (size_t x = 0; x < lpage_columns(s); x++) {
    const lpage_cell *c = lpage_get(s, 0, x);
    if (expected[x] == 'W') CHECK(c->codepoint == 0x65e5 && c->width == 2 && !c->flags);
    else if (expected[x] == '-') CHECK(!c->codepoint && !c->width && c->flags == LP_CELL_WIDE_TAIL);
    else CHECK(c->codepoint == (expected[x] == ' ' ? 0 : (uint32_t)(uint8_t)expected[x]) && c->width == 1 && !c->flags);
  }
}
static void clear(lpage_screen *s) { CHECK(lpage_erase(s, 0, 0, lpage_columns(s), 0)); }
static void vectors(void) {
  lpage_screen *s = lpage_create(6, 1, 2); CHECK(s && sizeof(lpage_cell) == 16);
  wide(s, 1); shape(s, " W-   "); narrow(s, 1, 'a'); shape(s, " a    ");
  wide(s, 1); narrow(s, 2, 'b'); shape(s, "  b   ");
  clear(s); wide(s, 1); wide(s, 3); wide(s, 2); shape(s, "  W-  ");
  CHECK(!lpage_put(s, 0, 5, (lpage_cell){0x65e5, 0, 0, 2, 0, 0})); shape(s, "  W-  ");
  CHECK(!lpage_put(s, 0, 0, (lpage_cell){0, 0, 0, 0, LP_CELL_WIDE_TAIL, 0})); shape(s, "  W-  ");
  CHECK(!lpage_put(s, 0, 2, (lpage_cell){'X', 9999, 0, 1, 0, 0})); shape(s, "  W-  ");
  CHECK(lpage_erase(s, 0, 3, 1, 0)); shape(s, "      ");
  wide(s, 2); CHECK(lpage_erase(s, 0, 2, 1, 0)); shape(s, "      ");
  wide(s, 2); CHECK(lpage_erase(s, 0, 3, 0, 0)); shape(s, "  W-  ");
  CHECK(lpage_insert_cells(s, 0, 2, 1, 0)); shape(s, "   W- ");
  clear(s); wide(s, 2); CHECK(lpage_insert_cells(s, 0, 3, 1, 0)); shape(s, "      ");
  wide(s, 4); CHECK(lpage_insert_cells(s, 0, 0, 1, 0)); shape(s, "      ");
  wide(s, 3); CHECK(lpage_insert_cells(s, 0, 0, 1, 0)); shape(s, "    W-");
  CHECK(lpage_delete_cells(s, 0, 0, 1, 0)); shape(s, "   W- ");
  CHECK(lpage_delete_cells(s, 0, 4, 1, 0)); shape(s, "      ");
  wide(s, 2); CHECK(lpage_delete_cells(s, 0, 1, 2, 0)); shape(s, "      ");
  narrow(s, 0, 'a'); wide(s, 1); narrow(s, 3, 'b');
  CHECK(lpage_delete_cells(s, 0, 1, 2, 0)); shape(s, "ab    ");
  clear(s); wide(s, 4); lpage_wrap(s, 0, true);
  CHECK(lpage_scroll(s, 0, 0, 1, true, 0)); shape(s, "      ");
  const lpage_row *h = lpage_history(s, 0);
  CHECK(h && h->wrapped && h->cells[4].width == 2 && h->cells[5].flags == LP_CELL_WIDE_TAIL);
  lpage_wrap(s, 0, true);
  CHECK(lpage_put(s, 0, 5, (lpage_cell){0, 0, 0, 1, LP_CELL_WIDE_HEAD, 0}));
  CHECK(lpage_delete_cells(s, 0, 0, 1, 0)); shape(s, "      ");
  CHECK(!lpage_put(s, 0, 3, (lpage_cell){0, 0, 0, 1, LP_CELL_WIDE_HEAD, 0}));
  lpage_clear_history(s); lpage_destroy(s);
}
static uint32_t seed = 0x31415926;
static uint32_t random_value(void) { seed ^= seed << 13; seed ^= seed >> 17; return seed ^= seed << 5; }
static void inspect(lpage_screen *s, const lpage_row *r, size_t *styles, size_t *links, size_t *graphemes) {
  CHECK(r);
  for (size_t x = 0; x < r->columns; x++) {
    const lpage_cell *c = &r->cells[x];
    CHECK(c->style < 4 && c->hyperlink < 4); styles[c->style]++; links[c->hyperlink]++;
    if (c->flags & LP_CELL_GRAPHEME) {
      CHECK(c->codepoint<256); graphemes[c->codepoint]++;
      lgrapheme_value v=lpage_grapheme(s,c);
      CHECK(v.length==2 && v.codepoints[0]==0x65e5 && v.codepoints[1]==0x301);
    }
    if (c->flags & LP_CELL_WIDE_TAIL) {
      CHECK(x && !c->codepoint && !c->width && r->cells[x-1].width == 2);
      CHECK(c->style == r->cells[x-1].style && c->hyperlink == r->cells[x-1].hyperlink);
    } else if (c->width == 2) CHECK(x + 1 < r->columns && r->cells[x+1].flags & LP_CELL_WIDE_TAIL);
    else CHECK(c->width == 1);
    if (c->flags & LP_CELL_WIDE_HEAD) CHECK(x+1 == r->columns && r->wrapped && !c->codepoint);
  }
}
static void lifetime(void) {
  lpage_screen *s = lpage_create(9, 3, 5); CHECK(s);
  uint32_t styles[4] = {0}, links[4] = {0};
  for (unsigned i = 1; i < 4; i++) {
    lpage_style style = {LP_COLOR_RGB | i, 0, 0, LP_BOLD};
    CHECK(lstyle_acquire(lpage_styles(s), &style, &styles[i]) && styles[i] == i);
    char key[] = {(char)('a' + i)}; llink_value link = {key, "https://example.com", 1, 19};
    CHECK(llink_acquire(lpage_links(s), &link, &links[i]) && links[i] == i);
  }
  for (unsigned i = 0; i < 30000; i++) {
    size_t y = random_value()%3, x = random_value()%9, n = random_value()%12;
    uint32_t style = styles[random_value()%4];
    switch (random_value()%6) {
      case 0: { unsigned w = 1 + random_value()%2; if (w==2 && x==8) w=1;
        CHECK(lpage_put(s,y,x,(lpage_cell){0x65e5,style,links[random_value()%4],(uint8_t)w,0,0}));
        if (random_value()&1) CHECK(lpage_append_grapheme(s,y,x,0x301,w)); break; }
      case 1: CHECK(lpage_erase(s,y,x,n,style)); break;
      case 2: CHECK(lpage_insert_cells(s,y,x,n,style)); break;
      case 3: CHECK(lpage_delete_cells(s,y,x,n,style)); break;
      case 4: CHECK(lpage_scroll(s,0,2,random_value()&1 ? 1 : -1,true,style)); break;
      case 5: lpage_clear_history(s); break;
    }
    size_t style_refs[4]={0}, link_refs[4]={0}, grapheme_refs[256]={0}, count=0;
    for (size_t row=0;row<3;row++) inspect(s,lpage_visible(s,row),style_refs,link_refs,grapheme_refs);
    for (size_t row=0;row<lpage_history_count(s);row++) inspect(s,lpage_history(s,row),style_refs,link_refs,grapheme_refs);
    for (unsigned j=1;j<256;j++) {
      CHECK(lgrapheme_refs(lpage_graphemes(s),j)==grapheme_refs[j]);
      if(grapheme_refs[j]) count++;
    }
    CHECK(lgrapheme_count(lpage_graphemes(s))==count);
    for (unsigned j=1;j<4;j++) {
      CHECK(lstyle_refs(lpage_styles(s),styles[j]) == style_refs[j]+1);
      CHECK(llink_refs(lpage_links(s),links[j]) == link_refs[j]+1);
    }
  }
  for (unsigned j=1;j<4;j++) { lstyle_release(lpage_styles(s),styles[j]); llink_release(lpage_links(s),links[j]); }
  lpage_destroy(s);
}
int main(void) { vectors(); lifetime(); puts("wide pairs, clipping and 30000 ownership operations passed"); return 0; }
