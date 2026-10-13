# Logical page ownership checkpoint

Native screens now store ordered SDK page spans separately from physical
16-row allocation chunks. Spans use the verified capacity arithmetic, append
on history growth, preserve positions on partial row shifts, retire with
history, and are copied into unpublished resize candidates. Height-only
commit retains cell storage and transfers candidate-owned span metadata.
Abort leaves published spans and storage unchanged.

Cached growth scans each logical page for wide heads. Crop computes that
decision once per page. Slow growth adjusts capacity, splits replacements
and fills previous-page slack. Byte accounting includes span storage;
physical allocation statistics retain their original meaning.

The original `cached_page_head_spill` failure is fixed: **43 cases / 203
snapshots** pass. Six focused resize tests pass in normal and ASan/UBSan
builds. C tests cover real boundaries, partial shifts, history append/clear,
cell addresses, refs and 9,000 mixed resizes. Fault injection now also checks
raw span-ring bytes: **424 allocation failures / 52 cases** preserve both
screens and callbacks. Height commit remains allocation-free.

## Extended gate

`terminal_resize_large` checks 11 cases / 79 snapshots. SDK expectations are
SHA256 digests of an explicit little-endian protocol containing every field
in the reference adapter snapshot: geometry, cursor/pending wrap, active
screen, history/screen rows, wrap flags, codepoints, widths, wide heads,
protection, styles and URI bytes. Internal state, OSC8 IDs and fields outside
that adapter contract are not covered. Every snapshot is checked, and every
mismatch is reported.
Page-boundary expectations depend on the SDK target's allocation layout.
The fixture records its host profile, and the test requires a matching profile
or an independently captured fixture supplied via `BMUX_RESIZE_FIXTURE`.
The current capture is macOS arm64; target-specific CI captures remain required.

Eight complete cases and 68/79 snapshots match. Eleven mismatches remain:

- Style growth: final step 9 after replacement-page slack is consumed.
- Printable-base grapheme growth: final step 9 after the same sequence.
- Mixed-script graphemes: steps 1–9. The first mismatch occurs during feed,
  before resize: around U+05C8 the SDK continues a cluster while native starts
  another cell. Final cursor columns differ: SDK 10, native 5.

Page-local managed utilization/growth is still missing from span capacities.
The Venus map is available for the counters. The mixed-script case remains
captured; a new ASCII-base case independently isolates managed page growth.
BMUX-20 and criterion 1446 remain open/failed.

Full suite: 127/129 in 133.82s. Besides the large gate, `mining_jobs` exceeded
its unchanged 100ms foreground bound at 100.499ms. Its isolated rerun passes
(1/1, 1.31s); no bound was relaxed. Focused small resize gates pass 6/6 in
both builds. The large sanitizer result is recorded in the plan checkpoint.
The large ASan/UBSan run reproduces the same 11 compatibility mismatches
(17.48s), with no sanitizer diagnostic.

## Current measurement

The [source-identified report](2026-10-13-logical-page-resize.json) measures
seven original corpora with two alternating-order rounds, 11 samples and
three warmups per round. All 29 rendered-state digests match in every round;
compiled harness validation passes. Height-only medians are native
0.958/0.958/0.792 us versus SDK 0.167/0.084/0.125 us. This is a current
measurement with no controlled speedup or whole-app claim. Memory scopes
differ as recorded in the report.

```sh
python3 tools/ghostty/resize_digest.py \
  --binary /private/tmp/bmux-verified-oracle/resize-oracle \
  --output tests/fixtures/ghostty-resize-large.json --check
python3 tests/ghostty_resize_digest_test.py
ctest --test-dir build -R 'terminal_resize' --output-on-failure
```
