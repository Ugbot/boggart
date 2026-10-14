/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/unicode/grapheme.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 */
#include "btunicode.h"
#include "btunicode_data.h"
#include "lgrapheme.h"
#include <limits.h>
static bool valid(uint32_t cp) {
  return cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff);
}
static uint16_t properties(uint32_t cp) {
  return btunicode_pages[(size_t)btunicode_index[cp >> 8] * 256 + (cp & 255)];
}
unsigned btunicode_width(uint32_t cp) {
  /* The printer filters controls first and uses this byte-sized fast path. */
  return cp <= 255 || !valid(cp) ? 1 : properties(cp) & 3;
}
bool btunicode_break(btunicode_state *s, uint32_t cp) {
  bool boundary = true;
  if (s->started && valid(s->previous) && valid(cp)) {
    unsigned a = (properties(s->previous) >> 3) & 31;
    unsigned b = (properties(cp) >> 3) & 31;
    unsigned value = btunicode_transitions[s->machine | (a << 3) | (b << 8)];
    boundary = (value & 1) != 0;
    s->machine = (uint8_t)(value >> 1);
  } else s->machine = 0;
  s->previous = cp; s->started = true;
  return boundary;
}
bool btunicode_pictographic(uint32_t cp) {
  return valid(cp) && ((properties(cp) >> 3) & 31) == 11;
}
bunicode_width_effect btunicode_effect(uint32_t previous, uint32_t cp) {
  if (cp == 0xfe0e || cp == 0xfe0f) {
    if (!valid(previous) || !(properties(previous) & 256)) return BU_WIDTH_IGNORE;
    return cp == 0xfe0f ? BU_WIDTH_WIDE : BU_WIDTH_NARROW;
  }
  return valid(cp) && (properties(cp) & 4) ? BU_WIDTH_UNCHANGED : BU_WIDTH_WIDE;
}

static unsigned text_scalar_width(uint32_t cp) {
  return cp<32 || cp==127 ? 0 : btunicode_width(cp);
}
/* One effective native text cluster, including ignored source suffixes. The
 * stored DFA/previous scalar stop advancing at the page's retention cap. */
static const char *text_cluster(const char *p,const char *end,bool grapheme,unsigned *width,btunicode_text_cluster *out) {
  uint32_t previous;const char *next=bunicode_utf8_next(p,end,&previous);
  *width=text_scalar_width(previous);if(!*width)return next;
  if(out)out->length=bunicode_utf8_put(previous,out->text);
  btunicode_state state={0};(void)btunicode_break(&state,previous);size_t retained=1;
  p=next;
  while(p<end) {
    uint32_t cp;next=bunicode_utf8_next(p,end,&cp);unsigned scalar=text_scalar_width(cp);
    if(cp<32 || cp==127){p=next;continue;}
    if(!grapheme) {
      if(scalar)break;
      if(retained<LG_LIMIT && !((cp==0xfe0e || cp==0xfe0f) && !btunicode_pictographic(previous))) {
        if(out)out->length+=bunicode_utf8_put(cp,out->text+out->length);
        retained++;
      }
      p=next;continue;
    }
    btunicode_state candidate=state;
    bool boundary=cp<=255 || btunicode_break(&candidate,cp);
    if(boundary) {
      if(scalar)break;
      p=next;continue;
    }
    bunicode_width_effect effect=btunicode_effect(previous,cp);
    if(effect!=BU_WIDTH_IGNORE) {
      if(effect==BU_WIDTH_WIDE)*width=2;
      else if(effect==BU_WIDTH_NARROW)*width=1;
      if(retained<LG_LIMIT){
        if(out)out->length+=bunicode_utf8_put(cp,out->text+out->length);
        state=candidate;previous=cp;retained++;
      }
    }
    p=next;
  }
  return p;
}
int btunicode_text_width(const char *text,size_t length,bool grapheme) {
  if(!length || !text)return 0;
  const char *p=text,*end=text+length;int total=0;
  while(p<end) {
    unsigned width;p=text_cluster(p,end,grapheme,&width,NULL);
    if(total>INT_MAX-(int)width)return INT_MAX;
    total+=(int)width;
  }
  return total;
}
size_t btunicode_text_take(const char *text,size_t length,int columns,bool grapheme,int *used) {
  if(used)*used=0;
  if(!length || !text || columns<0)return 0;
  const char *p=text,*end=text+length;int total=0;
  while(p<end) {
    unsigned width;const char *next=text_cluster(p,end,grapheme,&width,NULL);
    if((int)width>columns-total)break;
    total+=(int)width;p=next;
  }
  if(used)*used=total;
  return (size_t)(p-text);
}
size_t btunicode_text_next(const char *text,size_t length,bool grapheme,btunicode_text_cluster *out) {
  if(out){out->width=0;out->length=0;}
  if(!text || !length)return 0;
  unsigned width;const char *next=text_cluster(text,text+length,grapheme,&width,out);
  if(out)out->width=width;return (size_t)(next-text);
}
