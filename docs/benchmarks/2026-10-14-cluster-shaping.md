# Native cell shaping: paired Studio draw evidence

The native row renderer now shapes each retained terminal cell with static
HarfBuzz 14.4.0, then rasterizes/cache-looks-up positioned glyph IDs through the
existing FreeType. Recorded cell widths supply advances. Canonical accents and
Indic shaping are verified separately; the scalar control has the old rendering
behavior, so the Unicode comparison includes a correctness improvement.

All captures use the same RelWithDebInfo binary, 80x24 native pane, primary font
16, identical frontend/font/corpus hashes and compiled renderer-source hashes.
The script-only `_test_cluster_shaping` control is set before creating contexts:
`off` uses existing scalar measurement/drawing; `on` uses native cluster layout.
It is registered only under `BOGGART_STUDIO_SCRIPT`. Neither path uses per-cell
Lua draw calls. `studio_draw.lua` performs six warmups and 21 measured samples
per corpus/mode, with input/feed/sync outside the timed section. Each backend has
three paired process runs, alternated before/after, 63 samples per comparison.
These captures precede the final literal scalar/soft-hyphen flag correction;
the benchmark corpus contains no soft hyphens. The exact captured source hashes
remain in each report; the final policy has separate regression verification.

## Metal, actual SDL window

Median one-row-dirty CPU time:

| Corpus | Scalar control | Native cluster | Change |
|---|---:|---:|---:|
| Plain | 0.376 ms | 0.359 ms | -4.5% |
| Styled | 0.406 ms | 0.402 ms | -1.0% |
| Unicode | 0.458 ms | 0.359 ms | -21.6% |
| Mixed styles | 0.355 ms | 0.376 ms | +5.9% |

The Unicode sample emits **334 -> 267 quads**, **266 -> 3 batches** and
**265 -> 1 texture switches**. Its logical RGBA glyph capacity falls from
**3,670,016 -> 2,359,296 bytes**. Fallback faces share the glyph-ID pages within
a font; the composed accent emits one glyph. Plain/mixed geometry counts remain
400 quads/2 batches/zero switches. Mixed styles incur a small CPU increase;
this increment does not establish a universal performance improvement.

Unchanged frames replay zero rows and have 6-7 microsecond median CPU time.
Dirty frames queue 24 rows, replay five and skip 19. Presentation wall medians
remain around 8.4-8.7 ms. This is a draw/presentation measurement, **not a
keypress-to-pixel or flood/frame-pacing gate**.

## SDL software control

Final median dirty-frame CPU times: plain 0.440 -> 0.325 ms, styled
0.386 -> 0.475 ms, Unicode 0.502 -> 0.412 ms and mixed 1.068 -> 0.929 ms.
Styled CPU regresses here while wall medians are nearly identical
(0.474 -> 0.475 ms); the software results are mixed. Unicode geometry is the
same 334 -> 267 quads, 266 -> 3 batches, 265 -> 1 switches. Its logical RGBA
capacity falls from 2,883,584 -> 1,572,864 bytes. Style-atlas sharing remains
disabled on software, matching the previous policy.

The initial software captures caught extra overhead on ASCII. They are preserved
under `2026-10-14-cluster-shaping-raw/initial/`. The final implementation draws
ordinary ASCII directly through the existing C text path, preserving synthetic
styles and avoiding cluster-layout work for those glyphs. General font decoration
options use the cluster layout path so their recorded advances/bounds agree.

Raw captures and summaries: `2026-10-14-cluster-shaping-raw/` (18 captures and
three summaries, including initial evidence). `studio_draw_delta.lua` verifies
backend/frontend/font/corpus consistency and derives its backend label from the
captured renderer. A variable-shadowing error in that labeling change initially
prevented the Metal summary; it was fixed and the completed captures reused.

## Correctness and remaining work

`renderer_clusters` verifies canonical pixels in all four styles and pixel
budgets 1-18, positioned marks, pinned Indic substitution/reordering, every byte
split of retained-cell vectors in both modes, source destruction and pending
ID-atlas geometry during font free. `renderer_atlas` checks failed uploads and
both 7168-entry and four-page rollover. `studio_terminal_clusters` verifies
styles, fragmented text, preserved widths after mode changes, history/reflow and
queued mutation/closure using both the bundled and pinned Indic font, including
an actual SDL window. Normal and ASan/UBSan focused checks pass.

General scalar width/prefix consumers still require migration with their
renderers. Across-cell ligatures, real style faces, colored emoji and HiDPI/zoom
remain in BMUX-25. The full scroll/flood and input-latency gates remain in BMUX-3
and BMUX-28. BMUX-19 criterion 1500 remains open.
