# Terminal grapheme layout plan

> Continue the authorized BMUX-19/25 roadmap through measured C/Lua increments.

**Goal:** Native terminal rendering and prefix/width measurement use the same
bounded grapheme/cell policy as the pinned terminal SDK profile.

**Architecture:** First expose allocation-free UTF-8 cluster width/take primitives
using `btunicode` and the native base+64 suffix retention policy, with mode 2027
on/off explicit. Lua terminal methods use their current native mode. This is a
plain-text measurement API, not a VT cursor/escape interpreter. General Unicode-16
scalar string APIs keep their documented policy until their renderers migrate.
Then use a terminal-specific cluster rendering path with authoritative cell
advances and positioned glyphs. Complex shaping will use a pinned static HarfBuzz
C interface over the existing owned font bytes, not a second FreeType instance.

**Scope:** C11/Lua implementation and tests. The system HarfBuzz was inspected
only for API feasibility; no runtime/system dependency is introduced by the
measurement increment. Native rendering, general width/prefix migration and
shaping remain required before BMUX-19 can close.

## Native text measurement increment

- [x] Implement `btunicode_text_width` and `btunicode_text_take`, preserving
  cluster boundaries, ignored selectors/marks, retained-state cap, mode semantics,
  strict bounded UTF-8 progress and integer saturation.
- [x] Compare the results and every prefix budget with real native cell widths
  on valid plain text, byte-fragmented feed, emoji/RI/Indic/Unicode-profile vectors,
  selectors, controls and long capped clusters. Test malformed input policy.
- [x] Expose `terminal:width(text)` and `terminal:take(text, columns)` after Lua
  validation, reacquiring the native mode safely. Verify CLI/Studio parity and
  finalizer-induced closure during argument validation.
- [x] Run normal/sanitizer and source-identity/attribution gates. Document exact
  policies and commit the foundation while leaving criterion 1500 open.

## Required rendering follow-up

- [x] Separate glyph raster/cache ownership from generic SDL drawing so shaping
  can consume glyph IDs/positions without expanding the renderer's large module.
- [ ] Pin a static OpenType shaping dependency, select cluster fallback faces,
  cache positioned cluster glyphs and draw/measure authoritative cell advances.
- [ ] Verify cluster positions and prefix/width agreement across all fragmented
  inputs, both grapheme modes, font styles, mutation/resize/history and deferred
  lifetime in normal, sanitizer and real SDL windows. Migrate general consumers
  with their corresponding renderers and run meaningful performance gates.

Measurement evidence: `docs/terminal-text-layout.md`. Required rendering work
above remains unfinished; neither BMUX-19 nor the overall BMUX goal is complete.

Font boundary increment: `studio/src/fontglyph.c` now owns font bytes, faces,
fallback selection, rasterization and scalar atlases. `fontglyph.h` exposes
glyph geometry by value and a borrowed texture; each quad must be queued before
the next lookup can migrate an atlas. The renderer supplies the device and flush
hook, so migration/free still flushes pending geometry before UV/texture changes.
No shaping behavior/dependency is introduced by this refactor. Normal and
ASan/UBSan focused suites both pass 9/9; 26 saved pre/post SDL screenshots are
byte-identical, and the controlled SDL window pixel/lifetime test passes.
