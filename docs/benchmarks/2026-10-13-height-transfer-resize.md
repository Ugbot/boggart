# Height-only ownership transfer — 2026-10-13

Height-only resize now prepares new row pointer rings and retains existing
cell storage through commit. In a controlled alternating before/after run,
256 plain lines resize **145–176× faster** in this C-API workload. This is
a measured terminal-core improvement, not an overall application speed claim.

| Target geometry | Before median (µs) | After median (µs) | Ratio |
|---|---:|---:|---:|
| 80x12 | 187.854 | 1.291 | 145.5× |
| 80x48 | 183.604 | 1.041 | 176.4× |
| 80x24 | 185.813 | 1.084 | 171.4× |

The [controlled native comparison](2026-10-13-height-transfer-paired.json)
contains four alternating-order rounds, 31 timed sequences and three warmups
per round for all seven original corpora. The before core was rebuilt from
31 source blobs at `78a9ba155607f857440679aa4c0f2e15984e3e4b`, each verified
against the immutable baseline report, using the same native compiler and
`-O2 -g -DNDEBUG -std=gnu99` flags. The C99 harness and input bytes are unchanged.
All 29 rendered-state digests match between before and after in every round.
Compiler flags, source/archive/binary hashes and raw timing/RSS observations
are saved. Ratios use 124 samples per step, and exclude same-size calls near
one timer tick. Other timing differences are not attributed to this change.

The separate [native / SDK follow-up](2026-10-13-height-transfer-resize.json)
repeats the original seven-corpus protocol and verifies current source/library
identity, fixture identity and matching rendered-state digests in four rounds.
It passes the seven compiled harness tests. Native height-only medians there
are 1.52/1.17/1.21 µs, versus SDK 0.208/0.125/0.167 µs. Native remains slower
in that comparison. Memory scopes remain backend-specific as described in the
[baseline](2026-10-13-native-sdk-resize.md). Neither comparison measures transient
peak memory during a transaction or 1/10/100-pane application workloads.

## Ownership behavior

Preparation borrows live source rows without retaining individual cells or
changing source storage. New blank rows first reserve unused source slots
without modifying their free bits or contents. Only overflow padding needs
candidate-owned pages. Abort frees those pages and the candidate rings.
Commit transfers source pages, marks retained rows, initializes reserved slots
and releases only discarded live rows. Free slots own no holds even if stale
grapheme flags remain; initialization clears their complete physical capacity
without releasing stale IDs. Commit retires empty pages and rebuilds availability
without allocating. Screen and pool identities remain stable.

The fast path is restricted to whole unchanged-width requests from published
sources. Width reflow still copies independently; its intermediate geometries
can die before commit and are never borrowed. Current/saved cursor mapping,
bounded history, trailing blank rules, damage and parser/policy state are
preserved under the existing source-must-not-mutate prepare/commit contract.

## Correctness evidence

- Nine thousand mixed resizes still pass exact style/link/grapheme reference and history-bound checks for limits 0/1/17.
- Height-specific lifecycle tests assert retained cell addresses and unchanged references through prepare/abort, address transfer at commit, blank padding, unused-slot reuse, later width changes, stale free-slot flags and final release.
- Fault injection now covers **340 allocations across 52 cases**, including primary/alternate, cursor top/bottom, shrink/grow and cached widths. It compares the complete private screen, raw page-byte checksums, resolved pool contents/references, terminal state and callbacks. Height commit allocates nothing.
- Four new pinned SDK vectors cover owned height changes followed by width reflow, cached capacities, wide saved cursor/pending state, and alternate-screen height changes.
- The exhaustive [43-case comparison](2026-10-13-height-transfer-comparison.json) matches **42 cases / 202 snapshots** out of 43 / 203. Only the existing `cached_page_head_spill` observation differs; it remains in the registered failing gate.

The optimization does not close BMUX-20 or redefine its oracle requirement.
Page-wide wide-head metadata still needs a faithful solution. PTY, renderer
and whole-application gates remain separate work.


Latest verification: both products build; strict C99 and attribution checks pass;
CLI/Studio fingerprints match on all 33 fields. The full registered suite is
124/125 (99.86 s), and ASan/UBSan focused checks are 23/24 (6.32 s). Both fail
only the unchanged `cached_page_head_spill` observation in `terminal_resize`.
After those runs, eight additional fault-injection combinations force padding
past unused slots into separately owned pages; the expanded 52-case / 340-failure
`resize_failure` test passes again in normal and sanitizer builds. Product code
is unchanged between the broad runs and this final test expansion.
