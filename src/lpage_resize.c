/* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/PageList.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/page.zig
 * ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Screen.zig
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 * SPDX-License-Identifier: MIT; see THIRD_PARTY/ghostty-LICENSE.
 * Adaptation: bounded row rings, two cursor pins, shared screen-owned pools,
 * and unpublished geometry so all allocation failures can roll back.
 */
#include "lpage_internal.h"
#include <stdlib.h>

typedef struct { size_t x,y; bool valid; } pin;
typedef struct { lpage_screen *screen; size_t count,y; } output;
struct lpage_resize {
  lpage_screen *source,*geometry;
  lpage_position cursor,saved;
};
static size_t total(const lpage_screen *s) { return lpage_history_count(s)+lpage_rows(s); }
static const lpage_row *source_row(const lpage_screen *s,size_t y) {
  size_t history=lpage_history_count(s);
  return y<history ? lpage_history(s,y) : lpage_visible(s,y-history);
}
static bool next_row_capacity(output *o,size_t capacity) {
  size_t rows=lpage_rows(o->screen);
  if (o->count==SIZE_MAX) return false;
  if (o->count<rows) o->y=o->count;
  else {
    if (!lpage_scroll(o->screen,0,rows-1,1,true,0)) return false;
    o->y=rows-1;
  }
  if (!lp_geometry_row(o->screen,o->y,capacity)) return false;
  o->count++; return true;
}
static bool next_row(output *o) { return next_row_capacity(o,0); }
static void prune_pins(const output *o,pin pins[3]) {
  size_t dropped=o->count-total(o->screen);
  for (unsigned i=0;i<3;i++) if (pins[i].valid) {
    if (pins[i].y<dropped) pins[i].valid=false;
    else pins[i].y-=dropped;
  }
}
static bool empty_cell(const lpage_screen *s,const lpage_cell *c) {
  return !lpage_codepoint(s,c) && c->width==1 && !(c->flags&LP_CELL_WIDE_HEAD)
    && !lstyle_get(lpage_styles((lpage_screen *)s),c->style)->bg;
}
static bool row_text(const lpage_screen *s,const lpage_row *row,size_t columns) {
  size_t n=columns<row->columns ? columns : row->columns;
  for (size_t x=0;x<n;x++) {
    if (row->cells[x].width==2 && x+1==n) break;
    if (lpage_codepoint(s,&row->cells[x])) return true;
  }
  return false;
}
static lpage_screen *crop(const lpage_screen *s,size_t columns,size_t rows,
                          pin pins[3],bool pull,size_t cursor_y) {
  size_t old_rows=lpage_rows(s),end=total(s);
  if (rows<old_rows) {
    size_t remaining=old_rows-rows;
    while (remaining && !row_text(s,source_row(s,end-1),columns)) {
      if ((pins[0].valid && pins[0].y==end-1) || (pins[1].valid && pins[1].y==end-1)) break;
      end--; remaining--;
    }
  }
  lpage_screen *dst=lp_geometry_new(s,columns,rows); if (!dst) return NULL;
  output out={dst,0,0};
  for (size_t y=0;y<end;y++) {
    const lpage_row *row=source_row(s,y);
    size_t capacity=lp_row_capacity(s,y);
    bool rebuild=columns>row->columns && (columns>capacity || lp_row_page_has_head(s,y));
    if (rebuild) capacity=columns;
    if (!next_row_capacity(&out,capacity)) goto fail;
    lpage_wrap(dst,out.y,rebuild ? false : row->wrapped);
    size_t n=columns<row->columns ? columns : row->columns;
    for (size_t x=0;x<n;x++) {
      lpage_cell c=row->cells[x];
      if (c.flags&LP_CELL_WIDE_TAIL) continue;
      if ((c.width==2 && x+1==n) || ((c.flags&LP_CELL_WIDE_HEAD) && x+1!=columns)) continue;
      if (!lpage_put(dst,out.y,x,c)) goto fail;
    }
  }
  if (rows>old_rows && (!pull || cursor_y<old_rows-1))
    for (size_t y=old_rows;y<rows;y++) if (!next_row(&out)) goto fail;
  while (out.count<rows) if (!next_row(&out)) goto fail;
  for (unsigned i=0;i<3;i++) if (pins[i].x>=columns) pins[i].x=columns-1;
  prune_pins(&out,pins); lp_geometry_trim(dst); return dst;
fail:
  lp_geometry_destroy(dst); return NULL;
}
/* Whole unchanged-width requests can transfer rows. Never borrow from the
 * intermediate geometries used by width reflow: they die before commit. */
