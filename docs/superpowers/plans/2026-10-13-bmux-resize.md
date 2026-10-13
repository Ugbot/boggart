# BMUX Resize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Continue the already-authorized inline execution.

**Goal:** Resize both native terminal screens transactionally, with primary-screen reflow matching the pinned Ghostty reference and bounded ownership preserved.

**Architecture:** Prepare candidate page geometries while retaining the source screens' style/link/grapheme pools. Map current/saved cursors while cropping or reflowing history and visible rows; publish both candidates only after every allocation succeeds. Validate resolved values against immutable SDK snapshots, and exercise allocation failure separately.

**Tech Stack:** C99, existing page/style/link/grapheme pools, Lua 5.4 bindings, CTest, ASan/UBSan, test-only libghostty-vt built with Zig 0.16.0, Python reference tooling.

## Global Constraints

- Product code is C99; no Zig product dependency.
- Geometry remains 1..4096 columns and rows.
- Cells remain 16 bytes; base cells alone own grapheme IDs.
- Ghostty pin: `05dcf887ef51ea27821f20979493306ec3a19149`; preserve MIT notices and update the existing attribution ledger for translated destinations.
- Source/cell borrows expire on mutation; resize invokes no callbacks or Lua allocations inside the native transaction.
- Preserve Boggart's exact history-row limit; do not equate it with Ghostty's page-granular pruning.
- BMUX-20 criterion 1446 requires native parity, not successful reference capture.

## File responsibilities

- `tools/ghostty/oracle-pin.json`: official archive and compiler pin.
- `tools/ghostty/build_oracle.py`: verified optional SDK build and provenance.
- `tools/ghostty/resize_oracle.c`: public C API adapter, resolved-value snapshots.
- `tools/ghostty/resize_cases.py`, `capture_resize.py`: curated input operations and immutable capture/check.
- `tests/ghostty_oracle_test.py`, `ghostty_oracle_cli_test.py`: offline guards and compiled adapter boundaries.
- `tests/fixtures/ghostty-resize.json`: all 119 authoritative observations.
- `src/lpage.c/h`, `src/lpage_internal.h`: stable screen/pool identities and candidate geometry ownership.
- `src/lpage_resize.c`: streaming reflow/crop and cursor mapping, isolated from allocation internals.
- `src/bterm.c/h`: two-screen transaction, terminal side effects.
- `src/lterminal.c`: Lua argument validation and synchronous `resize` method.
- `tests/c/page_resize.c`, `resize_failure.c`: storage/lifecycle, exact pool contents/refs, and allocation failures.
- `tests/terminal_resize.lua`: fixture parity through the real Lua binding.
- `CMakeLists.txt`: native test targets and source fingerprint maintenance.
- `docs/terminal-resize.md`, `terminal-core.md`, `ghostty-port.md`: current API, policy adaptations, evidence.

## Task 1: Reproducible reference oracle

**Interfaces:** `resize-oracle COLS ROWS [feed HEX | resize COLS ROWS | snapshot]...`; `build_oracle.py --work-root PATH`; `capture_resize.py --binary PATH [--check]`.

- [x] Pin the official source archive by SHA-256, compare every extracted source file, validate the port ledger, and require Zig 0.16.0.
- [x] Build static/shared VT libraries with SIMD disabled, validate the shared-library ABI schema, and compile the strict C99 adapter.
- [x] Record local executable/library/adapter hashes and reject stale provenance before capture.
- [x] Capture 29 cases / 119 snapshots, including Unicode ownership, wide boundaries, history, both screens, parser fragments, and saved cursor.
- [x] Run offline fixture/provenance guards and actual adapter rejection tests.

```sh
python3 tests/ghostty_oracle_test.py
cmake --build build --target ghostty-oracle
```

Expected: six offline tests pass; the optional target validates 176 native ABI types, passes two adapter tests, and prints `Ghostty resize fixtures: 29 cases, 119 snapshots` on the verified macOS host. Linux ABI selection is covered offline; a native Linux oracle run is still required before claiming that platform's execution.

## Task 2: Owned page resize candidates

**Files:** Modify `src/lpage.c/h`; create `src/lpage_internal.h`, `src/lpage_resize.c`, and `tests/c/page_resize.c`; modify native and sanitizer test targets in `CMakeLists.txt`. The existing fingerprint list covers the new resize implementation and private header (31 compiled files).

**Interfaces:** Add these declarations to `src/lpage.h`:

