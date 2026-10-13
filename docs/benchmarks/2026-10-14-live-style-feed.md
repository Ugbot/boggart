# Live page style references (BMUX-20)

Logical page spans now own a Venus-derived Swiss map of cell-backed style ID
reference counts. A new unique style is reserved against the SDK's actual item
limit, including its reserved zero ID, before writing the cell. The verified
`lp_capacity_grow` rule updates retained capacity. Wide-pair repair reserves
the incoming style before retiring the old glyph's last references, preserving
the transient capacity requirement.

The formerly failing `sdk_style_capacity_growth.step9` snapshot now matches.
The large corpus matches 77/79 snapshots; the remaining two final steps are
mixed-script and ASCII grapheme-capacity growth. Small parity remains 46 cases /
215 snapshots. This is cell-backed style accounting, with complete page-local
cursor, hyperlink, string and grapheme ownership still requiring work.

Bulk edits and row movement invalidate affected style caches. Default history
append preserves retained row membership; an evicted styled row invalidates
its own group. Reconciliation builds replacement maps before retiring old
storage. Unpublished resize geometry defers caches; commit frees old maps and
keeps the existing allocation-free commit path. A failed resize leaves source
maps unchanged. Failure images now cover controls and live key/value entries,
in addition to the private group ring and original page/pool checks.

The map gains a writable existing-value lookup, borrowing storage until a
structural mutation. Hot reference updates reuse that lookup. Unchanged styles
avoid counter work, and untracked default screens bypass map bookkeeping.
Map initialization uses the SDK's bucket count: Venus doubles the supplied
hint, while the SDK's 13/16 occupancy fits inside the map's 7/8 limit. Allocated
storage metrics include all three aligned map buffers.

## Controlled feed cost

The [measurement](2026-10-14-live-style-feed.json) compares current native
archives with a baseline whose `lpage.c.o` alone comes from `f9229ac`. Both use
the same `-O2 -g -DNDEBUG -std=gnu11` library flags. A checked-in C probe feeds
approximately 1 MiB per workload at 80×24 with 1,000 history rows. Two rounds
alternate process order, each collecting 11 samples after three warmups.
Every measured sample has the same rendered-state digest across variants.

| Workload | Before median | After median | Final allocated bytes, before → after |
| --- | ---: | ---: | ---: |
| Plain | 10.667 ms | 11.636 ms | 1,371,144 → 1,371,336 |
| Dense SGR | 9.045 ms | 11.406 ms | 1,371,144 → 1,376,520 |
| Styled Unicode | 12.436 ms | 14.524 ms | 1,633,224 → 1,638,600 |

The new accounting has measured feed overhead: approximately 9%, 26% and 17%
for these corpora. This is a compatibility checkpoint, with performance tuning
still open. Allocated bytes are final `lpage_usage` storage, excluding terminal,
parser, callbacks, allocator overhead, RSS and transaction peak. The probe
digests codepoints, widths, flags, row wrap, style values and current cursor;
it does not prove complete terminal or application conformance.

`tools/termbench/style_feed.c` and `compare_style.lua` are C/Lua development
tools. The report records source, driver, harness and executable hashes; source
and executable identities are rechecked after measurement. A baseline archive
is prepared by copying the current archive and replacing its `lpage.c.o` with
an object compiled from `git show f9229ac:src/lpage.c` using the matching flags.
Link each probe with its respective archive and the same current
`libboggart_unicode.a`, then run:

```sh
BOGGART_HOME=/private/tmp/bmux-style-feed-home ./boggart \
  --eval tools/termbench/compare_style.lua -- \
  /private/tmp/bmux-style-before-feed /private/tmp/bmux-style-after-feed \
  docs/benchmarks/2026-10-14-live-style-feed.json
```

Do not run builds, tests or other task benchmarks alongside this measurement.
The three corpora measure C feed calls only; renderer, PTY and application
budgets remain separate work. BMUX-20 and the full bmux objective stay open.

Final verification: CLI/Studio builds, C11 warning checks and Lua syntax pass.
Full normal CTest passes 131/132 (115.15 s); the final ASan/UBSan focused run
passes 7/8 (53.00 s), including native and scalar 20-second map soaks. Both
fail only the two grapheme observations in `terminal_resize_large`, with no
sanitizer diagnostics. The style tests cover dense capacity growth, wide-pair
transient reservation, resize, erase/ID reuse, history recycling and cleanup.
The failure gate preserves group controls/live entries as well as existing
page/pool/cursor/callback state, and confirms allocation-free commit.
