# Terminal resize and reference oracle

The native `bterm_resize` and Lua `t:resize(columns, rows)` APIs now prepare
and commit both screens transactionally. The current fixture has 39 cases /
182 snapshots. A full comparison matches 181 snapshots; the wide-head
page-grouping case fails. BMUX-20 acceptance remains open as described below.

## Reproduce the reference

The optional `ghostty-oracle` target builds the public libghostty-vt C SDK at
`05dcf887ef51ea27821f20979493306ec3a19149`. Product targets do not depend on it.
It needs Zig **0.16.0**, Python 3 with `jsonschema`, a C compiler, and network
access on a cold cache. The builder supports native macOS and Linux; the
recorded validation is on arm64 macOS. Linux execution remains unverified.

```sh
cmake -S . -B build \
  -DBOGGART_GHOSTTY_ORACLE_WORK_ROOT=/private/tmp/boggart-resize-oracle
cmake --build build --target ghostty-oracle
```

The work root contains the source archive, verified source tree, Zig caches,
installed libraries, `resize-oracle`, and `oracle.json`. The builder checks the
official archive's SHA-256, compares every archived file with the extracted
source, checks the port ledger, builds with SIMD disabled, validates the native
shared library against Ghostty's ABI schema, and compiles the adapter as strict
C99. It checks source bytes again after the build. A modified source tree or
different Zig version cannot silently become the pinned reference.

`oracle.json` records the revision, archive hash, verified source-file count,
Zig and C compiler identities, and hashes of the static library, adapter, and
executable. The capture command verifies the executable and adapter hashes
against that manifest before running any case.

```sh
python3 tests/ghostty_oracle_cli_test.py --binary /path/to/resize-oracle
python3 tools/ghostty/capture_resize.py --binary /path/to/resize-oracle --check
```

The CMake target runs both commands. It checks the existing fixture rather than
overwriting it. Deliberate recapture requires omitting `--check`; review the
resulting fixture diff with changes to the inputs, adapter, or upstream pin.

## Fixture contract

`tools/ghostty/resize_cases.py` defines 39 cases and 182 snapshots in
`tests/fixtures/ghostty-resize.json`. Each case observes the initial state and
every feed/resize operation. Grapheme mode 2027 is explicitly enabled before
capture; the reference scrollback limit is 2,000 lines.

The adapter accepts `COLS ROWS`, then `feed HEX`, `resize COLS ROWS`, or
`snapshot` operations. Dimensions are in 1..4096. Feed data is hex-encoded to
preserve partial UTF-8 and parser controls. Each snapshot is one JSON line:

- Geometry and zero-based cursor coordinates, pending wrap, active screen.
- Visible rows and scrollback in oldest-first order, with soft-wrap flags.
- Complete scalar sequences, width 0/1/2, wide-head and protection flags.
- Resolved foreground/background/underline colors and attributes, URI bytes.

The reference contains values rather than allocation IDs. Color tags and
attribute bits match the existing native snapshot representation. Wide tails
have width zero and no scalar sequence. Wide heads are blank padding at the
last column of a wrapped row. The C adapter is original test tooling using
the public SDK; it does not translate upstream implementation code.

Cases cover shrink/grow, history, trailing blanks, cursor and saved cursor,
pending wrap, wide heads/tails, one-column geometry, grapheme clusters, nowrap,
active/inactive alternate screens, margins, tabs, background blanks, styles,
links, clearing the active screen, partial UTF-8/CSI, and same-size resize.

```sh
python3 tests/ghostty_oracle_test.py
```

These six offline tests validate fixture identity and structure, source
mutation rejection, archive boundaries, required native ABI library selection,
and stale provenance rejection. CI and release workflows run them without
building Ghostty or installing Zig. They do not exercise Boggart resize or
satisfy BMUX-20 acceptance.

## Native API and ownership

```lua
local t <close> = require("terminal").new(80, 24, 2000)
t:feed("wrapped text")
t:resize(100, 30)
local image = t:snapshot(true)
```

Dimensions must be integers in 1..4096. Invalid arguments and closed terminals
raise errors. Allocation failure raises a recoverable resize error while
preserving both screens; a prior feed failure still requires reset. Same-size
calls preserve state and damage exactly. Successful resize expires borrowed C
row/cell views; copied Lua images remain valid.