```c
typedef struct { size_t x, y; bool pending_wrap; } lpage_position;
typedef struct {
  size_t columns, rows;
  bool reflow, pull_scrollback;
  lpage_position cursor, saved;
  bool saved_valid;
} lpage_resize_options;
typedef struct lpage_resize lpage_resize;
lpage_resize *lpage_resize_prepare(lpage_screen *screen,
                                  lpage_resize_options options);
lpage_position lpage_resize_cursor(const lpage_resize *resize);
lpage_position lpage_resize_saved(const lpage_resize *resize);
void lpage_resize_commit(lpage_resize *resize);
void lpage_resize_abort(lpage_resize *resize);
```

Prepare returns NULL without changing the source. Commit consumes the candidate,
changes geometry while preserving screen/pool identity, and cannot allocate.
Abort consumes the candidate and releases all retained cells. No source mutation
is allowed between prepare and commit/abort.

- [x] Begin with an ownership test that retains a styled linked grapheme in history and visible rows, prepares a crop, verifies source values and expected temporary candidate reference holds, aborts, and checks exact original refcounts.
- [x] Add geometry-only destroy/commit helpers. Candidate pages share the existing pools and retain each copied base/tail cell independently. Abort releases candidate cell refs and geometry; it must not destroy the shared pools. Commit releases old geometry refs before swapping candidate geometry.
- [x] Implement non-reflow cropping and height policy. Repair each cut wide pair, trim trailing blank rows before shrinking, push remaining top rows to bounded history, and pull history on growth only when `pull_scrollback` and the cursor-at-bottom rule permit it.
- [x] Implement column reflow from oldest history row through visible rows. Consume complete base/tail pairs and scalar sequences; skip old wide heads. Preserve wrapped-row width, trim hard-row right blanks except for background content and required cursor pins. Emit a new wide head at the final column when needed; replace wide glyphs with one narrow blank at width one.
- [x] Track emitted row ordinals for current and saved cursors, account for bounded-history eviction, preserve the required rows below the current cursor, and reset saved positions outside the resulting visible region.
- [x] Apply the pinned resize ordering: growing columns before height change; shrinking columns after height change. Same columns use only the height path.
- [x] Inject failure at each allocation in a test-only translation unit using malloc/calloc wrappers. Assert every failed prepare leaves source geometry, cell values, refs, wrap flags, and damage unchanged. Assert commit performs zero allocations.

Storage test commands after adding the CMake test:

```sh
cmake --build build --target page_resize_test
env -u NO_COLOR ctest --test-dir build -R '^page_resize$' --output-on-failure
```

Expected: exact cursor/content/reference assertions pass for reflow, crop, history limits 0/1/17, repeated grow/shrink, and each failed allocation. Repeat the same target in the sanitizer build.

## Task 3: Terminal and Lua transaction

**Files:** Modify `src/bterm.c/h`, `src/lterminal.c`; create `tests/c/resize_failure.c`, `tests/terminal_resize.lua`; register tests in `CMakeLists.txt`.

**Interface:** `bool bterm_resize(bterm *terminal, size_t columns, size_t rows);`; Lua `t:resize(columns, rows)` returns no values on success and raises a recoverable resize error on failure.

Register the C failure test as `resize_failure` and the Lua test as
`terminal_resize`, so their CTest names remain distinct.

The public API rejects dimensions outside 1..4096. Same geometry returns true
without side effects. It prepares the primary screen with reflow matching
`BT_AUTOWRAP` and history pulling enabled, and any allocated alternate screen
with crop and no history pulling. Both must succeed before either commits.

- [x] Add tests that compare both allocated screens, parser fragments, reply bytes, pen/link holds, saved/current cursors, tabs, margins, modes, damage, and mouse motion before/after an injected second-screen allocation failure.
- [x] Prepare both screen candidates, abort every candidate if either fails, then commit both without allocation. Copy mapped cursor positions back into `bt_buffer`; preserve saved pens and validity.
- [x] Publish dimensions; reset top/bottom margins; reset default eight-column tabs only on width change; clear cached mouse motion; damage both screens. Do not reset parser, events/replies, modes, `last_printed`, focus/clipboard policies, or an existing feed-failure flag.
- [x] For pending wrap whose mapped cursor leaves the last column, clear pending wrap and advance one column. Verify the `pending_wrap_shrink`, `pending_wrap_grow`, `cursor_on_wide_tail`, and `saved_cursor` vectors before proceeding.
- [x] Bind the Lua method with integer/range validation before entering C. Perform no Lua allocation while borrowing native state. Check closed-terminal errors and successful resize of a terminal with incomplete UTF-8 and CSI fragments.

