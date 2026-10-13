# Native / pinned SDK resize baseline — 2026-10-13

Boggart height-only resize currently clones every retained cell. With 256
plain lines and an 80x24 viewport, its three height-only changes take median
**272.48, 266.71 and 269.60 µs**, versus **0.29, 0.17 and 0.25 µs** for the
pinned SDK. This identifies a real copy/ownership cost to remove; the native
core is not uniformly faster. Styled linked Unicode resize is faster in this
corpus, while plain reflow and cached nowrap growth are slower.

[Raw paired report](2026-10-13-native-sdk-resize.json) records every timing,
memory observation, state digest, corpus byte, compiler command and identity.

## Controls and scope

- arm64 macOS, native RelWithDebInfo (`-O2 -g -DNDEBUG`), SDK ReleaseFast / SIMD disabled at the pinned Ghostty revision.
- Both C harnesses compile as strict C99 with `-O2 -Wall -Wextra -Werror`; one links the actual native VT/Unicode archives, the other the verified SDK static library.
- Each sample creates and feeds a fresh terminal outside the timer, then times each resize call separately. Both use 80x24, 2,000-line history, grapheme mode 2027, and identical UTF-8/control bytes.
- Four rounds, 31 timed samples plus three warmups per round: **124 samples per step**, 2,728 resize calls per backend. Backend order alternates between rounds.
- A separate verification terminal walks every visible/history cell before warmup. All four rounds match on all 29 observed states: geometry, cursor, pending wrap, active screen, row wraps, scalar sequences, width/head/protection, resolved style and URI.
- These FNV-1a checksums cover rendered values. They do not prove parser/queue or pool-state parity, or replace full snapshot comparisons. Seven compiled CLI tests validate both harnesses, including fingerprints derived independently from complete SDK fixtures for cached growth, RGB-only blanks, styles/links and Unicode clusters.
- macOS timing uses `mach_absolute_time` with its native scale. The observed positive timer tick is about 41–42 ns. The same-size results are below useful timer resolution; no ratio or zero-cost claim is made for them.
- The driver verifies the SDK source archive/tree and static-library hash before and after, checks all 31 native source fingerprints and both archive hashes, and records the active Ninja compile commands. A stale vendored-only `compile_commands.json` is not used.

## Medians

Default steps are 40x24 → 120x32 → 80x24. The nowrap case uses
40x24 → 80x24 → 120x32 → 80x24; height-only uses
80x12 → 80x48 → 80x24. Same-size calls repeat 80x24.

| Corpus | Native medians (µs) | SDK medians (µs) |
|---|---:|---:|
| empty | 33.98, 40.58, 51.98 | 46.33, 67.35, 38.69 |
| plain_history | 583.60, 716.52, 747.60 | 67.81, 74.77, 55.96 |
| styled_linked_unicode_history | 197.88, 226.23, 236.75 | 719.35, 754.77, 757.08 |
| nowrap_cached_history | 178.42, 166.31, 283.71, 312.52 | 3.29, 0.54, 60.90, 3.83 |
| alternate_crop | 50.00, 55.67, 79.19 | 46.48, 109.85, 38.90 |
| height_only_history | 272.48, 266.71, 269.60 | 0.29, 0.17, 0.25 |
| same_size_history | below useful timer resolution | below useful timer resolution |

Plain history contains 256 numbered hard lines of 75 ASCII columns. The
Unicode corpus has 64 lines of combining accents, wide ideographs, ZWJ
emoji, regional-indicator flags and variation-selector hearts, all styled
and hyperlinked. Feed bytes and hashes are included in the raw report.
P95 and per-round samples are retained there; medians do not establish a
whole-app tail-latency or speed claim.

## Memory observations

Native figures sum screen allocations, pointer rings and screen-owned pools.
The SDK reports primary/alternate page resident and virtual bytes, including
its different page-capacity and spare-page policy. Both exclude some terminal
bookkeeping and allocator overhead. These fields have different scopes and
are not interchangeable measures of total process memory.

For the initial empty viewport, native screen storage is 43,648 bytes across
two 16-row pages; SDK page accounting reports 409,600 resident / 1,638,400
virtual bytes for one active page and spare capacity. This makes the
allocation-model difference concrete, but does not prove physical memory
usage per pane. The report also records uniform per-process peak RSS; that
includes the harness, libraries, feed buffer and verification walks. There
is no measurement of peak memory inside a resize transaction, no 1/10/100-pane
app workload, and no renderer/PTY integration. BMUX-10/12 remain open.

## Reproduce

Build the pinned optional oracle first, using the same work root below:

```sh
cmake -S . -B build -DBOGGART_GHOSTTY_ORACLE_WORK_ROOT=/tmp/boggart-resize-oracle
cmake --build build --target ghostty-oracle
CCACHE_DIR=/tmp/boggart-resize-ccache CCACHE_TEMPDIR=/tmp \
  python3 tools/ghostty/bench_resize.py \
  --build-dir build --oracle-work-root /tmp/boggart-resize-oracle \
  --output /tmp/native-sdk-resize.json
```

The driver requires a native, unsanitized Ninja build, Python 3, and a C
compiler. It builds the native VT target, compiles and validates both optional
harnesses, then performs the paired runs. It reuses the already verified SDK;
the benchmark is outside normal product builds and CI and adds no Zig product
dependency. Recorded execution is macOS only; Linux execution is unverified.

## Next changes

Preserve cell/page ownership through a height-only resize by preparing new
row pointer rings and allocating only genuinely new blank rows. Source
pages and pool references must remain untouched until both screens are
prepared; commit transfers the retained rows without allocating, and abort
retires only candidate-owned storage. See the
[height-resize plan](../superpowers/plans/2026-10-13-bmux-height-resize.md).

The SDK page-wide wide-head metadata discrepancy still fails BMUX-20. A
height-only optimization must retain that test, preserve all existing
comparisons, and avoid substituting a global wide-head rule for a real page
model. Faster measurement on these seven corpora does not satisfy that gate.
