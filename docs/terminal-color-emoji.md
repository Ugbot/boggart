# Color emoji rendering

The native terminal/grid renderer can preserve color glyphs from installed
sbix (Apple Color Emoji), CBDT/CBLC (Noto Color Emoji) and FreeType's COLRv0
path. Native cell records remain the source of cursor advance: an emoji sequence
does not move its following character when the fallback font has a wider em.

Emoji presentation prefers a color face. VS16 selects that presentation; VS15
prefers a monochrome face. The HarfBuzz run covers the complete retained cluster,
including ZWJ sequences, flag pairs, modifiers and keycaps. A color face whose
glyphs cannot actually be rasterized is skipped rather than publishing blank ink.

Bitmap-only fonts select the nearest available strike. The raster path resamples
the bitmap and bearings to the requested em size, interpolating premultiplied
samples before converting FreeType's BGRA into straight-alpha atlas pixels.
Intrinsic RGB bypasses text/ANSI foreground tint; caller opacity still applies.
The glyph cache records that distinction alongside its atlas coordinates.

Installed Apple Color Emoji exceeds the former 64MB font discovery cap. The new
384MB per-file cap accepts it, and POSIX fallback files are mapped read-only so
the large system font is not copied onto the heap. Existing bounded face and
glyph atlas limits still apply. Linux discovery reserves common Noto emoji
paths before broader family scans can fill the fallback cap.

## Build integration

The shipping build enables PNG and zlib through `cmake/EmojiDependencies.cmake`.
FreeType 2.14.3, libpng 1.6.59 and zlib 1.3.2 are built statically from verified
archives; Studio has no package-manager decoder dependency. CLI-only builds
do not fetch these renderer dependencies. Original licenses are retained under
`THIRD_PARTY/`.

The upstream dependency pins are:

| Source archive | SHA-256 |
| --- | --- |
| [libpng 1.6.59](https://download.sourceforge.net/libpng/libpng-1.6.59.tar.xz) | `d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389` |
| [zlib 1.3.2](https://zlib.net/zlib-1.3.2.tar.gz) | `bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16` |

CTest registers `renderer_emoji` using the existing `renderer_clusters_test` executable:

```sh
SDL_VIDEODRIVER=dummy \
BOGGART_STUDIO_FONTS=tests/fixtures/fonts/NotoColorEmoji-subset.ttf \
./build/renderer_clusters_test \
  studio/data/fonts/monospace.ttf tests/fixtures/fonts/NotoSansDevanagari.ttf \
  tests/fixtures/fonts/NotoColorEmoji-subset.ttf
```

The optional fourth argument enables the color-specific suite. The ordinary
three-argument suite continues to test accents, positioned marks, Indic,
fragmented input, native/grid agreement and cache lifetime. CTest also runs
`studio_color_emoji` with the same pinned fallback.

## Verification and limits

The shipping normal and ASAN/UBSAN builds pass 15/15 focused tests (5.59s and
8.71s). FreeType, libpng and zlib are instrumented in the sanitizer build.
The color suites require chromatic pixels, one shaped glyph
for each selected emoji sequence, all four font styles, 16px/13.5px strike sizing,
VS15 monochrome, foreground independence, opacity changes, exact native/grid
pixel agreement and clean atlas teardown. An actual shipping Studio SDL/Metal run also passed native/grid replay using
installed Apple Color Emoji. `otool -L boggart-studio` lists only platform
libraries. The original no-PNG build failed the color-glyph assertion; the
pinned decoder build passes it.

This does not establish universal font coverage. SVG and COLRv1 paint graphs,
paragraph bidi, shaping between separate terminal cells, editor grapheme motion,
and generic editor-text cluster policy remain separate work. ANSI faint currently
dims foreground RGB; colored glyphs bypass that tint, so faint needs its own
opacity/paint propagation. Fonts absent from
a machine still produce the existing diagnostic glyph. Unicode properties and
native cell widths remain pinned to Unicode 16.0.0.

Sources: [FreeType BGRA representation](https://freetype.org/freetype2/docs/reference/ft2-basic_types.html#ft_pixel_mode),
[color glyph loading](https://freetype.org/freetype2/docs/reference/ft2-glyph_retrieval.html#ft_load_xxx),
[strike selection](https://freetype.org/freetype2/docs/reference/ft2-sizing_and_scaling.html#ft_select_size),
and [COLRv1 limitations](https://freetype.org/freetype2/docs/reference/ft2-layer_management.html).
