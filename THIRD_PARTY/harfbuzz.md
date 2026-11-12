# HarfBuzz static OpenType shaping

Boggart Studio builds the upstream HarfBuzz **14.4.0** amalgamation as a static
library and calls its C API from Boggart's C implementation.

- [Official release](https://github.com/harfbuzz/harfbuzz/releases/tag/14.4.0)
- Archive: `harfbuzz-14.4.0.tar.xz`
- Archive SHA-256: `2357ed966c6ced7bfa720b0640c0231065af01158fbea215093ffa15aed44371`
- Original license: `harfbuzz-LICENSE`
- License SHA-256: `ba8f810f2455c2f08e2d56bb49b72f37fcf68f1f4fade38977cfd7372050ad64`

The [upstream build instructions](https://github.com/harfbuzz/harfbuzz/blob/14.4.0/BUILD.md)
support the `src/harfbuzz.cc` amalgamation. FetchContent populates the verified
archive without running upstream's CMake, which would auto-enable FreeType
interop when Boggart's FreeType target exists. Platform shapers, FreeType/GLib/ICU
interop, utilities, subset/raster/vector/GPU libraries are not enabled. Optional
draw/paint/color APIs, buffer serialization/verification and environment-based
configuration are compiled out. OpenType shaping and AAT support remain.

`fontshape.c` builds the OpenType font over borrowed immutable bytes, independently
of FreeType. Every face records its byte owner, length and TTC index. Shape
objects are freed before faces/font bytes. There is one existing FreeType
rasterizer, and no `hb_ft_font_create` symbol is built. Runtime link inspection on
macOS shows only system libraries.

Input is capped at 65 scalars per native retained cell. The wrapper accepts at
most 256 output glyphs and bounded positions. HarfBuzz's internal length factor
is 4, minimum 256; its operation factor is 1024, minimum 65536. These compile-time
limits apply only to this Studio shaping library. General editor/CLI Unicode
helpers keep their existing policy while their consumers await migration.
