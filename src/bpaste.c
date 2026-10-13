/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/input/paste.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: caller-owned binary buffers and atomic capacity validation;
 * memmove permits overlapping input/output without a transient allocation.
 */
#include "bpaste.h"
#include <string.h>
static const uint8_t prefix[]="\033[200~", suffix[]="\033[201~";
static bool stripped(uint8_t b) {
  /* Same xterm-derived replacements as the pinned paste encoder. */
  switch(b) {
    case 0x00: case 0x08: case 0x05: case 0x04: case 0x1b: case 0x7f:
    case 0x03: case 0x1c: case 0x15: case 0x1a: case 0x11: case 0x13:
    case 0x17: case 0x16: case 0x12: case 0x0f: return true;
    default: return false;
  }
}
bool bpaste_encode(const uint8_t *data,size_t size,bool bracketed,
                    uint8_t *output,size_t capacity,size_t *length) {
  *length=0;
  size_t frame=bracketed ? BPASTE_FRAME_SIZE : 0;
  if((!data && size) || size>SIZE_MAX-frame)return false;
  size_t n=size+frame, start=bracketed ? sizeof prefix-1 : 0;
  if(n>capacity || (!output && n))return false;
  if(size)memmove(output+start,data,size);
  for(size_t i=0;i<size;i++) {
    uint8_t *b=output+start+i;
    if(stripped(*b))*b=' ';
    else if(!bracketed && *b=='\n')*b='\r';
  }
  if(bracketed) {
    memcpy(output,prefix,sizeof prefix-1);
    memcpy(output+start+size,suffix,sizeof suffix-1);
  }
  *length=n;return true;
}
bool bpaste_safe(const uint8_t *data,size_t size,bool bracketed) {
  if(!data && size)return false;
  for(size_t i=0;i<size;i++) {
    if(!bracketed && data[i]=='\n')return false;
    if(data[i]==suffix[0] && size-i>=sizeof suffix-1 && !memcmp(data+i,suffix,sizeof suffix-1))return false;
  }
  return true;
}
