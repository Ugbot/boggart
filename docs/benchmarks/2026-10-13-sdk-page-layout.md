# Native SDK page-layout arithmetic

`src/lpage_layout.c` translates the pinned SDK's page layout, column-capacity
adjustment and initial capacity into allocation-free C99. Its explicit target
shape separates SDK word size/cache-line/page alignment from native terminal
cell storage. It is compiled in `boggart_vt`; logical page ownership has not
yet been connected to this module.

The [SDK capture](2026-10-13-sdk-page-layout.json) contains 153 arithmetic
samples from a separate instrumented SDK copy. The pristine 5,915-file source
tree is checked before and after capture. The compiled C fixture checks total
size, all represented page-region offsets, metadata size, adjusted capacities
and initial capacities against those SDK values. It also verifies that rejected
inputs preserve output objects.

Coverage includes:

- Initial widths 1–65,535, with samples around row/cache-line boundaries and
  the production 4,096-column limit; initial fallback when one row cannot fit
  in the standard page budget.
- Zero, one, small and maximum grid dimensions, including layouts above the
  SDK's usable-page byte limit. Layout calculation itself remains valid and
  allocation-free; future allocation policy must enforce the usable limit.
- Style-set power-of-two and 13/16 load-factor rounding; bitmap allocation
  rounding; grapheme-map rounding; hyperlink item count and 80% map load.
- Zero metadata and maximum field values, with 64-bit arithmetic to avoid
  wrapping intermediate products.

The captured shape is macOS arm64: 8-byte words, 128-byte cell-region alignment
and 16,384-byte allocation alignment. Other target shapes require independent
SDK capture before claiming target conformance. The module also accepts the
4-byte word shape from the source formulas, which this capture does not verify.
Column adjustments requiring more than 65,535 rows are explicitly rejected
with the output unchanged; such results cannot be represented by SDK capacity.

Reproduce:

```sh
python3 tools/ghostty/probe_page_layout.py \
  --work-root /private/tmp/bmux-layout-diagnostic \
  --archive /private/tmp/bmux-ghostty-source.tar.gz \
  --global-cache-dir /private/tmp/bmux-zig-global \
  --output /private/tmp/bmux-sdk-page-layout.json
python3 tools/ghostty/layout_fixture.py \
  --report docs/benchmarks/2026-10-13-sdk-page-layout.json \
  --output tests/fixtures/ghostty-page-layout.h --check
ctest --test-dir build -R '^page_layout$' --output-on-failure
python3 tests/ghostty_page_layout_test.py
```

Verification: strict C99 with warnings treated as errors, 153 SDK expectation
cases, ASan/UBSan `page_layout`, four fixture guards, seven existing topology
guards, six existing oracle guards, and attribution checks pass. Both CLI and
Studio build. The source identity now includes the layout module: 33 files and
16 native compilation units. Benchmark provenance checks compare against the
CMake declarations; four integration tests reject missing/duplicate sources,
stale hashes and missing/duplicate compilation units. Termbench verifies
required file membership, including layout, rather than a fixed file count.
The existing resize page-grouping compatibility gate remains open. This
checkpoint makes no performance or whole-app conformance claim.

The final full suite passes **125/126** in 77.36 seconds. The sole failure is
the existing `cached_page_head_spill` wrap mismatch in `terminal_resize`.
ASan/UBSan `page_layout` passes independently. The unchanged resize fixture
recaptures successfully with 43 cases/203 snapshots. Attribution verifies
44 SDK source modules and 29 C port files.

Remaining work follows the
[page-boundary plan](../superpowers/plans/2026-10-13-bmux-page-boundaries.md):
managed-data utilization/growth policy, logical page membership through edits
and resize, transactional ownership, cross-target layout capture, and complete
differential/fault validation.
