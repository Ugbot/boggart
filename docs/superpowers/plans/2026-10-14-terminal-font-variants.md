# Terminal font variants implementation plan

> Execute the authorized BMUX-24/25 renderer roadmap inline using executing-plans.

**Goal:** Render terminal SGR bold/italic with separately cached glyph atlases,
shared font-file bytes, stable cell metrics and safe deferred font lifetime.

**Architecture:** A base `RenFont` owns at most three lazily created synthetic
bold/italic variants. Variants borrow the base's bytes and each own their
FreeType faces/atlases. Only the base is exposed to Lua; deferred row commands
keep the existing base-font lifetime. Measurement prepares every used variant
before enqueue, computes actual glyph ink bounds and returns failure before
queueing if variant creation fails. SDL3 geometry batching remains the draw path.

**Tech stack:** C11, Lua, existing FreeType/SDL3. No new Python or dependency.
The approved roadmap supplies authorization for this implementation choice.

## Contract and scope

- `ren_get_font_variant(font, flags)` returns a borrowed font owned by the base;
  only `REN_STYLE_BOLD|REN_STYLE_ITALIC` adds synthetic styles. Repeated requests
  reuse a variant. Failure returns NULL and leaves the base/cache usable.
- Variant faces read shared base bytes. Free variants before base faces/bytes;
  a variant cannot be independently freed or exposed as an owning Lua object.
- `ren_get_text_bounds(font, text)` includes glyph overhang and font decorations
  while `ren_get_font_width` continues to report unchanged logical advance.
- `tg_measure(..., RenRect *bounds)` prepares variants and reports allocation/
  face failure. `tg_draw` uses those prepared variants for SGR bold/italic.
- Preserve the exact saved Lua reference; tests build an explicit styled oracle
  from separately loaded FreeType option fonts instead of rewriting history.
- Real bold/italic face discovery, ligatures, procedural glyphs, zoom, profile
  alignment and hardware instancing remain the wider roadmap's requirements.

## Implementation and verification

- [x] Add a C renderer/font test using the real renderer with allocation/face
  failure hooks. Assert reuse, shared byte identity, stable metrics, distinct
  styled glyph pixels, fallback rasterization and complete variant teardown.
- [x] Implement base-owned variants, failure cleanup and ink measurement inside
  the existing font internals; adapt native row measurement/drawing and its
  failure handling. Compile normal and sanitizer builds.
- [x] Extend Studio pixel tests with explicit synthetic style fonts as oracle;
  cover all four styles, fallback/wide/combining text, last-column overhang,
  transitions to regular, unchanged reuse and finalization between queue/replay.
- [x] Run normal and sanitizer font/native/Studio gates and real SDL window
  pixels/shell/Vim. Run required regressions and controlled mixed-style draw
  measurements, keeping their source identity distinct from old results.
- [x] Record evidence and remaining requirements; commit and link BMUX-24/25.
  Keep both stories open until their full contracts are verified.

Evidence: `docs/benchmarks/2026-10-14-font-variants.md`. Glyph advance/profile
alignment and the remaining atlas/instancing contract are not completed by
this synthetic font cache increment.