`lpage_resize.c` owns the streaming crop/reflow algorithm and cursor pins.
`lpage.c` owns private geometry allocation/retirement through
`lpage_internal.h`. Candidate geometry shares the existing pools and retains
copied cells. Abort releases those holds; commit retires old geometry and
publishes the candidate without changing screen or pool identities.

The authoritative algorithms are the pinned `PageList.zig` `resize`,
`resizeCols`, `reflowRow`, `writeCell`, and `resizeWithoutReflow`; `Screen.zig`
`resize`; and `Terminal.zig` `resize`. These files are already in the port
ledger. The native implementation plan is
[bmux-resize.md](superpowers/plans/2026-10-13-bmux-resize.md).

Primary-screen width changes reflow when autowrap is enabled. Alternate screens
crop instead. Both allocated screens resize, including the inactive one.
Width growth reflows before height changes; width shrink changes height before
reflow. Same-size calls do nothing, including preserving tabs and margins.

Height shrink removes trailing blank rows first and pushes remaining top rows
into history. Height growth pulls history when the cursor is at the bottom;
otherwise it appends blank rows to preserve the cursor's visible row. Reflow
tracks current and saved cursor positions through wrapped lines and history.
Pending wrap clears and advances the cursor if its mapped cell leaves the
right edge. A saved cursor outside the active screen resets to its top left.

Hard lines trim empty cells on the right, while cursor pins preserve the needed
blank positions. Background-colored blanks remain meaningful. Reflow removes
old wide-head padding, creates padding at new wide boundaries, moves complete
graphemes, and repairs cropped wide pairs. One-column reflow substitutes a blank
for a wide glyph. Success damages every visible row, resets margins, restores
default column tabs on width change, and invalidates mouse motion geometry.
Parser fragments, replies/events, modes, and host policies survive resize.

Boggart retains its exact bounded history ring. Ghostty's history pruning uses
page allocation; the curated cases stay below eviction limits to isolate geometric
semantics. The native page tests verify Boggart's history limits 0/1/17 and release
of evicted styles, links, and graphemes through 9,000 mixed resizes. Do not claim pruning-policy parity.

Resize prepares both screen geometries before committing either. Failed
allocation leaves both screens, cursor state, pool references, tabs, margins,
damage, and parser state unchanged. Commit does not allocate. This stronger
transaction across both screens is a deliberate adaptation; it is not a claim
that Ghostty has the same failure policy.

## Initial oracle checkpoint evidence

The CMake target built and passed on arm64 macOS with Zig 0.16.0. It verified
40 ledger modules / 26 attributed destination files and 176 ABI types, compiled
the C99 adapter with `-Wall -Wextra -Werror`, and reproduced all 29 cases / 119
snapshots. Two compiled-adapter tests cover rejected arguments and empty feeds
with resize. The six offline guards and four Unicode generator tests pass.
Both products build; six focused terminal tests pass (2.21 s), and CLI/Studio
fingerprints agree on all 32 fields. Ninja dependency inspection confirms that
the oracle target is excluded from the default `all` target.
This checkpoint establishes the test reference, not implemented resize parity.


## Native checkpoint evidence and remaining acceptance

The updated optional target validates 176 SDK ABI types, compiles as strict
C99, passes three adapter tests, and reproduces all 30 cases / 123 snapshots.
The adapter now reads background-only palette/RGB content via the SDK cell
getters; the style-ID lookup alone loses those colors. Palette and RGB
regressions failed before that correction and now pass. The native fixture
comparison includes complete resolved colors, not just style IDs.

Both products build. The full registered suite passes **123/123 (130.45 s)**;
focused ASan/UBSan checks pass **17/17 (9.14 s)**; CLI/Studio agree on **33**
fingerprint fields, including a resize/save/restore snapshot. The source
fingerprint contains 31 compiled files, and attribution verifies 40 modules /
27 destination files. Strict C99 and Python guards pass.

`resize_failure` fails each allocation in eight crop/reflow and primary/alternate
combinations: **72** failures roll back geometry, cells, resolved pool contents,
reference counts, cursor/save state, parser, tabs, margins, modes, damage,
mouse state, replies, and event callbacks. It checks that commit allocates
nothing and that resize preserves an existing feed-failure state.
`terminal_resize` also tests dimension bounds, parser fragments, policy/queues,
height-only tabs, and finalizers resizing a terminal during row/snapshot
allocation. These checks run in normal and sanitizer builds.

