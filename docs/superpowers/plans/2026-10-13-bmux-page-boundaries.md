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

1. Translate pinned SDK page-layout/capacity arithmetic into private C99:
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
