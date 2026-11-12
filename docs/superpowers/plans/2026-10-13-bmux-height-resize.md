# BMUX height-only resize: prepare row rings, transfer ownership at commit

The measured native height-only resize costs about 267–272 µs with 256 plain
lines, versus 0.17–0.29 µs for the pinned SDK. Both produce the same resolved
state digests in four rounds. The current native crop streams every retained
cell through `lpage_put`, retaining each style/link/grapheme and allocating new
page storage before retiring the originals. Changing only height needs new
row selection and cursor mapping, not a copy of those cells.

Evidence: [paired baseline](../../benchmarks/2026-10-13-native-sdk-resize.md).
This is performance work within BMUX-20, not an override of its failing
wide-head page-grouping comparison. That case remains an active gate.

## Contract and ownership

Keep both-screen transactional preparation, the exact bounded history ring,
trailing-blank removal constrained by current/saved pins, history pulling when
the cursor was at the bottom, pending-wrap behavior, damage, and all existing
public APIs. An allocation failure must preserve every field and owned value,
including physical page capacities, pool references, parser state and callback
counts. Commit may not allocate. All row/cell borrows still expire on success.

Prepare a private height-only candidate containing new visible/history pointer
rings. Retained rows borrow the source's physical storage during preparation;
source pages, free-slot bits, availability links, cells and pool holds do not
change. The candidate separately owns newly allocated blank-row storage.
Abort frees only its rings and owned pages, with no release of borrowed cells.
The source remains alive and unmodified for the complete prepare/abort/commit
interval. `src/lpage.h` already requires that the source not mutate before
commit/abort; this borrows storage under that existing single-owner contract.

At commit, transfer the source page list into the candidate, retain rows selected
by the new rings, and release only discarded live rows. Never visit free slots
as if they own cell holds; they can retain stale grapheme flags. Retire empty
pages and rebuild availability without allocation. Free old pointer rings,
publish the candidate in the existing screen object, and clear private borrow
state. Damage can be applied through the screen's all-damage flag. Successful
commit keeps the screen/pool identities stable.

The fast path applies **only when the entire public resize keeps columns
unchanged**, directly borrowing from the original published source. Width
resize can create intermediate candidate geometries that are destroyed before
commit; borrowing from them would dangle. Do not enable the fast path inside
arbitrary crop calls or from an unpublished intermediate geometry. Width
changes retain the current independent-copy implementation until separately
optimized and verified.

## Implementation steps

1. Add the private height geometry preparation/retirement contract in
   `src/lpage_internal.h` and implement storage ownership in `src/lpage.c`.
   Keep source storage completely untouched until commit. The candidate must
   describe ownership explicitly rather than relying on a page-list layout
   accident or increasing/decreasing cell pool holds for borrowed rows.
2. Select the retained absolute row range using existing crop rules in
   `src/lpage_resize.c`. Preserve stream-equivalent history pruning and padding
   counts so current/saved pin mapping remains unchanged. Allocate only new
   blank rows; preserve their capacity behavior across later cyclic crops.
3. Route only whole height-only requests from `lpage_resize_prepare` into the
   new ownership path. Commit/abort remain opaque to `bterm_resize`, so both
   screens still prepare before either commits.
4. Add lifecycle assertions in `tests/c/page_resize.c`: preparation/abort leave
   the original row/cell identities and exact pool refs unchanged; commit keeps
   retained identities; bounded eviction releases discarded owned cells; growth
   creates blank rows; later width change, reset and destruction release all
   transferred ownership exactly once. Exercise histories 0/1/17 and cached
   physical widths. Run the existing 9,000 mixed resize/property checks.
5. Extend `tests/c/resize_failure.c` to inject every height-only preparation
   allocation for primary-only and allocated alternate screens, cursor-top and
   cursor-bottom growth, shrink with/without trailing blanks, and mixed cached
   capacities. Keep full state/cell/pool/capacity/callback rollback assertions
   and zero-allocation commit checks.
6. Run every SDK vector, the independent API/finalizer suite, normal and
   ASan/UBSan ownership/fault checks, full CTest, strict C99/attribution checks,
   and CLI/Studio parity. The known page-grouping case must stay visible; do
   not accept any new snapshot difference as part of the optimization.
7. Repeat the exact seven-corpus benchmark, using the same SDK, archive/compiler
   flags, 31 samples, three warmups and four paired rounds. Preserve the baseline
   report unchanged and save a new report with actual compiled hashes. Compare
   per-round timing and allocation observations; do not claim a whole-app gain
   from C-API measurements or use timer-resolution-limited no-ops in ratios.

## Remaining correctness work

Ghostty `initialCapacity` derives page row capacity from the standard page byte
layout and requested columns. Its `grow` appends into the last page while that
capacity permits; page-local style/grapheme growth can also affect allocation.
The cached-grow slow path tests every row in that actual SDK page for a spacer
head before cloning. Native 16-row chunks and screen-owned pools have different
boundaries. A constant larger group or a global head flag cannot reproduce
that lifecycle in general. Keep `cached_page_head_spill` and broaden boundary
probes while designing a faithful solution. The height-only optimization is
independent of that unresolved page-model question and does not close BMUX-20.


## Implementation checkpoint

The unchanged-width path is implemented in `lpage.c/lpage_internal.h` and
selected only by the complete request in `lpage_resize_prepare`. Source rows
are borrowed; unused source slots are reserved by reading free bits and are
initialized only at commit. Candidate-owned pages are allocated only after
that free storage is exhausted. Commit marks kept rows, releases discarded
live rows, transfers page ownership, retires empty pages and rebuilds
availability without allocation. Abort never releases borrowed ownership.

Lifecycle tests pass for histories 0/1/17, retained addresses, pool refs,
unused-slot reuse, blank growth, later width resize, stale free-slot flags and
final release. The existing 9,000 mixed cases pass. Fault injection covers
340 allocations in 52 cases and includes whole private screen/raw page state
in addition to resolved values, refs and callbacks. Four new SDK vectors bring
the fixture to 43 cases / 203 snapshots; 42 cases / 202 snapshots match, with
only the existing page-grouping observation failing.

The original baseline remains unchanged. A controlled alternating native
before/after comparison rebuilds the before core from verified baseline Git
blobs and identical optimization flags. Height-only medians fall from
183.6–187.9 µs to 1.04–1.29 µs (145–176×) in that workload. The separate SDK
follow-up still shows native slower than the SDK for height changes. All seven
corpora and 29 states match on every round in both comparisons. See
`docs/benchmarks/2026-10-13-height-transfer-resize.md` and its raw artifacts.
No whole-app or transaction-peak memory claim is made; the failed page-grouping
criterion remains open.


Latest verification: both products build; strict C99 and attribution checks pass;
CLI/Studio fingerprints match on all 33 fields. The full registered suite is
124/125 (99.86 s), and ASan/UBSan focused checks are 23/24 (6.32 s). Both fail
only the unchanged `cached_page_head_spill` observation in `terminal_resize`.
After those runs, eight additional fault-injection combinations force padding
past unused slots into separately owned pages; the expanded 52-case / 340-failure
`resize_failure` test passes again in normal and sanitizer builds. Product code
is unchanged between the broad runs and this final test expansion.
