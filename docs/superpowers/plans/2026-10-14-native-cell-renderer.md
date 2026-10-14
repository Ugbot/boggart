# Native cell renderer implementation plan

> Execute the approved Phase 2/BMUX-24 roadmap incrementally using executing-plans.

**Goal:** Render native terminal rows through SDL's existing glyph batcher with
no Lua draw call or Lua snapshot table per cell, preserving deferred lifetime
and per-row damage. C11/Lua; SDL3 stays the graphics/platform layer.

**Architecture:** Immutable C rows hold resolved style values, widths and full
UTF-8 clusters. A terminal render context caches screen/visible-history rows.
Rencache commands retain rows until frame end and hash content/geometry/theme;
closing or mutating the terminal cannot invalidate deferred rendering. The
renderer feeds the existing SDL_RenderGeometry atlas batches. Font variants,
shaping and procedural glyphs remain BMUX-25; application performance targets
must be measured separately.

## Task 1: Measurement and immutable row primitive

- [x] Capture a source-identified current Studio draw baseline with C grid
  input: plain/styled/Unicode corpora, warmed font atlas, repeated frames,
  CPU/wall samples and Lua renderer-call counts. Do not infer pixel latency.
- [x] Add `studio/src/termgrid.c/.h` immutable packed rows, checked capture,
  deterministic content hashes and retained lifetime. Test complete clusters,
  styles, wide tails, mutation/close and native allocation failures.

## Task 2: Native rencache command and render context

- [x] Add a row command retaining snapshots through frame replay/cleanup;
  preserve font lifetime, clip ordering and content-based damage. Check bounded
  command-buffer growth and release on frames with no damage.
- [x] Add `renderer.new_terminal` context with rooted font/terminal owners,
  native row invalidation and cached viewport snapshots. Read the core only
  after Lua validation/allocation; deferred commands never borrow live cells.
- [x] Preserve fixed cell positions, background-before-glyph ordering,
  palette/RGB/inverse/faint/invisible/decorations and cursor rendering.
- [x] Replace production Lua cell loops with one context draw per pane. Keep
  existing row API for inspection and historical artifacts unchanged.

## Task 3: Verification and measurement

- [x] Compare native/reference rendered images for unchanged behavior, including
  clip/movement/resize/scroll/history/alt-screen and Unicode fixtures.
- [x] Test closed/mutated sources and finalizers between enqueue and replay,
  unchanged frames, damage transitions, bounds/OOM and font/row release.
- [x] Run normal/ASan/UBSan native and Studio gates, real-window shell/Vim,
  appropriate full regressions and controlled before/after draw measurements.
- [x] Record remaining style/font, shaping, platform and application-budget
  limits; close BMUX-24 only when its whole declared interface is verified.

Current rencache copies commands and frees fonts after replay. Its text path
already batches glyph quads in renderer.c; the per-cell Lua/C boundary and
resolved-table construction are the immediate targets. A content hash must
participate in row damage: allocator pointer reuse cannot hide changed text.

Completed checkpoint evidence: `docs/benchmarks/2026-10-14-native-row-renderer.md`.
BMUX-24 remains in progress for its remaining atlas/style and instancing
contract. This plan's row command path reuses SDL geometry batching and does
not claim hardware instancing.