```sh
cmake --build build --target resize_failure_test boggart boggart-studio
env -u NO_COLOR ctest --test-dir build -R '^(page_resize|resize_failure|terminal_resize)$' --output-on-failure
```

Expected: both-screen state is unchanged for every failed allocation; subsequent feed works without reset when it worked before the failure.

## Task 4: Differential acceptance and integration evidence

**Files:** `tests/terminal_resize.lua`, `docs/terminal-resize.md`, `docs/terminal-core.md`, `docs/ghostty-port.md`, `THIRD_PARTY/ghostty-port.json` if destination attribution changes.

Resolve native `snapshot(true)` values into the fixture schema. Decode each
cell's `text` into scalar sequences, map `flags & 4` to wide head and `flags & 2`
to protection, copy four style values, and encode link URI strings as bytes.
Convert one-based Lua cursor coordinates to zero-based. Preserve every snapshot,
including observations before resize: a pre-existing feed discrepancy must be
reported and fixed rather than masked in the comparison.

- [x] Run every fixture operation through `terminal.new`, `feed`, and `resize`, comparing complete resolved snapshots after each operation. Fail with case/operation/row/column and expected/actual values.
- [x] Add native bounded-eviction tests separate from the fixture: clusters/styles/links survive while retained and release when evicted; repeated resize/reset/destroy leaves no leaked IDs or dangling tails.
- [x] Run focused native/Lua tests and the same set under ASan/UBSan, then the full serial CTest suite. Run CLI/Studio native fingerprints to verify the same API, ownership, and snapshots in both binaries.
- [x] Run strict C99 warning checks and attribution verification; document the actual public contract, ownership and failure-policy adaptations, and verification evidence.
- [ ] Measure native resize latency and memory under the same screen/history and feed corpora.
- [ ] Fix the observed cached-width nowrap regrow mismatch in `tests/terminal_resize_cached.lua`, add it to `tools/ghostty/resize_cases.py`, and recapture through the verified SDK. The failing input is 6x3, feed `abcdefghij` plus `CSI ?7l`, shrink to 4x3, regrow to 6x3; Ghostty retains row 0 wrapped while Boggart clears it. Check cyclic crop/reflow transitions beyond the initial vectors before acceptance.
- [ ] Commit and link evidence to BMUX-20; record criterion 1446 only after all curated native comparisons and lifecycle checks pass. Keep broader renderer, PTY, differential fuzzing, and application gates in their existing tickets.

```sh
python3 tools/check_ghostty_port.py --upstream /path/to/pinned/source
env -u NO_COLOR ctest --test-dir build --output-on-failure -j1
```

Expected: zero snapshot differences, zero sanitizer failures, all existing tests
pass, and CLI/Studio native fingerprints agree. Criterion 1446 remains pending
until this native evidence exists.

## Task 1 verification record

Final optional CMake target: exit 0, 176 ABI types, two compiled-adapter tests,
29 cases / 119 unchanged snapshots. Offline guards: 6/6; Unicode generator
guards: 4/4. Both products build; native terminal focus: 6/6 in 2.21 s;
CLI/Studio: 32 identical fields. Workflow YAML parses and includes the offline
oracle guard; Ninja `all` excludes `ghostty-oracle`. Strict C99 warnings,
attribution (40 modules / 26 attributed files), Python compilation, and diff
checks pass. At that initial checkpoint, Tasks 2–4 remained unimplemented; neither native resize acceptance
nor the remaining CI performance-budget gate is marked complete.


## Native checkpoint verification record

Tasks 2/3 are implemented, with crop/reflow isolated in `lpage_resize.c` and
geometry ownership behind `lpage_internal.h`. Main vectors: 30 cases / 123
snapshots; palette/RGB adapter regression fixed and verified. Registered suite:
123/123 (130.45 s); sanitizer focus: 17/17 (9.14 s); CLI/Studio: 33 identical
fields. Native source identity: 31 files; attribution: 40 modules / 27
attributed destinations. Nine thousand mixed page operations preserve exact
refs and bounded history; 72 injected allocation failures preserve both
screens and terminal state. Finalizer-triggered geometry changes are checked
while Lua images allocate.

Acceptance is still incomplete: `tests/terminal_resize_cached.lua` is a
confirmed failing regrow regression excluded from the passing registered
suite. Paired snapshots/provenance are saved in
`docs/benchmarks/2026-10-13-resize-cached-width.json`. Fix it, expand cyclic
coverage, and record resize measurements before criterion 1446 passes.
