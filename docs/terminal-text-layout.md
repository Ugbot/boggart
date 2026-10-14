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

This is the measurement foundation, not integrated grapheme rendering. General
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

The next increment needs glyph-ID lookup and positioned cluster shaping within
that boundary. Shaped runs should retain glyph IDs/positions, resolving each
borrowed texture at draw time so later atlas migration cannot stale a run.
Complex cluster shaping will use a pinned static OpenType
shaper over owned font bytes. HarfBuzz's
[OpenType font implementation](https://harfbuzz.github.io/harfbuzz-hb-ot-font.html)
and [shaping API](https://harfbuzz.github.io/harfbuzz-hb-shape.html) provide that
contract. No HarfBuzz dependency or shaping code has been introduced yet.
