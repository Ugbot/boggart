# Shared style glyph atlas plan

> Execute the authorized BMUX-24 renderer roadmap using incremental implementation.

**Goal:** Keep alternating terminal font styles in a common SDL texture so glyph
geometry batches survive style changes without changing pixels or font metrics.

**Architecture:** A cold-path, four-slot atlas resource stores one block/phase
for the four synthetic font styles. Normal unstyled fonts retain separate
textures. Once a second style appears, existing glyph images are reproduced
from their immutable font inputs, verified against cached metrics and uploaded
before publishing shared texture/UV metadata. Later styles upload into unused
slots; larger blocks replace the page atomically. Failed allocation/upload or
oversized blocks keep the existing standalone texture path. The base owns pages;
variants only borrow them, and pending geometry flushes before old textures retire.

**Tech:** C11, Lua, existing FreeType and SDL3 geometry. No new dependency/Python.
Venus UI's bounded batches and cold resource ownership inform the design; its
GHI/Vulkan backend is not copied into Boggart. The SDL3 batched-quad epic remains
the governing architecture; hardware instancing is still a separate contract.

## Implementation and verification

- [x] Capture a source-identified native baseline and texture-batch counts.
- [x] Add bounded `fontatlas.c/.h` resource creation/upload/destruction with
  checked failures and at most a 4096×4096 shared texture.
- [x] Separate glyph baking/upload, migrate style-family textures atomically,
  preserve cached advances/ink, and free shared pages once after all glyph sets.
- [x] Test actual SDL shared texture identity, all styles, atlas growth, upload/
  allocation fallback, exact pixels, pending geometry and root/variant teardown
  in normal and sanitizer builds. Verify real-window shell/Vim and affected UI.
- [x] Measure mixed-style batches/draw cost with source manifests; record memory
  tradeoffs and platform limits, commit and link BMUX-24 without claiming the
  unimplemented hardware-instancing or application latency gates.

Evidence: `docs/benchmarks/2026-10-14-shared-style-atlas.md`. Measurements use
paired on/off controls in the same GPU binary. Software retains standalone
textures after a verified modulation regression; the test resource path can
explicitly enable sharing. Four-style corpus correction and hashes are recorded.