The comparison corrected two existing feed behaviors needed by the vectors:
right-edge prints record pending wrap even in nowrap mode, and screen switches
copy cursor positions. Overwriting either half of a wrapped wide glyph now
clears its previous-row padding head (including a head in history); appending
a combining scalar with unchanged width keeps that head. Repeated alternate
mode sets retain the existing Boggart no-op policy; complete terminal protocol
conformance remains BMUX-16/23 work.

## Cached-capacity checkpoint

The original 6x3 nowrap crop/regrow mismatch is fixed. Native pages now keep
their allocated width separately from the exposed column count. Cropping
discards clipped text and owned references; growth within capacity exposes
blank cells and preserves wrap metadata. Growth beyond capacity, or a wide
head in the source page, rebuilds rows and clears wrap metadata. Candidate
rows allocate lazily; abort still releases all copied holds and commit
allocates nothing. Memory accounting sums actual page capacities, including
storage retained after a crop. Empty candidate pages are retired before commit.

The SDK captures **39 cases / 182 snapshots**, adding cached shrink/grow cycles,
growth beyond capacity, wide-head slow cloning, owned clusters/styles/links in
history, active/inactive alternate screens, reflow transitions, mixed page
widths, and a wide head beyond the native page boundary. An exhaustive native
comparison matches **38 cases / 181 snapshots**. One snapshot fails in
`cached_page_head_spill`; it remains in the main fixture and the registered
`terminal_resize` test fails. It has not been skipped or accepted as an override.

The failing case starts at 6x20, feeds `abcdefghij\r\n` twelve times, disables
autowrap, crops to 4x20, temporarily enables autowrap and prints `日` at row 18,
column 4, then disables autowrap and grows to 6x20. Ghostty's page-wide spacer
head check triggers slow cloning for earlier rows in the same SDK page, clearing
scrollback row 0's wrap flag. Boggart's 16-row storage pages put that row and
the spacer head in different pages and retain the flag. Matching the first
small cached-width case does not establish page-grouping compatibility.

The historical red evidence remains unchanged in
[resize-cached-width.json](benchmarks/2026-10-13-resize-cached-width.json).
The follow-up
[resize-cached-capacity.json](benchmarks/2026-10-13-resize-cached-capacity.json)
contains the corrected original case and the new failing case, full paired
snapshots, all 39-case comparison results, verified SDK provenance, fixture
hash, and 31 compiled native source hashes checked against the working tree.

`terminal_resize_cached` is now a registered passing regression. API bounds,
parser/policy/queues, damage, and allocation-time finalizer checks run separately
in `terminal_resize_api`, so a failed differential gate cannot hide them. The
API finalizer checks run in their own process, since retaining the large
fixture graph changes when Lua starts collection. The native tests also verify physical
capacity, allocated-byte accounting, blank regrowth, ownership, and 9,000 mixed
resizes. Fault injection now covers **108 allocation failures in 12 cases**,
including primary/alternate growth back to a previously cropped capacity.

Page-grouping parity remains acceptance work. Controlled C-API latency and
backend-scoped memory have now been measured as described below. No renderer,
PTY integration, or overall cmux parity is claimed.

Latest cached-capacity verification: the full registered suite is **124/125
(125.82 s)** and the focused ASan/UBSan suite is **23/24 (12.29 s)**. Both fail
only `terminal_resize` at the documented page-grouping observation. The
independent cached-width, API/lifecycle, page ownership and 108-allocation
rollback tests pass in both builds. The suite is intentionally reported as
failing; this checkpoint does not satisfy BMUX-20 acceptance.


## Paired C-API performance baseline

The [resize measurement](benchmarks/2026-10-13-native-sdk-resize.md) records
seven controlled corpora, four rounds and 124 samples per step. Both backends
produce matching rendered-value digests at all 29 states in every round, with
seven compiled harness tests validating full fixture fingerprints and rejected
inputs. Native height-only resize takes about 267–272 µs with 256 plain lines;
the SDK takes 0.17–0.29 µs. The native path currently copies retained cells even
when only row count changes. This is the next ownership/performance target.
Styled linked Unicode is faster in the native corpus; plain reflow and cached
nowrap changes are slower. No uniform speed advantage is established.

Raw samples, compiler/source/library hashes, full input bytes, backend-specific
memory figures, and uniform peak process RSS are retained. Memory scopes differ;
there is no measurement of transient peak allocation inside a transaction or
1/10/100-pane application workloads. The optional benchmark uses the already
verified SDK, stays outside default builds/CI, and introduces no Zig product
dependency. The known wide-head page-grouping gate remains failed.
