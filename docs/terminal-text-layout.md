# Native terminal text measurement foundation

`terminal:width(text)` returns the display-cell width of plain UTF-8 text under
that terminal's current grapheme mode and pinned SDK profile.
`terminal:take(text, columns)` returns the longest effective-cluster prefix and
its used columns. A wide cluster that would cross the budget is left whole.
Negative budgets become zero; Lua budgets above INT_MAX clamp to INT_MAX.

```lua
local t <close> = require('terminal').new(80, 24, 0)
assert(t:width('é👩‍💻🇬🇧日') == 7)
local prefix, used = t:take('é👩‍💻X', 3)
assert(prefix == 'é👩‍💻' and used == 3)
t:feed('\27[?2027l')
assert(t:width('👩‍💻') == 4)
```

These are text helpers, not a VT escape/cursor interpreter. They ignore C0/DEL
width and do not apply tab movement, wrapping, newline cursor changes, SGR or
OSC commands. UTF-8 encoded C1 characters follow the native printable profile.
The helpers use explicit string lengths, including embedded NUL. Malformed
bytes each consume one byte and measure as U+FFFD; this bounded helper policy
is distinct from a stream decoder's incomplete sequence at EOF.

Mode 2027 on groups according to the same generated `btunicode` state machine
and width effects as printing. Mode off keeps scalar cells and zero-width suffixes.
Ignored selectors and standalone marks do not change the effective cluster state.
The DFA and previous scalar stop advancing after the native base+64 suffix cap,
while source suffix bytes remain part of the returned prefix. Width effects still
follow the retained previous scalar. The implementation is allocation-free and
linear in source bytes; totals saturate at INT_MAX.

The API measures future plain text under the current mode. Existing native cells
retain their recorded widths when a mode changes; renderers must use those widths
instead of remeasuring historical cell text under the new mode. It also does not
report cursor displacement caused by a wide glyph wrapping at a margin.

Lua validates/coerces text and column arguments before borrowing the native mode,
then reacquires the terminal to reject finalizer-induced closure. Prefix source
strings stay rooted on the Lua stack; no native borrow crosses result allocation.

## Verification

`terminal_text_width` compares helper results against actual native cell widths
for ASCII/CJK, marks, emoji ZWJ, RI flags, selectors, Hangul, Indic, pinned-profile
U+05C8/U+05C9, Unicode C1, NUL and long capped clusters, in both modes. Every byte
split of each valid plain-text vector produces the same cell result. Prefix
budgets and explicit emoji/flag/selector vectors prove whole-cluster boundaries
and width shrinking. Malformed UTF-8 and integer-budget edges are checked separately.

`terminal_graphemes` covers Lua mode/prefix behavior and forces finalizers during
number-to-string argument conversion. The test uses Lua 5.5's `collectgarbage`
parameter API (`stepsize=0`), because the old positional incremental arguments
are ignored by that runtime. Finalizer closure returns a controlled error.
Studio's native pane test exercises the same APIs in its shared interpreter.

Normal focused gates: **10/10**, 4.06s. ASan/UBSan: **9/9**, 6.02s. CLI/Studio
core parity: **33 identical fields**. The existing attribution verifier passes
44 modules/34 ported files. C11 warning and diff checks pass. A real SDL3 pane
run also passes the new methods and existing input/shell checks.

## Work still required for BMUX-19

The measurement foundation is followed by native cell shaping below. General
`sys.width`/`sys.wtake`, termctl and generic font measurement keep their documented
Unicode-16 scalar policy. The native terminal cell printer uses the pinned SDK
profile. BMUX-19 criterion 1500 remains open until terminal cluster painting,
measurement and corresponding prefix/render consumers agree across fragmented
input, fonts, edits/history/resize and deferred lifetime.

The font raster/cache ownership now lives in `studio/src/fontglyph.c`, separate
from generic SDL drawing in `renderer.c` (416 lines after extraction). The
internal `fontglyph.h` boundary keeps FreeType faces, font bytes and mutable
cache entries private. It returns scalar glyph geometry by value plus a borrowed
texture, font metrics and atlas capacity statistics. The renderer installs its
borrowed SDL device and pending-geometry flush hook. Each returned glyph must be
queued before another lookup can migrate its atlas; migration and free flush
geometry before changing UVs or destroying textures. Font caches must be released
before destroying the device. Headless measurement keeps the existing CPU path.
Both files are included in compiled renderer-source fingerprints.

