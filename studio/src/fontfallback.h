#ifndef BOGGART_FONTFALLBACK_H
#define BOGGART_FONTFALLBACK_H

#include <stddef.h>

/* One font file the system offered us, loaded once and shared by every RenFont.
 * `data` stays mapped for the life of the process -- a CJK face is 8-25 MB and
 * the alternative is a copy per size the UI loads. */
typedef struct {
  char path[512];
  int  index;        /* face within a .ttc collection, 0 for a plain .ttf */
  void *data;        /* NULL until something actually needs a glyph from it */
  size_t size;
  int tried;         /* we have attempted to load it; do not attempt again */
  int usable;        /* loaded, and stb_truetype can rasterise it */
} FontFallback;

/* The discovered chain, in the order it should be consulted. Built on first
 * call and cached in a plain static with no lock, so the first call must happen
 * on the main thread (it does -- renderer bring-up); not safe to call
 * concurrently. Returns count via *n. */
FontFallback* fontfallback_chain(int *n);

/* Map the file behind a chain entry, returning its bytes or NULL. Idempotent,
 * and a failure is remembered so a missing or unreadable font costs one
 * open() for the whole session rather than one per glyph block. */
void* fontfallback_data(FontFallback *f, size_t *size);

#endif
