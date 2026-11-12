# BMUX-20: preserve SDK page boundaries

The remaining `cached_page_head_spill` failure is caused by observable page
membership. `resizeWithoutReflowGrowCols` scans every used row in one SDK
page for a spacer head before allowing cached-width growth. Its slow path
clones rows and clears their wrap metadata. Native `lp_row_page_has_head`
scans physical 16-row allocation chunks, which have different boundaries.

## Verified diagnostic checkpoint

`tools/ghostty/probe_page_topology.py` builds a diagnostic executable from a
separate, instrumented copy of the pinned SDK. It verifies the pristine
reference tree and archive before and after. An independently verified C ABI
oracle checks every frame's geometry, active screen, flattened row count/order,
wrap and head flags. The immutable resize fixture remains unchanged.

The ten default inputs cover the existing failure, cached owned history,
height changes, heads on either side of an actual SDK page boundary, and
style/grapheme capacity growth. The 59-frame report is
`docs/benchmarks/2026-10-13-sdk-page-topology.json`.

Observed constraints:

- A six-column page initially has capacity for 6,847 rows on this build.
  At 215 columns, the adjusted capacity is 221 rows, including layout slack.
- A head in the first page clears that page's wraps. Moving the head to the
  second page preserves the first page's 111 wrapped rows. Height shrink/grow
  before cropping preserves these page-local outcomes in the tested inputs.
- Style capacity grows from 128 to 1,024 items; grapheme capacity grows from
  8,192 to 65,536 bytes in the respective stress inputs. Feed replacements
  retain the 221-row capacity. Subsequent slow cached-width growth adjusts
  row capacity to 224 and 230 respectively.
- The SDK slow grow code can fill available space in the previous page
  before inserting replacements. Page membership must follow lifecycle
  operations, rather than division of row indexes by an initial capacity.

## Implementation sequence

1. Translate pinned SDK page-layout/capacity arithmetic into private C:
   row/cell sizes, metadata set/map layouts, alignment, rounded allocation
   sizes and growth. Verify against independently captured SDK layout samples.
2. Track logical SDK page ownership separately from native storage chunks.
   Preserve it through scrolling, edits, erasure, height transactions, crops
   and reflow. Track managed-data utilization where it changes capacity.
   Include split, replacement, previous-page filling and pruning; global
   style/GP IDs alone do not describe page-local state.
3. Scan logical page membership on cached grow. Preparation must preserve
   all published rows, groups, pool holds and capacities until both screen
   candidates succeed. Keep the height-transfer ownership guarantees.
4. Add full differential vectors for actual boundaries, managed-capacity
   growth and later operations that consume replacement-page slack. Cover
   primary/alternate screens and allocation-failure rollback. Keep the
   existing failing vector registered throughout implementation.
5. Run C99/product, sanitizer, fault, SDK differential and benchmark gates.
   Record metadata overhead. Close criterion 1446 only when the complete
   registered differential suite passes.

The diagnostic is complete for the listed inputs. Logical page ownership and
the remaining compatibility fix are still required.

## C99 layout checkpoint

`src/lpage_layout.c/.h` now compute page layout, column-capacity adjustment
and initial capacity with explicit SDK target shape and 64-bit offsets.
153 independent SDK arithmetic samples cover every represented region offset,
zero metadata, rounding thresholds, maximum fields and initial fallback.
The generated C fixture is dependency-free; `page_layout` is registered with
CTest. Strict C99, the C test and ASan/UBSan pass. Four offline guards verify
capture identity, generated expectations and rejection of inconsistent SDK
samples. CLI and Studio build.

Captured arithmetic conformance is established for the macOS arm64 SDK shape.
Other shapes still need independent capture. The allocation/growth density
policy and logical page lifecycle are pending; this checkpoint does not fix
`cached_page_head_spill`. Details and reproduction are in
`docs/benchmarks/2026-10-13-sdk-page-layout.md`.

Final full suite: 125/126 (77.36s), only the existing page-grouping mismatch.
ASan/UBSan `page_layout`, four fixture guards, four benchmark identity guards,
seven topology guards and six oracle guards pass. The unchanged resize
fixture checks at 43 cases/203 snapshots; attribution is 44 modules/29 files.

## Venus lookup primitive

The user permits C11 or newer and identified `~/venus` as a source of useful
C data structures. `src/lidmap.c/.h` now adapt Venus's u64→u32 Swiss table
for page-local style/GP/link reference counters. It preserves SSE2, NEON and
scalar probes, mirrored control groups and allocation-free tombstone cleanup.
The release-only overfill hazard noted in Venus's DS map is addressed with
explicit insertion refusal; existing-key updates still work at the limit.
The project now requests C11 for aligned allocation and test timing.

