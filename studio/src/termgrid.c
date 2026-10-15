#include "termgrid.h"
#include "bunicode.h"
#include <stdlib.h>
#include <string.h>
static void hash_row(tg_row *row) {
  row->hash=UINT64_C(14695981039346656037);
  const uint8_t *data=(const uint8_t *)row->cells;
  for(size_t i=0;i<row->bytes-sizeof *row;i++){row->hash^=data[i];row->hash*=UINT64_C(1099511628211);}
}
tg_row *tg_capture(const bterm *term,const lpage_row *source,size_t columns) {
  if(!term || !source || !columns || columns>4096 || source->columns!=columns)return NULL;
  const lpage_screen *screen=bterm_screen(term);
  if(columns!=lpage_columns(screen))return NULL;
  size_t bytes=sizeof(tg_row)+columns*sizeof(tg_cell);
  for(size_t x=0;x<columns;x++){
    lgrapheme_value value=lpage_grapheme(screen,&source->cells[x]);char encoded[4];
    for(size_t i=0;i<value.length;i++)bytes+=bunicode_utf8_put(value.codepoints[i],encoded);
    bytes++;
  }
  if(bytes>UINT32_MAX)return NULL;
  tg_row *row=calloc(1,bytes);if(!row)return NULL;
  row->references=1;row->columns=(uint32_t)columns;row->bytes=(uint32_t)bytes;
  char *text=(char *)(row->cells+columns);
  for(size_t x=0;x<columns;x++){
    const lpage_cell *in=&source->cells[x];tg_cell *out=&row->cells[x];
    const lpage_style *style=bterm_style(term,in->style);if(style)out->style=*style;
    out->width=in->width;out->flags=in->flags;out->text=(uint32_t)(text-(char *)row);
    lgrapheme_value value=lpage_grapheme(screen,in);
    for(size_t i=0;i<value.length;i++)text+=bunicode_utf8_put(value.codepoints[i],text);
    out->length=(uint16_t)((size_t)(text-(char *)row)-out->text);*text++=0;
  }
  hash_row(row);
  return row;
}
tg_row *tg_capture_values(const tg_value *values,size_t columns) {
  if(!values || !columns || columns>4096)return NULL;
  size_t bytes=sizeof(tg_row)+columns*sizeof(tg_cell);
  for(size_t i=0;i<columns;i++) {
    const tg_value *v=&values[i];
    if(v->length>UINT16_MAX || (v->length && !v->text) || v->width>2 || (v->flags&~15u))return NULL;
    bytes+=v->length+1;
  }
  if(bytes>UINT32_MAX)return NULL;
  tg_row *row=calloc(1,bytes);if(!row)return NULL;
  row->references=1;row->columns=(uint32_t)columns;row->bytes=(uint32_t)bytes;
  char *text=(char *)(row->cells+columns);
  for(size_t i=0;i<columns;i++) {
    const tg_value *v=&values[i];tg_cell *cell=&row->cells[i];
    cell->style=v->style;cell->width=v->width;cell->flags=v->flags;
    cell->text=(uint32_t)(text-(char *)row);cell->length=(uint16_t)v->length;
    if(v->length)memcpy(text,v->text,v->length);text+=v->length;*text++=0;
  }
  hash_row(row);return row;
}
bool tg_retain(tg_row *row) {if(!row || row->references==UINT32_MAX)return false;row->references++;return true;}
void tg_release(tg_row *row) {if(row && --row->references==0)free(row);}
bool tg_equal(const tg_row *a,const tg_row *b) {
  return a && b && a->columns==b->columns && a->bytes==b->bytes && a->hash==b->hash
    && !memcmp(a->cells,b->cells,a->bytes-sizeof *a);
}
const char *tg_text(const tg_row *row,const tg_cell *cell) {return (const char *)row+cell->text;}