This ownership refactor preserves the existing scalar layout, fallback policy,
style variants and atlas behavior. Normal focused tests pass **9/9**, 4.60s;
ASan/UBSan **9/9**, 6.73s. All **26** saved pre/post SDL dummy-driver screenshots
are byte-identical, including styles, clips, partial damage, history, resize and
queued mutation/close. The controlled SDL window pixel/lifetime test also passes.

## Native positioned cell rendering

`termrender.c` uses `ren_get_cluster_bounds` and `ren_draw_cluster` with each
captured cell's explicit UTF-8 length and **recorded width times cell width**.
It shapes one retained cell at a time. Existing cells keep their advances after
mode changes. ASCII uses the existing C scalar draw path; other cell text uses
cached positioned glyphs, with no Lua cell traversal or snapshot allocation.

`fontshape.c` calls the pinned static HarfBuzz 14.4.0 C API over immutable owned
font bytes. Each FreeType face records its byte owner, length and TTC index, and
owns its separate OpenType shape object/reused buffer. Shape objects are freed
before faces/bytes. No second FreeType instance or runtime HarfBuzz dependency
is introduced. HarfBuzz's
[OpenType font implementation](https://harfbuzz.github.io/harfbuzz-hb-ot-font.html)
and [shaping API](https://harfbuzz.github.io/harfbuzz-hb-shape.html) provide that
contract supports this path; source/license hashes are in
`THIRD_PARTY/harfbuzz.md`.

`fontcluster.c` tries the bounded existing fallback face chain on the whole
cluster, accepting a complete positioned run. This also permits canonical
composition when a font supports the composed glyph. Unsupported clusters draw
one diagnostic box in their cell span. Its 64 fixed cache slots compare full
source bytes; runs retain IDs/positions and resolve textures at draw time.
Input is bounded by the native 65-scalar/260-byte retention cap, output by 256
glyphs, with explicit shaping work/position limits. Allocation failure remains
retryable and does not publish a cached unsupported run.

Retained scalar cells and soft-hyphen heads use a literal shaping policy that
preserves their nominal ink. Flags reset on every reused buffer; joined emoji
and other clusters retain normal handling of invisible formatting scalars. A
regression test proves a positive-width soft hyphen survives with its selected
face's glyph, including legacy combining/joiner suffixes.

`glyphcache.c` uses the Venus-derived `lidmap` Swiss map for face/glyph-ID/phase
keys. It holds at most 7168 entries and four SDL pages per font, starting at
512 square and using 1024 for larger glyphs (at most 16 MiB logical RGBA).
Rollover flushes pending geometry before clearing textures. Failed unused-slot
uploads publish no metadata; cached geometry stays valid. CPU bitmap staging is
released after upload. Capacity diagnostics include these pages. Atlas UVs never
live in shaped runs or native row snapshots.

The painter centers a run in its cell span and compresses genuinely wider runs
horizontally; fractional monospace advances within one pixel preserve natural
ink. Positioned marks share the primary baseline. Bounds and painting use one
layout routine, including ink overhang and font decorations. A regression test
reproduces/fixes the tiny-negative-offset subpixel phase edge. General scalar
renderers retain their policy while their prefix/width consumers await migration.

`renderer_clusters`, `renderer_atlas` and `studio_terminal_clusters` verify
canonical accents across four styles/pixel budgets, positioned marks, a pinned
Indic fixture, all native vector byte splits/both modes, retained row and font
lifetime, cache limits/upload failure, mode changes, history/reflow and queued
closure. The existing scalar reference test covers single-scalar parity and
ASCII overhang; shaped text uses the native tests rather than the old mark
placement as an oracle. Normal and ASan/UBSan focused suites pass, as do the
controlled SDL window tests. C11 warning/diff checks and static-link inspection
pass. Paired draw evidence: `docs/benchmarks/2026-10-14-cluster-shaping.md`.

The full suite passes **149/149**, 135.74s at the native-shaping checkpoint.
Final literal-cell policy checks pass in normal and ASan/UBSan builds, including
the reproduced soft-hyphen regression and native pane tests.

General helper/renderer migration, remaining BMUX-25 typography and full
BMUX-3/28 frame/input gates are still required. Criterion 1500 remains open.

## Whole-string Studio grid consumers

`sys.cell_width(text)` and `sys.cell_take(text, columns)` explicitly select the
same native on-mode plain-text policy as terminal cells. `sys.width/wtake`
continue to serve their scalar renderers. Studio's `font:get_grid_width(text)`
returns pixels using the font's width of `0` as its cell unit;
`renderer.draw_grid(font, text, x, y, color)` returns the ending pixel position.
`common.draw_grid` aligns and draws with those same metrics. These methods use
explicit lengths, including embedded NUL. C0/DEL are ignored rather than treated
as cursor, tab or newline instructions; callers provide one logical text line.
The grid span is bounded to 100 million pixels and Lua coordinates are bounded
before conversion to integers.

`btunicode_text_next` now copies exactly the retained UTF-8 of one effective
native cluster while consuming its source prefix. Ignored and over-cap source
bytes do not enter the copied text. The existing width/take helpers use the same
segmentation routine. `bunicode_utf8_put` centralizes strict scalar encoding and
replaces the render-row encoder; every valid scalar round-trips through the
bounded decoder. The collector compares its text and widths with actual native
cells in both modes, including selectors, controls and retention caps.

`gridtext.c` uses that iterator for both ink bounds and positioned cluster paint.
Grid commands carry an explicit-length copy of the source in the existing
command arena, with a separate payload so ordinary editor commands retain their
size. They use the same deferred font cleanup as other text commands. Empty,
invisible or zero-width grid text adds no paint command. Source mutation, embedded
NUL, no-damage replay and failed buffer growth are tested.

Picker text and sandbox text labels now pair cell prefixes with grid painting.
A one-cell filename budget emits an ellipsis instead of splitting an emoji;
sandbox `text_width` reports the same pixels its `text` function paints. Existing
file-name control-byte display sanitization remains before grid layout.

Normal focused checks pass **13/13**, 4.64s; ASan/UBSan **13/13**, 9.59s. The
controlled SDL window test verifies width/prefix/paint/native pixel agreement,
whole emoji truncation in the actual picker/sandbox draw paths and deferred font
closure. Final encoder round-trip checks pass separately in both builds. C11
warning/diff checks and the existing 44-module/34-file attribution gate pass.

## Styled AgentView grid consumers

AgentView now normalizes styled token boundaries before wrapping. The token at
each native cluster's source head owns its color, bold and link metadata.
`sys.cell_partition(text, ends)` accepts cumulative byte offsets and returns
owner/text spans, keeping original source bytes for selection, including ignored,
malformed and over-cap suffixes. Its workspace and source stay rooted through Lua
result allocations. `sys.cell_first(text)` consumes one whole effective cluster
when a glyph exceeds a narrow wrapping budget.

Transcript, choices and composer use paired cell metrics/grid painting. Mouse
selection snaps to whole cluster boundaries. Composer keyboard motions and
deletion now use whole-cluster editing; see
[`studio_grapheme_edit.lua`](../tests/studio_grapheme_edit.lua).

Direct binding checks cover every byte boundary inside accent/emoji/flag/selector
clusters and invalid token offsets. Styled layout checks cover head ownership,
one-cell wrapping and selection. SDL tests compare styled grid pixels with native
retained cells and verify the real transcript paints visible pixels. Nine focused
checks pass in both builds; the Studio suite passes separately in normal and
ASan/UBSan builds after concurrent runs collided on its existing timestamp-named
temporary file. Controlled SDL window, C11 warnings and attribution checks pass.
The font pipeline now handles intrinsic BGRA/color emoji, including faint
styling; see [`studio_color_emoji.lua`](../tests/studio_color_emoji.lua). This
does not establish Unicode/rendering parity for generic Fleet text consumers
or every platform/font combination.

CLI/TUI consumers still need an explicit external-terminal policy before switching
their helpers. Criterion 1500, full performance gates and the overall BMUX goal
remain open.
