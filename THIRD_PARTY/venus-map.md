# Venus Swiss table

`src/lidmap.c` and `src/lidmap.h` adapt the complete Swiss-table section of
Ben Gamble's local Venus engine `src/core/venus_ds.h`, as requested by the
owner. [venus-map.json](venus-map.json) records the Venus revision and exact
source-file SHA256. The engine source tree is used as a reference; Boggart
has no engine build or runtime dependency.

Retained mechanisms: 16-byte control groups, 7-bit hash fingerprints,
tail-mirrored controls, SSE2/NEON/scalar probes, the u64 hash mixer,
erase-to-empty detection, tombstones and bounded in-place rehash.

Adaptations:

- Boggart names and separate C implementation/header.
- C11 `aligned_alloc` with rounded byte counts; Windows uses
  `_aligned_malloc`/`_aligned_free`. Three blocks are allocated at init.
- Runtime refusal for invalid/oversized hints, and cleanup of all partial
  allocations. Invalid hints leave outputs untouched; allocation failures
  leave an empty, destructible object.
- Invariant checks remain active under `NDEBUG`.
- A new key at the 7/8 load limit returns false without changing the map.
  Updating an existing key at the limit succeeds.
- Scalar comparison helpers are compiled for scalar targets and diagnostic
  tests; production SIMD builds avoid unused test-only functions.

The NEON movemask in Venus is a C translation of Bolt's
`bmm_movemask_i8`, identified in the source as Apache-2.0 and Ben-owned.
The [Apache licence](venus-map-bolt-LICENSE) is retained. Other comments
identifying algorithm origins remain in the adapted source.

The table is single-owner, fixed-capacity storage. Find, insert, erase,
clear and tombstone cleanup do not allocate. Resizing/ownership integration
must prepare replacement storage explicitly. SIMD correctness is tested on
the current arm64 target and against a forced scalar build; this checkpoint
does not establish x86/Windows execution or terminal performance.

Verification checkpoint: both products build as C11. The full suite passes
127/128 (111.11s), with only the existing terminal resize page-grouping
mismatch. Native and forced-scalar registered tests each run a 20-second
reference-model soak (about 1.42 billion and 1.10 billion checked operations
in this run). ASan/UBSan passes both 20-second soaks plus `page_layout`
(3/3, 41.07s). Tests also compare 20,000 SIMD/scalar mask cases, exercise
tail-wrap collisions, inject failure at each of the three init allocations,
check alignment and failed-insertion preservation, and verify operation-time
allocation counts remain unchanged.