static lpage_screen *height(lpage_screen *s,size_t rows,pin pins[3],bool pull,size_t cursor_y) {
  size_t old_rows=lpage_rows(s),end=total(s);
  if (rows<old_rows) {
    size_t remaining=old_rows-rows;
    while (remaining && !row_text(s,source_row(s,end-1),lpage_columns(s))) {
      if ((pins[0].valid && pins[0].y==end-1) || (pins[1].valid && pins[1].y==end-1)) break;
      end--; remaining--;
    }
  }
  size_t padding=rows>old_rows && (!pull || cursor_y<old_rows-1) ? rows-old_rows : 0;
  if (end+padding<rows) padding=rows-end;
  lpage_screen *dst=lp_geometry_height(s,rows,end,padding);
  if (!dst) return NULL;
  output out={dst,end+padding,0}; prune_pins(&out,pins); return dst;
}
static size_t wrapped_before(const lpage_screen *s,size_t cursor) {
  size_t top=lpage_history_count(s),wraps=0;
  if (cursor<top || cursor>=total(s)) return 0;
  for (size_t y=top;y<=cursor;y++) if (y && source_row(s,y-1)->wrapped) wraps++;
  return wraps;
}
static void map_pin(pin dest[3],const pin source[3],size_t row,size_t x,const output *out,size_t column) {
  for (unsigned i=0;i<3;i++) if (source[i].valid && source[i].y==row && source[i].x==x)
    dest[i]=(pin){column,out->count-1,true};
}
static void forward(size_t *x,bool *pending,size_t columns) {
  if (*x==columns-1) *pending=true; else (*x)++;
}
static lpage_screen *reflow(const lpage_screen *s,size_t columns,pin pins[3],
                            bool pull,size_t cursor_y) {
  size_t rows=lpage_rows(s),old_wraps=wrapped_before(s,pins[0].y);
  size_t remaining=cursor_y<rows ? rows-cursor_y-1 : 0;
  /* Track the active top to avoid pulling history when requested. */
  pins[2]=(pin){0,lpage_history_count(s),!pull};
  lpage_screen *dst=lp_geometry_new(s,columns,rows); if (!dst) return NULL;
  output out={dst,0,0}; if (!next_row(&out)) goto fail;
  pin mapped[3]={{0,0,false},{0,0,false},{0,0,false}};
  size_t x=0,breaks=0; bool pending=false;
  for (size_t y=0;y<total(s);y++) {
    const lpage_row *row=source_row(s,y); size_t len=row->columns;
    bool continuation=y && source_row(s,y-1)->wrapped;
    if (!row->wrapped) while (len && empty_cell(s,&row->cells[len-1])) len--;
    pin source[3]={pins[0],pins[1],pins[2]};
    size_t start=(breaks || pending) ? 0 : x;
    for (unsigned i=1;i<3;i++) if (source[i].valid && source[i].y==y && source[i].x>=len) {
      size_t last=columns-1-start;
      if (source[i].x>last) source[i].x=last;
    }
    for (unsigned i=0;i<3;i++) if (source[i].valid && source[i].y==y && len<=source[i].x) len=source[i].x+1;
    if (!len) { if (!continuation) breaks++; continue; }
    while (breaks) {
      if (!next_row(&out)) goto fail;
      x=0; pending=false; breaks--;
    }
    for (size_t sx=0;sx<len;) {
      if (pending) {
        lpage_wrap(dst,out.y,true);
        if (!next_row(&out)) goto fail;
        x=0; pending=false;
      }
      lpage_cell c=row->cells[sx];
      map_pin(mapped,source,y,sx,&out,x);
      if (c.flags&LP_CELL_WIDE_HEAD) { sx++; continue; }
      if (c.width==2 && columns>1 && x==columns-1) {
        lpage_wrap(dst,out.y,true);
        if (!lpage_put(dst,out.y,x,(lpage_cell){0,0,0,1,LP_CELL_WIDE_HEAD,0})) goto fail;
        forward(&x,&pending,columns); continue;
      }
      if (c.width==2 && columns==1) {
        /* Whole cluster is discarded; the skipped tail maps after the blank. */
        forward(&x,&pending,columns);
        map_pin(mapped,source,y,sx+1,&out,x); sx+=2; continue;
      }
      if (!lpage_put(dst,out.y,x,c)) goto fail;
      forward(&x,&pending,columns);
      if (c.width==2) {
        map_pin(mapped,source,y,sx+1,&out,x);
        forward(&x,&pending,columns); sx+=2;
      } else sx++;
    }
    if (!row->wrapped) breaks++;
  }
  while (out.count<rows) if (!next_row(&out)) goto fail;
  prune_pins(&out,mapped);
  size_t top=lpage_history_count(dst);
  if (!pull && mapped[2].valid && mapped[2].y>=top) {
    size_t delta=mapped[2].y-top,dropped=out.count-total(dst);
    for (unsigned i=0;i<3;i++) if (mapped[i].valid) mapped[i].y+=dropped;
    for (size_t n=0;n<delta;n++) if (!next_row(&out)) goto fail;
    prune_pins(&out,mapped);
  } else if (pull && mapped[0].valid && mapped[0].y>=top) {
    size_t new_wraps=wrapped_before(dst,mapped[0].y);
    size_t additional=new_wraps>old_wraps ? new_wraps-old_wraps : 0;
    size_t needed=remaining>additional ? remaining-additional : 0;
    size_t below=total(dst)-mapped[0].y-1;
    if (needed>below) {
      /* Pins now refer to retained rows. Restore emission ordinals before
       * appending, since bounded history may discard more rows. */
      size_t dropped=out.count-total(dst);
      for (unsigned i=0;i<3;i++) if (mapped[i].valid) mapped[i].y+=dropped;
      for (size_t n=below;n<needed;n++) if (!next_row(&out)) goto fail;
      prune_pins(&out,mapped);
    }
  }
  pins[0]=mapped[0]; pins[1]=mapped[1]; pins[2]=mapped[2]; lp_geometry_trim(dst); return dst;
fail:
  lp_geometry_destroy(dst); return NULL;
}
static lpage_position position(const lpage_screen *s,pin p,bool pending,bool saved) {
  size_t history=lpage_history_count(s);
  lpage_position result={0,0,saved ? false : pending};
  if (p.valid && p.y>=history && p.y<total(s)) result=(lpage_position){p.x,p.y-history,pending};
  if (result.pending_wrap && result.x!=lpage_columns(s)-1) {
    result.pending_wrap=false; result.x++;
  }
  return result;
}
lpage_resize *lpage_resize_prepare(lpage_screen *s,lpage_resize_options opts) {
  if (!s || !opts.columns || !opts.rows || opts.columns>4096 || opts.rows>4096
      || opts.cursor.x>=lpage_columns(s) || opts.cursor.y>=lpage_rows(s)
      || (opts.saved_valid && (opts.saved.x>=lpage_columns(s) || opts.saved.y>=lpage_rows(s)))) return NULL;
  lpage_resize *r=calloc(1,sizeof *r); if (!r) return NULL; r->source=s;
  size_t history=lpage_history_count(s);
  pin pins[3]={{opts.cursor.x,history+opts.cursor.y,true},{opts.saved.x,history+opts.saved.y,opts.saved_valid},{0,0,false}};
  lpage_screen *first=NULL;
  if (opts.columns==lpage_columns(s)) r->geometry=height(s,opts.rows,pins,opts.pull_scrollback,opts.cursor.y);
  else if (opts.reflow) {
    if (opts.columns<lpage_columns(s)) {
      first=crop(s,lpage_columns(s),opts.rows,pins,opts.pull_scrollback,opts.cursor.y);
      if (first) r->geometry=reflow(first,opts.columns,pins,opts.pull_scrollback,opts.cursor.y);
    } else {
      first=reflow(s,opts.columns,pins,opts.pull_scrollback,opts.cursor.y);
      if (first) r->geometry=crop(first,opts.columns,opts.rows,pins,opts.pull_scrollback,opts.cursor.y);
    }
    lp_geometry_destroy(first);
  } else r->geometry=crop(s,opts.columns,opts.rows,pins,opts.pull_scrollback,opts.cursor.y);
  if (!r->geometry) { free(r); return NULL; }
  r->cursor=position(r->geometry,pins[0],opts.cursor.pending_wrap,false);
  r->saved=position(r->geometry,pins[1],opts.saved.pending_wrap,true);
  return r;
}
lpage_position lpage_resize_cursor(const lpage_resize *r) { return r->cursor; }
lpage_position lpage_resize_saved(const lpage_resize *r) { return r->saved; }
void lpage_resize_commit(lpage_resize *r) { lp_geometry_replace(r->source,r->geometry); free(r); }
void lpage_resize_abort(lpage_resize *r) { if (r) { lp_geometry_destroy(r->geometry); free(r); } }
