# Native terminal dirty-region replay

Rencache now skips a terminal row when its complete cached ink bounds have no
nonempty intersection with the effective dirty clip. Clip commands still replay
in order, including an empty clip and a later restored clip. Skipping happens
before tab/glyph/style work. All retained rows and deferred font frees are still
released in the unconditional frame-end pass.

This follows the native row and synthetic font increments. It keeps SDL3's
geometry batcher, font/style cache and command order. Ordinary editor commands
retain their existing behavior and payload size.

`renderer.terminal_replay_stats()` returns a snapshot of the last completed
frame: `rows_queued`, `rows_replayed`, `rows_skipped` and `dirty_rects`. Replayed
and skipped count each row command considered for each dirty region. Unchanged
frames can queue rows while replaying/skipping none because there are no dirty
regions. The snapshot is copied before Lua allocation.

## Verification

The initial C test failed because a row at y=160 was replayed for damage at
y=0..96. It now passes with:

- Separated unchanged rows skipped while the changed row replays.
- Empty clips suppressing work and later clips restoring it in order.
- Ink overhang intersecting a clip despite the nominal cell missing it.
- Two separate dirty regions producing two row replays and four skips.
- No-damage and skipped commands releasing every retained row reference.
- The existing allocation/bounds and deferred source/font lifetime checks.

`studio_terminal_render` captures the warmed partial native update before
rendering the full reference, then compares exact backbuffer bytes. This avoids
masking a stale-pixel bug with a later full redraw. Its color/style, clip,
overhang, resize/reflow/history/alt-screen and finalizer checks remain passing.

Final focused normal tests **7/7**, 2.98s; ASan/UBSan **7/7**, 4.33s, include
the Studio regression suite, C command/font tests, native pane, shutdown,
pixel parity and Vim. The final C test fixture adjustment also passes in both
builds. Real SDL3 window pixel/shell/Vim checks pass. C11 warning checks pass,
with the existing unused-parameter exemption for renderer Lua bindings.
The previous font increment's full 145-test result is separate evidence;
this increment was verified with the affected renderer/Studio gates.

## Before/after native draw measurements

macOS arm64, SDL3 3.4.14 dummy driver, normal build, 80×24 pane, font size 16.
Three source-identified native processes were captured before editing at
`e9faea80ac3d90ee5b95b81149279e21a4698225`, and three after this change.
Each process warms every case before taking 21 samples. Processes run
sequentially with no other task-owned build/test/measurement active. Frontend
and font hashes match across both sides; source manifests identify the C change.
Optional completed-frame counters are captured after the timed sample loop.

This is a before-then-after experiment, not an interleaved hardware-controlled
trial. OS/background/frequency effects can influence elapsed measurements.
The exact row counts independently demonstrate the eliminated replay work.
Feed/`sync` are outside the measured draw; these are CPU/wall pane draw costs,
not key-to-pixel latency, GPU timings or whole application throughput.

| Corpus | State | Before CPU median | After CPU median |
| --- | --- | ---: | ---: |
| Plain | Unchanged | 0.008 ms | 0.007 ms |
| RGB/256 colors | Unchanged | 0.008 ms | 0.008 ms |
| Unicode | Unchanged | 0.008 ms | 0.008 ms |
| Mixed styles (three effective styles) | Unchanged | 0.008 ms | 0.008 ms |
| Plain | One row changes | 1.000 ms | 0.444 ms |
| RGB/256 colors | One row changes | 1.215 ms | 0.478 ms |
| Unicode | One row changes | 1.283 ms | 0.509 ms |
| Mixed styles (three effective styles) | One row changes | 2.277 ms | 1.209 ms |

Every measured dirty case queues 24 rows, replays 5 and skips 19 for one dirty
rectangle. The 96-pixel damage grid spans multiple terminal rows, so a one-row
change is not a one-row replay. Unchanged history viewports queue 25 rows
(including the boundary row) and replay none. Native draw still makes zero
per-cell Lua text calls and captures zero/one rows on unchanged/dirty frames.

Raw samples, hashes and counters are in
[`2026-10-14-row-replay-raw`](2026-10-14-row-replay-raw/).
`tools/termbench/studio_draw_delta.lua` consumes
`<BMUX_DRAW_PREFIX>-{before,after}-{1,2,3}.json` and writes `BMUX_DRAW_SUMMARY`.
Earlier row/font reports are preserved.

BMUX-24 remains open for its atlas/style/instancing contract. Alternating styles
still incur texture switches, and the row hash damages the whole row width.
Merged atlas/instancing choices require separate implementation and measurement.
Unicode/profile alignment, remaining font work, platforms and whole-app budgets
are still open requirements in their respective tickets.

Correction: the mixed corpus in these records retained bold when SGR 3 set
italic, so it exercised three effective styles. The later shared-atlas experiment
clears bold explicitly and hashes its corpora; these historical samples remain
unchanged. Independent four-style correctness tests were unaffected.
