# SDK page topology diagnostic

The native 16-row storage chunks differ from the pinned SDK's observable
page boundaries. `cached_page_head_spill` remains a failed compatibility gate.
The diagnostic captures the boundaries and capacity changes needed to adapt
native ownership metadata.

The [raw report](2026-10-13-sdk-page-topology.json) contains ten inputs and
59 frames, archive/build/probe identities, page serials/capacities/layout
sizes, and every used row's wrap/head flags. All 59 frames match the
independent, source-verified C ABI oracle for dimensions, active screen,
flattened row count/order and wrap/head flags. Page membership itself comes
directly from the instrumented SDK's internal page list. The C ABI comparison
does not independently expose those boundaries or verify
every cell, style, hyperlink or cursor field.

| Probe | Observed SDK behavior |
| --- | --- |
| Six-column initial page | Capacity 6,847 rows; existing failing input occupies one SDK page |
| 215-column viewport | Capacity 221 rows; 300-row viewport occupies two pages |
| Head in first page | First page replaced; second retains 49 wrapped rows |
| Head in second page | First retains 111 wrapped rows; second replaced |
| Height changes before head | Same page-local outcomes in both boundary inputs |
| Style stress | Styles 128 → 1,024; slow grow adjusts row capacity 221 → 224 |
| Grapheme stress | Bytes 8,192 → 65,536; slow grow adjusts row capacity 221 → 230 |

Capacity follows SDK byte layout and allocation alignment. Managed-data
growth and replacement can change it. A fixed chunk size or a screen-wide
head flag cannot represent the observed behavior.

Reproduce using the pinned archive and independently verified oracle:

```sh
python3 tools/ghostty/probe_page_topology.py \
  --work-root /private/tmp/bmux-page-diagnostic \
  --archive /private/tmp/bmux-ghostty-source.tar.gz \
  --global-cache-dir /private/tmp/bmux-zig-global \
  --oracle-binary /private/tmp/bmux-verified-oracle/resize-oracle \
  --output /private/tmp/bmux-page-topology.json
python3 tests/ghostty_page_topology_test.py
```

The optional probe uses pinned Zig and a separate scratch source tree. Product
C99 builds and verified oracle artifacts remain independent. Seven offline
tests guard incomplete captures, invalid membership/capacities, mismatched
geometry/screens/flags and generated-input validation. Layout geometry in the
report describes this build/platform; it does not establish sizing on every
target. This is a diagnostic, with no performance claim.

The [implementation plan](../superpowers/plans/2026-10-13-bmux-page-boundaries.md)
tracks layout arithmetic, logical page lifecycle, rollback and full
differential validation as remaining work.