The primitive is compiled in the native library. Connecting it to page-local
utilization and logical page ownership remains required. Import provenance
and retained Apache attribution are in `THIRD_PARTY/venus-map.md`.

Verification: C11 release build with warnings treated as errors, both product
builds, native and scalar 20-second reference-model soaks, SIMD/scalar masks,
allocation failures and allocation-free operation checks pass. Full suite
127/128 (111.11s), only the existing resize page-grouping mismatch.
ASan/UBSan 3/3 (41.07s): both soaks and `page_layout`. Compiled native source
identity verifies 35 files/17 C11 compilation units. Page ownership integration
remains the next step.

## Logical spans connected

Native screens now own ordered SDK page spans independently of physical
16-row storage chunks. History append/drop/clear, partial row shifts, crops,
slow-growth splitting/previous-page fill and height transactions preserve
span ownership. Candidate span rings are unpublished; commit transfers them
without allocation and abort preserves the source. Cached-grow head scans
use logical spans and are computed once per page during crop.

The original page-head spill is fixed: all 43 small cases/203 snapshots pass.
Six focused normal and sanitizer resize gates pass, including 9,000 mixed
resizes and 424 injected allocation failures/52 cases. Fault images include
raw span-ring bytes as well as source screen fields and physical pages.

A new registered full-state digest gate captures 11 large cases/79 snapshots
through the independent verified SDK adapter. Eight complete cases/68 snapshots
match. Eleven mismatches are preserved: final managed-style and ASCII-grapheme
growth steps, and mixed-script grapheme feed/resize steps 1–9. The latter
already diverges during feed around U+05C8, before resizing. The same failures
reproduce under ASan/UBSan without sanitizer diagnostics.

Full suite: 127/129 (133.82s). The additional mining_jobs foreground-latency
failure at 100.499ms passes an isolated rerun; its 100ms bound stays unchanged.
Seven original benchmark corpora preserve all 29 state digests in two rounds.
Current native height medians remain below 1us in this run, with no controlled
speedup claim. Details: docs/benchmarks/2026-10-13-logical-page-resize.md.

Next: attach page-local managed reference accounting using the Venus map,
translate managed growth/projection and copy-time reservation policies, then
resolve the mixed-script feed width behavior. Capture large boundary
expectations per SDK target profile. Keep BMUX-20 failed until the entire
extended gate and rollback/performance checks pass.

## Live managed-data checkpoint, 2026-10-14

The pinned terminal Unicode profile and cell-backed style accounting are
connected. Grapheme append now reserves page-local bitmap extents before
releasing the old extent, preserving the SDK's allocation fragmentation and
growth/projection behavior. Venus Swiss tables index extents by physical cell
address. Payloads stay in the existing shared C pool; each cell owns its own
metadata extent. Style-capacity growth invalidates grapheme metadata so the
next append reconciles it. Usage includes aligned map buffers and bitmap words.

Both pinned resize corpora now pass: 46 small cases/215 snapshots and 11 large
cases/79 snapshots. Dense growth, independent copied-cluster appends, suffix
limits, erase/ID reuse, retained capacity and history lifetime have direct C
checks. Fault images cover maps and bitmap words; 15 fresh/dirty cache,
Swiss-table growth and arena-growth failures preserve deep page state.
Resize preparation defers
managed caches, preserving source ownership and allocation-free commit.

Normal CLI/Studio builds and C11 warnings-as-errors pass. Full normal CTest
passes 132/132 (126.73s); focused ASan/UBSan passes six tests (13.54s), with
no sanitizer diagnostics. Final expanded fault checks then pass separately
in both normal and sanitizer builds (0.24s/0.33s); product code is unchanged
from the full-suite run.

This is a bounded conformance checkpoint. Bulk cell copies/erases and geometry
changes reconcile caches lazily; exact fragmentation preservation across every
cached resize is not established. Pen-only styles, hyperlink/string metadata,
broader differential fuzzing and other SDK target profiles remain open. The
prior style-feed benchmark measured additional feed cost; this checkpoint makes
no performance claim. BMUX-20 remains in progress while these gaps are checked.

Implementation preference: C11 or newer and Lua; borrow useful structures from
`~/venus`, and use SDL3 platform facilities wherever they fit. Studio already
uses SDL3 for windows/input. Current new implementation and test changes are C;
new capture/validation tools use Lua. Historical Python developer tooling is
still present and has not been rewritten by this checkpoint.
