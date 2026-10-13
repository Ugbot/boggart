/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/mouse_encode.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: host-normalized integer terminal pixels, bounded geometry and
 * atomic output/state updates; no renderer or platform dependency.
 */
#include "bmouse.h"
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
static size_t utf8(uint32_t cp, uint8_t *out) {
  if (cp < 128) { out[0]=(uint8_t)cp; return 1; }
  if (cp < 2048) { out[0]=(uint8_t)(0xc0 | (cp>>6)); out[1]=(uint8_t)(0x80 | (cp&63)); return 2; }
  out[0]=(uint8_t)(0xe0 | (cp>>12)); out[1]=(uint8_t)(0x80 | ((cp>>6)&63)); out[2]=(uint8_t)(0x80 | (cp&63)); return 3;
}
static uint32_t cell(int32_t pixel, uint32_t size, uint32_t count) {
  if (pixel < 0) return 0;
  uint32_t value=(uint32_t)pixel/size;
  return value < count ? value : count-1;
}
bool bmouse_encode(const bmouse_event *e, const bmouse_options *o, bmouse_motion *last,
                     uint8_t *output, size_t capacity, size_t *length) {
  *length=0;
  if ((unsigned)o->mode > BM_ANY || (unsigned)o->format > BM_PIXELS || (unsigned)e->action > BM_MOTION
      || e->button > 9 || (!e->button && e->action != BM_MOTION) || (e->modifiers & ~(BI_SHIFT|BI_ALT|BI_CTRL))
      || !o->columns || o->columns > 4096 || !o->rows || o->rows > 4096
      || !o->cell_width || o->cell_width > 65535 || !o->cell_height || o->cell_height > 65535) return false;
  if (o->mode == BM_NONE || (o->mode == BM_X10 && (e->action != BM_PRESS || e->button > 3 || !e->button))
      || (o->mode == BM_NORMAL && e->action == BM_MOTION) || (o->mode == BM_BUTTON && !e->button)) return true;
  bool outside = e->x < 0 || e->y < 0 || (uint32_t)e->x > o->columns*o->cell_width || (uint32_t)e->y > o->rows*o->cell_height;
  if (e->action != BM_RELEASE && outside && (!(o->mode == BM_BUTTON || o->mode == BM_ANY) || !e->any_button_pressed)) return true;
  uint32_t x=cell(e->x,o->cell_width,o->columns), y=cell(e->y,o->cell_height,o->rows);
  if (e->action == BM_MOTION && o->format != BM_PIXELS && last && last->valid && last->column == x && last->row == y) return true;
  unsigned code;
  if (!e->button || (e->action == BM_RELEASE && o->format != BM_SGR && o->format != BM_PIXELS)) code=3;
  else if (e->button <= 3) code=e->button-1;
  else if (e->button <= 7) code=e->button+60;
  else code=e->button+120;
  if (o->mode != BM_X10) {
    if (e->modifiers & BI_SHIFT) code+=4;
    if (e->modifiers & BI_ALT) code+=8;
    if (e->modifiers & BI_CTRL) code+=16;
  }
  if (e->action == BM_MOTION) code+=32;
  uint8_t bytes[BMOUSE_CAPACITY]; size_t n;
  if (o->format == BM_FORMAT_X10) {
    if (x > 222 || y > 222) return true;
    bytes[0]=27; bytes[1]='['; bytes[2]='M'; bytes[3]=(uint8_t)(32+code);
    bytes[4]=(uint8_t)(33+x); bytes[5]=(uint8_t)(33+y); n=6;
  } else if (o->format == BM_UTF8) {
    bytes[0]=27; bytes[1]='['; bytes[2]='M'; n=3;
    n+=utf8(32+code,bytes+n); n+=utf8(x+33,bytes+n); n+=utf8(y+33,bytes+n);
  } else {
    int written;
    if (o->format == BM_PIXELS) written=snprintf((char *)bytes,sizeof bytes,"\033[<%u;%" PRId32 ";%" PRId32 "%c",code,e->x,e->y,e->action == BM_RELEASE ? 'm' : 'M');
    else if (o->format == BM_SGR) written=snprintf((char *)bytes,sizeof bytes,"\033[<%u;%u;%u%c",code,x+1,y+1,e->action == BM_RELEASE ? 'm' : 'M');
    else written=snprintf((char *)bytes,sizeof bytes,"\033[%u;%u;%uM",32+code,x+1,y+1);
    if (written < 0 || (size_t)written >= sizeof bytes) return false;
    n=(size_t)written;
  }
  if (n > capacity || (!output && n)) return false;
  memcpy(output,bytes,n); *length=n;
  if (last) *last=(bmouse_motion){true,x,y};
  return true;
}
