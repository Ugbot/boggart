# BMUX-19 Unicode Implementation Plan

> **For agentic workers:** Execute this plan inline, task by task, with verification before each commit. The existing BMUX C-port roadmap authorizes implementation; no additional design approval is needed.

**Goal:** Share reproducible Unicode width and grapheme properties between Boggart's terminal, termctl, and Studio.

**Architecture:** Vendor official Unicode 16.0.0 inputs with hashes and their license. Generate one immutable two-stage C lookup table, compiled once into a C99 library. Keep standard UAX #29 segmentation separate from the Ghostty-derived terminal width-effect kernel. Replace duplicate scalar width implementations first; migrate grid and rendering together afterward.

**Tech Stack:** C99, Python 3 standard library, CMake, official Unicode conformance data.

## Global constraints

- Builds work offline and need neither Python nor Zig to compile the checked-in table.
- Unicode version is explicitly 16.0.0, preserving the current scalar width policy. A future oracle must align its data version before claiming parity.
- Product code allocates no memory for property lookup, segmentation, decoding, or measurement.
- Ghostty-derived width decisions carry the pinned revision and MIT attribution; Unicode data has its own manifest and License V3.
- BMUX-19 stays in progress until wide pairs and grapheme storage are integrated into the native grid. BMUX-20 covers resize/reflow.

### Task 1: Generated properties and a streaming Unicode kernel

**Files:** `THIRD_PARTY/unicode/manifest.json`, `THIRD_PARTY/unicode/16.0.0/`, `THIRD_PARTY/unicode-LICENSE`, `tools/genwidth.py`, `src/bunicode.c`, `src/bunicode.h`, `src/bunicode_data.h`, `tests/c/unicode.c`, `CMakeLists.txt`.

**Interfaces:**

```c
uint16_t bunicode_properties(uint32_t cp);
int bunicode_width(uint32_t cp);
bool bunicode_grapheme_break(bunicode_grapheme_state *state, uint32_t cp);
bunicode_width_effect bunicode_grapheme_width_effect(uint32_t prev, uint32_t cp);
int bunicode_grapheme_width(const uint32_t *cps, size_t length, size_t *consumed);
```

- [x] Add the C conformance runner: parse every `÷`/`×` boundary in the official GraphemeBreakTest, pass each scalar sequentially to `bunicode_grapheme_break`, and fail at the first mismatched boundary with its file line.
- [x] Run the new test before adding the kernel and confirm it cannot link.
- [x] Generate width, GCB, InCB, Extended_Pictographic, Emoji_Presentation, and valid emoji variation-base properties. Preserve the existing Mn/Me/Cf (except soft hyphen), Jamo, control, EAW W/F and emoji width policy.
- [x] Implement GB3–GB13 with constant state for RI parity, pictographic Extend/ZWJ prefixes, and Indic consonant/linker prefixes. Invalid scalars force boundaries and measure one cell.
- [x] Implement valid VS15/VS16 width changes and ignore invalid selectors, restoring the terminal width measurement's break state. Standard segmentation itself never ignores selectors.
- [x] Run `python3 tools/genwidth.py --check` and the native Unicode test under normal and address/undefined sanitizer builds.
- [x] Commit the verified data/kernel increment with a BMUX-19 commit link.

### Task 2: Shared scalar consumers and safe UTF-8 compatibility

**Files:** `src/utf8width.h`, `src/termctl.c`, `src/bunicode.c`, `src/bunicode.h`, `tests/c/unicode.c`, `CMakeLists.txt`, `docs/terminal-core.md`.

**Interfaces:**

```c
const char *bunicode_utf8_next(const char *p, const char *end, uint32_t *cp);
int bunicode_str_width(const char *s, size_t length);
size_t bunicode_str_take(const char *s, size_t length, int columns, int *used);
```

- [x] Test bounded and NUL-terminated UTF-8, truncated tails, overlong encodings, surrogates, invalid leaders, and one-byte progress on errors. Test prefix width at CJK boundaries and embedded NUL in explicitly sized strings.
- [x] Make `utf8width.h` a compatibility wrapper over the shared implementation; make `tc_wcwidth` delegate to `bunicode_width`. Preserve scalar string measurement until the corresponding renderers support clusters.
- [x] Link the Unicode library into CLI, Studio, terminal backend and standalone termctl; include generated table/kernel hashes in terminal build identity.
- [x] Run focused C and Lua terminal/Studio/transcript tests, full serial CTest, compiled CLI/Studio parity, and both attribution checks.
- [x] Record test evidence and commit.

### Task 3: Native cells and renderer integration

**Files:** `src/lpage.c`, `src/lpage.h`, `src/bterm.c`, `src/bterm_internal.h`, `src/lterminal.c`, `studio/src/renderer.c`, `src/termctl.c`, `tests/c/page.c`, `tests/c/terminal.c`, `tests/terminal.lua`, `tests/studio.lua`.

- [ ] Add screen-owned, bounded grapheme storage with explicit references through put, clear, copy, scroll, history eviction, and destruction; retain the 16-byte cell layout.
- [x] Test width-two continuation repair on overwrite, insert/delete/erase and scroll boundaries before switching the printer to shared widths.
- [ ] Track grapheme state across feed chunks, append marks/ZWJ sequences, apply VS width changes, and break the association on cursor operations or control dispatch. Test all byte split points against an unsplit snapshot.
- [ ] Expose complete cluster text in copied snapshots and draw it as a unit. Update width/prefix consumers and their rendering in the same increment so layout and painting agree.
- [ ] Add long-running cluster lifetime/eviction tests and native/Lua parity vectors before closing BMUX-19. Use the existing termbench Unicode workload to detect regressions; do not claim Ghostty speed parity.

## Review checkpoints

Task 1 and Task 2 are independently usable foundations. Task 3 is required for story completion and must be refined against the existing page ownership interfaces before cell changes. No tracker status may imply integrated grapheme rendering before these checks pass.

Task 1 verification: normal Unicode CTest passed (0.41 s), ASan/UBSan Unicode CTest passed (0.52 s), four Python generator tests passed, attribution passed for 40 modules / 24 ported files, and strict C99 warning checks passed. Standard conformance: 1,093 cases / 2,774 boundaries. Exhaustive migration comparison: zero scalar-width changes.

Task 2 verification: both builds succeeded; normal focused tests 18/18 (10.87 s), ASan/UBSan focused tests 18/18 (13.14 s), full serial suite 116/116 (110.93 s), CLI/Studio parity 31 identical fields, regeneration and four generator tests passed, pinned Ghostty attribution passed for 40 modules / 24 ported files, and strict C99/diff checks passed. Source identity now contains 27 compiled files. Native cell widths and cluster ownership are still pending; BMUX-19 remains in progress.

Task 3 wide-pair storage checkpoint: the initially failing continuation test now passes; normal and ASan/UBSan page/wide/dispatch/link checks passed 4/4. `tests/c/wide_cells.c` covers overwrite of either half, adjacent-pair collisions, erase expansion, insertion/deletion cuts, clipping, no-op ranges, history transfer, WIDE_HEAD placement/removal, rejected geometry/style IDs, and 30,000 mixed operations with exact style/link refs. Cell size remains 16 bytes. Printer/cluster integration follows; BMUX-19 stays in progress.
