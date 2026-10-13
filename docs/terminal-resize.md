# Terminal resize and reference oracle

BMUX-20 adds resize/reflow to the native terminal. The checked-in reference
oracle is ready; the native `bterm_resize` and Lua `resize` APIs are not yet
implemented. The tracker acceptance criterion remains pending.

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

`tools/ghostty/resize_cases.py` defines 29 cases and 119 snapshots in
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

## Native behavior to preserve

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
page allocation; the 29 cases stay below eviction limits to isolate geometric
semantics. Separate native tests must verify Boggart's history limit and release
of evicted styles, links, and graphemes. Do not claim pruning-policy parity.

Resize should prepare both screen geometries before committing either. Failed
allocation must leave both screens, cursor state, pool references, tabs, margins,
damage, and parser state unchanged. Commit must not allocate. This stronger
transaction across both screens is a deliberate adaptation; it is not a claim
that Ghostty has the same failure policy.

## Oracle checkpoint evidence

The CMake target built and passed on arm64 macOS with Zig 0.16.0. It verified
40 ledger modules / 26 attributed destination files and 176 ABI types, compiled
the C99 adapter with `-Wall -Wextra -Werror`, and reproduced all 29 cases / 119
snapshots. Two compiled-adapter tests cover rejected arguments and empty feeds
with resize. The six offline guards and four Unicode generator tests pass.
Both products build; six focused terminal tests pass (2.21 s), and CLI/Studio
fingerprints agree on all 32 fields. Ninja dependency inspection confirms that
the oracle target is excluded from the default `all` target.
This checkpoint establishes the test reference, not implemented resize parity.
