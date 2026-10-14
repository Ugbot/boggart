# Shared SDL3 font-style atlases

On GPU renderers, glyph blocks for regular, bold, italic and bold/italic can now
share one texture. Style changes retain the existing glyph geometry batch instead
of flushing it to bind another texture. Software renderers keep separate textures.
Native row caching, dirty clips and deferred base-font ownership remain unchanged.

`fontatlas.c/.h` owns four fixed style slots, with a shared page bounded at
4096×4096. Unstyled fonts retain their existing standalone textures. Sharing starts
when a second style of a Unicode block/phase appears. Cold migration reproduces
existing glyph images from immutable font inputs and checks cached metrics before
publishing texture/UV changes. Later styles use unused slots; a larger block replaces
the page only after all uploads succeed. A pending old-texture batch flushes before
retirement. The base font owns shared pages and frees them once, after variants.

Allocation, raster reproduction or upload failure falls back to the standalone
texture path without replacing existing sets. Oversized blocks also fall back.
Glyph baking now unwinds partial allocations on failure; required initial glyph
baking retains the existing fatal-OOM policy. Only the optional sharing work can
fail without losing the glyph. Shared pages reserve unused style space, so sparse
style use can consume more capacity; the four-style fixture below uses the same
total logical RGBA texture capacity on both paths. These are capacity counters,
not allocator RSS or driver memory measurements.

## Backend choice and Venus reference

The existing SDL path submits textured triangles with per-vertex color through
[`SDL_RenderGeometry`](https://wiki.libsdl.org/SDL3/SDL_RenderGeometry).
Hardware instancing uses a different pipeline interface such as
[`SDL_DrawGPUPrimitives`](https://wiki.libsdl.org/SDL3/SDL_DrawGPUPrimitives).
This change does not claim hardware instancing.

Read-only inspection of Venus's `src/ui/clay_vk_renderer.c` found instanced solid
quads but six-vertex batched glyphs. Its bounded buffers and cold resource ownership
inform this design. No Venus file or GHI/Vulkan dependency was copied or changed.
The inspected Venus revision was `4aaa0f9d2458d09d2f857dc94381a481e150337b`.
That distinction also matches BMUX-3's SDL3 batched-quad architecture and the
conditional native-backend spike in BMUX-29.

The pinned SDL software path (`src/render/SDL_render.c`,
`SDL_SW_RenderGeometryRaw`) turns uniform glyph quads into texture copies and
changes texture color modulation. Alternating foreground tints on one shared
texture caused a roughly 44 ms mixed-style CPU probe. The GPU uses vertex color
directly. Sharing therefore defaults off for the `software` backend and on for
GPU backends. The software regression was removed before integration; final
default-policy measurements below verify its separate-texture behavior.

The `_test_style_atlas_sharing` control is registered only when
`BOGGART_STUDIO_SCRIPT` is set. It affects future atlas loads and lets experiments
compare on/off in one binary. Completed-frame diagnostics report glyph quads,
batches, texture switches, backend/policy and shared/standalone logical capacity.

## Verification

Full normal CTest: **146/146**, 133.38s. Focused ASan/UBSan: **8/8**, 5.49s.
Final extra allocation and existing-page upload failure cases pass separately
under both builds. Real SDL3 GPU window pixels, native shell final output and
Vim's exact saved text pass. C11 warning checks and diff checks pass.

`renderer_atlas` exercises real SDL textures and FreeType: shared texture identity,
all four style slots, one batch for 80 equal-tint glyphs, exact standalone-oracle
pixels, queued geometry before migration, growth, failed page/reproduction
allocation, failed initial/existing-page upload, subsequent recovery and complete
texture-capacity release. It explicitly enables sharing on the test software
renderer to test resource behavior; this is separate from default software policy.
`studio_terminal_render` verifies the default GPU path against independent styled
fonts, including partial clips, history/reflow and finalization before replay.

## Controlled measurements

macOS arm64, SDL3 3.4.14, 80×24 pane, explicit font size 16. Three independently
warmed processes per path, 21 samples per case, alternating on/off process order.
Every process completes before the next starts; task-owned tests/builds are idle.
Both sides use the same final binary and frontend. Font, renderer and corpus hashes
are recorded; the mixed corpus explicitly clears bold before setting italic.

| Backend/case | Separate texture CPU | Shared/default CPU | Separate wall | Shared/default wall |
| --- | ---: | ---: | ---: | ---: |
| Metal, mixed styles, one row dirty | 0.535 ms | 0.412 ms | 8.570 ms | 8.434 ms |
| Software, mixed styles, one row dirty | 1.070 ms | 1.067 ms | 1.069 ms | 1.071 ms |

The Metal dirty frame queues 24 rows, replays 5, emits 400 glyph quads and changes
from **400 batches/399 texture switches** to **2 batches/0 switches**. Across all
three runs the logical texture capacity is 4,456,448 bytes on both paths; after
sharing it comprises 1,048,576 shared bytes plus 3,407,872 standalone bytes.
Unchanged native frames replay no glyphs and have 0.006–0.008 ms CPU medians.
Other corpus timings fluctuate; the demonstrated benefit is the mixed-style
batch reduction and its observed CPU improvement, not universal throughput.

Wall samples include presentation and remain near 8.4–8.6 ms on this GPU window.
These measurements do not establish key-to-pixel latency, the 120 fps flood gate,
GPU execution time or whole-application budgets. Raw manifests, counts, capacity
and timing samples are preserved in
[`2026-10-14-style-atlas-raw`](2026-10-14-style-atlas-raw/).

The earlier font/replay mixed corpora accidentally retained bold when applying
italic. Those records exercised three effective styles; their document labels are
corrected while raw data remains unchanged. Independent four-style correctness
tests were valid. This experiment uses four effective styles and corpus hashes.

BMUX-24 remains in progress pending its instancing/backend contract and wider
performance evidence. Unicode/profile alignment, remaining font/shaping work,
platform execution and whole-app gates remain open in their respective tickets.
