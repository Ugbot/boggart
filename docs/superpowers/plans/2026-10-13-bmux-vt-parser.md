# BMUX-14: C VT parser

**Goal:** Replace the byte-level parser mechanism with a reusable, allocation-free
C99 state machine while keeping grid/session dispatch outside this module.

**Architecture:** `src/lvt.h` defines one terminal's fixed parser state and
borrowed events. `src/lvt.c` implements ordered exit/transition/entry actions
and streaming UTF-8 decoding. `src/vt_table.h` is an immutable generated port
of the pinned Ghostty transition table. `tools/gen_vt_table.py` validates the
upstream hashes before generating it; regeneration is development-only.

**Constraints:** Preserve the CLI `term` module. No Zig in product builds; no
per-byte allocation; no mutable process-global parser state. Callers consume
borrowed event buffers immediately and must not re-enter the same parser.
OSC is bounded raw payload here; typed command handling is BMUX-17. Screen/grid
semantics are BMUX-15/16, and PTY integration is BMUX-21.

- [x] Add C tests for all-state cancellation/restart, CSI parameters and colon
  separators, saturation/overflow, ordered DCS/APC events, UTF-8 split boundaries,
  malformed input recovery, OSC cancellation/overflow and independent instances.
  First compile must fail because `lvt.h`/`lvt.c` are absent.
- [x] Generate the full 14×256 transition table from the pinned Zig source;
  verify source hashes and reject unknown generator syntax.
- [x] Implement `lvt_init`, `lvt_next` (raw byte mechanism), `lvt_feed` (UTF-8
  stream), and `lvt_transition` (immutable table inspection). Use bounded
  intermediate/parameter/OSC storage, saturation and explicit overflow flags.
- [x] Register a `boggart_vt` C library and standalone `vt_parser` CTest target,
  including the existing sanitizer helper; record derivatives in the ledger.
- [x] Run normal and address/undefined/thread sanitizer tests, verify that the
  parser object references no allocator, check regeneration is byte-identical,
  and run the full suite. Commit with BMUX-14 and record verified tracker evidence.
