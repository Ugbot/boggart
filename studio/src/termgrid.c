#include "termgrid.h"
#include <stdlib.h>
#include <string.h>
static size_t encode(uint32_t cp,char *out) {
  if(cp>0x10ffff || (cp>=0xd800 && cp<=0xdfff))cp=0xfffd;
  if(cp<0x80){out[0]=(char)cp;return 1;}
  if(cp<0x800){out[0]=(char)(0xc0|(cp>>6));out[1]=(char)(0x80|(cp&63));return 2;}
  if(cp<0x10000){out[0]=(char)(0xe0|(cp>>12));out[1]=(char)(0x80|((cp>>6)&63));out[2]=(char)(0x80|(cp&63));return 3;}
  out[0]=(char)(0xf0|(cp>>18));out[1]=(char)(0x80|((cp>>12)&63));out[2]=(char)(0x80|((cp>>6)&63));out[3]=(char)(0x80|(cp&63));return 4;
}
tg_row *tg_capture(const bterm *term,const lpage_row *source,size_t columns) {
  if(!term || !source || !columns || columns>4096 || source->columns!=columns)return NULL;
  const lpage_screen *screen=bterm_screen(term);
  if(columns!=lpage_columns(screen))return NULL;
  size_t bytes=sizeof(tg_row)+columns*sizeof(tg_cell);
  for(size_t x=0;x<columns;x++){
    lgrapheme_value value=lpage_grapheme(screen,&source->cells[x]);char encoded[4];
    for(size_t i=0;i<value.length;i++)bytes+=encode(value.codepoints[i],encoded);
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
    for(size_t i=0;i<value.length;i++)text+=encode(value.codepoints[i],text);
    out->length=(uint16_t)((size_t)(text-(char *)row)-out->text);*text++=0;
  }
  row->hash=UINT64_C(14695981039346656037);
  const uint8_t *data=(const uint8_t *)row->cells;
  for(size_t i=0;i<bytes-sizeof *row;i++){row->hash^=data[i];row->hash*=UINT64_C(1099511628211);}
  return row;
}
bool tg_retain(tg_row *row) {if(!row || row->references==UINT32_MAX)return false;row->references++;return true;}
void tg_release(tg_row *row) {if(row && --row->references==0)free(row);}
bool tg_equal(const tg_row *a,const tg_row *b) {
  return a && b && a->columns==b->columns && a->bytes==b->bytes && a->hash==b->hash
    && !memcmp(a->cells,b->cells,a->bytes-sizeof *a);
}
const char *tg_text(const tg_row *row,const tg_cell *cell) {return (const char *)row+cell->text;}
