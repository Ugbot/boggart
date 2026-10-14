# Terminal row replay implementation plan

> Execute the authorized BMUX-24 renderer roadmap using incremental implementation.

**Goal:** Avoid terminal glyph/style work for rows outside each effective dirty
clip, preserving pixels, clip ordering and unconditional deferred cleanup.

**Architecture:** Track the effective clip independently during each dirty-region
replay. A row command's complete cached ink bounds must have a nonempty
intersection before invoking `tg_draw`. Clips and other commands keep their
existing ordering. Row/font release remains in the unconditional cleanup pass.
Frame diagnostics record queued/replayed/skipped rows and dirty rectangle count.

**Tech:** C11 and Lua, existing SDL3 geometry batches, no new dependencies.

## Implementation and evidence

- [x] Capture three source-identified native baseline processes before editing.
- [x] Add a failing C replay-count test for separated rows, empty clips, clip
  restoration, glyph overhang intersection and reference release after skips.
- [x] Implement clip-aware row replay and completed-frame counters; expose a
  small diagnostic snapshot to the existing renderer Lua API.
- [x] Test normal/ASan C/Studio paths and exact reference pixels, including clips,
  movement, removal, partial dirty updates, font finalizers, shell and Vim.
- [x] Compare three warmed processes before/after with identical frontend/font
  and eight corpus/state cases. Record CPU/wall samples and actual replay counts.
- [x] Document limits, commit and link BMUX-24. Its atlas/instancing and the
  wider font/Unicode/application-budget requirements remain separate open work.

Evidence: `docs/benchmarks/2026-10-14-row-replay.md`.
