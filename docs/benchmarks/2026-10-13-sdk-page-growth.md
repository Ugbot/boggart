# SDK managed-page growth diagnostic (BMUX-20)

The pinned SDK grows page-local metadata during printing, before the three
remaining large-corpus resize mismatches. Its capacity fields retain those
increases, so the later column adjustment changes row boundaries. The native
logical spans currently retain defaults. Matching those boundaries requires
live style/reference and allocator accounting.

The [capture](2026-10-13-sdk-page-growth.json) contains 24 real growth events
across all four metadata dimensions. Sixteen workloads include the unchanged
11-case large resize corpus plus sparse style/grapheme pages and hyperlink
work. All 89 snapshots are independently checked against the pristine C ABI
adapter for dimensions, active screen, row order, wrap flags and final-column
wide heads. These are topology checks, not a comparison of every snapshot
field. Instrumentation is confined to a separate copy of the SDK.

| Workload | Used rows | Capacity change |
| --- | ---: | --- |
| Dense styles | 221 | 128 → 256 → 512 → 1024 |
| Dense graphemes, both scripts | 221 | 8192 → 16384 → 32768 → 65536 bytes |
| Sparse styles | 25 | 128 → 2440 |
| Sparse styles, bounded projection | 2 | 128 → 4096 |
| Sparse graphemes | 25 | 8192 → 192253 bytes |
| Sparse graphemes, bounded projection | 22 | 8192 → 262144 bytes |

Style growth first occurs at 103 living nondefault entries, not 128. The SDK
rounds the requested count into a hash-table layout, applies a load limit and
reserves its default entry. Grapheme growth also depends on fragmentation.
Each ASCII grapheme growth event has 80 free bytes but only a 48-byte contiguous
run; the map remains below capacity (127/512, 255/1024, 511/2048 entries).
The pending append needs a larger contiguous allocation. Sum-only byte
accounting would miss these events.

`lp_capacity_grow` ports the SDK's nonallocating capacity decision into C. It
restores standard defaults from zero, doubles with integer-limit saturation,
then projects style counts or allocated grapheme bytes over the page's rows,
adding 25% headroom. Projection is bounded at 32 times the pre-growth capacity
and accepted only if the resulting layout fits the SDK's page-size limit.
Failure preserves the output; rehash retains existing capacity. All 24 captured
outcomes are frozen in a C fixture. Edge tests cover zero capacities, saturation,
projection bounds, projection rejection, invalid inputs and output preservation.

The capture, fixture generation and offline guards are Lua development tools,
running through the project's C/Lua executable. The diagnostic alone needs the
pinned Zig compiler and SDK archive; ordinary builds compile checked-in C data.

```sh
BOGGART_HOME=/private/tmp/bmux-growth-home ./boggart \
  --eval tools/ghostty/probe_page_growth.lua -- \
  --work-root /private/tmp/bmux-page-growth-lua \
  --archive /private/tmp/bmux-ghostty-source.tar.gz \
  --global-cache-dir /private/tmp/bmux-zig-global \
  --oracle-binary /private/tmp/bmux-verified-oracle/resize-oracle \
  --output docs/benchmarks/2026-10-13-sdk-page-growth.json
BOGGART_HOME=/private/tmp/bmux-growth-home ./boggart \
  --eval tools/ghostty/growth_fixture.lua -- --check
env -u NO_COLOR ctest --test-dir build \
  -R '^(page_layout|ghostty_page_growth|page_resize|resize_failure)$' \
  --output-on-failure
```

The archive hash and all 5,915 SDK files are verified before and after capture;
the report records pristine/instrumented source identities, probe/helper/input
hashes and independently verified C-ABI output hashes. The C fixture generator
rejects source drift, mixed target shapes, missing coverage and unsafe numeric
or dimension fields. CTest runs the Lua guards on normal builds.

This checkpoint supplies the growth calculation and evidence needed by live
page metadata. It does not wire that accounting into the screen yet: the three
large compatibility failures remain, and BMUX-20 stays in progress. No latency,
memory or application-level improvement is claimed.

Final verification: normal CLI/Studio builds and strict C11 warnings pass.
Normal and ASan/UBSan focused CTest each pass five tests and fail only the
unchanged three large capacity snapshots (4.30 s / 14.19 s), with no sanitizer
diagnostics. The C layout/growth matrix, mixed resize/ownership tests, failure
rollback checks and Lua provenance guards all pass. The small SDK suite passes
all 46 cases / 215 snapshots. The full suite was not repeated for this unused
growth calculation; the prior Unicode checkpoint's full-suite results remain
recorded separately.
