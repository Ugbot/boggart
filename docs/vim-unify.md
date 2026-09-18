# One vim, every surface

## The problem

Modal editing is implemented three times in boggart, over two different buffer
substrates:

1. `lua/tui/vim.lua` (~909 lines). A clean, surface-agnostic modal engine over a
   `{lines, cy, cx, edit_mode, _vs, _undo, _redo}` buffer with `buf:clamp_caret()`.
   Normal/insert/visual/vline, motions, operators (d c y), text objects, f/t,
   `/ ? n N * #`, ex-lite. Snapshot undo, one unnamed register. Drives the cTUI
   composer (`lua/tui/input.lua`). Codepoint-indexed columns.
2. `studio/data/core/agentview.lua`. The studio chat composer. Hand-rolls a
   stub modal layer over the SAME `{lines, cy, cx}` shape (`self.edit_mode`,
   `set_edit_mode`, the `on_text_input`/`on_key_pressed` branches ~1126-1404).
   Normal mode is only a viewport (i/a/o/c/: back to insert, `{`/`}` jump user
   turns); no operators, no visual, no d/c/y. Byte-indexed columns.
3. `studio/data/core/vim.lua` (~1715 lines). A full DocView editor vim over
   lite's `Doc`: `doc:get_selection`, `doc.lines`, `doc:get_char`,
   `doc:remove/insert/get_text`, `translate.*`, `DocView.translate.*`. Real doc
   undo, multi-cursor (dot-repeat fan-out), visual-block, dot-repeat, named
   registers, `:s`, marks. Byte-indexed columns. Reads `config.vim_mode`.

Engines 1 and 3 are near-identical in structure (same `reset_pending`,
`eff_count`, motion table, `text_object`, PAIRS/QUOTES, `do_operator` a_first
logic, the cw quirk, `apply_object`). They differ only in the buffer substrate
they mutate. Engine 2 is a stub over the same shape as engine 1.

`lua/vimmode.lua` is already the one shared off/on/mandatory setting. Only the
grammar is duplicated.

## The shape of the fix

Promote the clean engine (`lua/tui/vim.lua`) to `lua/vim.lua` and rewrite it
against a **buffer adapter**: the minimal set of operations the grammar needs.
The state machine, motions, operators, text objects, search and ex-lite run
against the adapter, so the SAME grammar runs on any surface that implements it.
Three adapters (TUI composer, studio composer, DocView) sit between the grammar
and each surface's real buffer.

The one design move that makes byte-vs-codepoint indexing disappear: the core
never does column arithmetic (`x + 1`) on raw line strings. It walks positions
through `next_pos`/`prev_pos` and reads through `get_char`. Each adapter owns its
own indexing convention behind those calls, exactly as engine 3 already does via
`translate.next_char`/`position_offset`.

## 1. The shared core: the buffer-adapter interface

`lua/vim.lua` calls only these adapter methods. An adapter is a table `a` bound
to one surface's buffer.

Reading:
- `a:line_count()` -- number of lines.
- `a:get_line(y)` -- raw line string, no trailing newline.
- `a:line_len(y)` -- position count in line y (units are the adapter's own).
- `a:first_nonblank(y)` -- column of first non-blank, or 1.
- `a:get_char(y, x)` -- one character at (y,x) as a string; "" at/after EOL.
- `a:next_pos(y, x)` -- one position forward, crossing line breaks; nil at EOF.
- `a:prev_pos(y, x)` -- one position back; nil at BOF.
- `a:get_text(y1, x1, y2, x2)` -- text in the half-open range [start, end).

Cursor and mode:
- `a:get_cursor()` -- returns y, x.
- `a:set_cursor(y, x)`.
- `a:clamp_caret()` -- keep the caret on a boundary, tight in normal/visual.
- `a:mode()` -- "normal" | "insert" | "visual" | "vline" | "vblock".
- `a:set_mode(m)`.
- `a:set_selection(ay, ax, cy, cx)` -- visual anchor..caret; may no-op.
- `a:clear_selection()` -- may no-op.

Mutation (all ranges half-open [start, end)):
- `a:delete_range(y1, x1, y2, x2)`.
- `a:insert_at(y, x, text)` -- text may contain "\n".
- `a:set_lines(y1, y2, list)` -- replace whole lines y1..y2 with list; the
  linewise primitive. A single-line replace is `set_lines(y, y, {s})`.

Undo and registers:
- `a:begin_undo()` / `a:end_undo()` -- bracket one command as one undoable unit.
- `a:undo()` / `a:redo()` -- drive `u` and Ctrl-R (surface owns the stack).
- `a:get_register(name)` -- returns text, linewise. name nil is the unnamed reg.
- `a:set_register(name, text, linewise)`.

Optional overrides (core supplies a default; a surface may replace):
- `a:motion(name, count, y, x, hadcount)` -- returns y, x, kind or nil. Lets
  DocView supply display-line-aware j/k, `%`, block motions from `translate.*`;
  the composers omit it and get the core's logical-line versions.
- `a:on_command_done()` -- fired when the grammar returns to idle normal mode.
  The hook DocView uses to commit dot-repeat and fan an edit to extra cursors.

Everything else the current `tui/vim.lua` does (the `_vs` pending state, counts,
the grammar dispatcher, the `:`/`/`/`?` prompt buffer) stays in the core and is
surface-independent.

## 2. The three adapters

### TUI composer (`lua/tui/input.lua`)

The current buffer already is `{lines, cy, cx, edit_mode}` with codepoint
columns. The adapter is thin:
- `next_pos`/`prev_pos`/`get_char` reuse the codepoint helpers already exported
  from `input.lua` (`cp_at`, `ulen`).
- `delete_range`/`insert_at`/`set_lines` are the current `remove_range` /
  paste-splice / `op_linewise` line-array edits, lifted out of the core into the
  adapter unchanged.
- `begin_undo` pushes a snapshot; `end_undo` is a no-op; `undo`/`redo` are the
  current `_undo`/`_redo` snapshot stacks.
- `get_register`/`set_register` are the module-level unnamed register.
- No `set_selection` highlight (the mode chip and amber caret carry visual);
  it no-ops, selection anchor lives in core `_vs`.

Net effect: behaviour identical to today, code moved behind the interface.

### Studio composer (`agentview.lua`)

Same `{lines, cy, cx, edit_mode}` shape, but columns are BYTE offsets and the
helpers are `prev_char`/`next_char` (byte walkers already present). The adapter:
- `next_pos`/`prev_pos` wrap `next_char`/`prev_char` plus line crossing;
  `get_char` slices one character; `line_len`/`first_nonblank` from the line.
- `delete_range`/`insert_at`/`set_lines` replace the ad-hoc splices in
  `on_text_input`/paste/`delete_composer_selection`.
- `begin_undo`/`undo`/`redo`: a snapshot stack like the TUI's (the composer has
  no doc undo today; add one).
- `set_selection` maps onto the existing `sel_anchor` so the composer's own
  highlight and copy/cut keep working; visual mode reuses it.
- `set_register`/`get_register` mirror to the system clipboard, matching engine 3.

Net effect: the studio chat composer gains the full grammar (operators, visual,
d/c/y, text objects, search) that it lacks today, and the hand-rolled modal
branch is deleted.

### Studio DocView (`studio/data/core/vim.lua`)

The hard one. The adapter wraps `Doc`/`DocView`:
- `get_cursor`/`set_cursor` are `doc:get_selection`/`doc:set_selection`.
- `next_pos`/`prev_pos` wrap `translate.next_char`/`previous_char` and
  `doc:position_offset`; `get_char` is `doc:get_char`; columns stay byte offsets.
- `delete_range`/`insert_at`/`get_text`/`set_lines` map onto
  `doc:remove`/`doc:insert`/`doc:get_text`/`remove_lines`+`insert`.
- `set_selection` is native `doc:set_selection(cy,cx, ay,ax)` -- the real
  selection highlight, unchanged.
- `mode`/`set_mode` are `dv.vim.mode`.

Three honest problems and their answers:

**Multi-cursor.** The core stays single-cursor. Extra carets remain a
DocView-adapter concern, implemented exactly as today: record the command's
keystrokes, replay them at each extra caret bottom-to-top (`fan_to_cursors`).
The `on_command_done` hook is where the adapter commits the recording and fans
it out. The core drives the primary caret and knows nothing about N cursors.
Recommendation: **adapter fan-out, not core N-cursor support** -- it reuses one
code path for dot-repeat and multi-cursor and keeps the grammar simple.

**Real doc undo vs snapshot undo.** `begin_undo`/`end_undo` bracket one vim
command; the DocView adapter maps them to a doc undo-group boundary so `dd` is
one `u`, and `undo`/`redo` delegate to `doc:undo`/`doc:redo`. The composers keep
snapshot stacks behind the same two calls. The core never sees the difference.

**DocView already has motions.** It does, and better ones (display-line j/k,
`%`, `{`/`}` over blocks). The adapter supplies `a:motion` to override those
names from `translate.*`/`DocView.translate.*`; the core's own word/char/search
motions run unchanged on the adapter for everything the override does not claim.

DocView-only features that stay in the adapter as extensions, not in the core:
visual-block, dot-repeat, named registers, `:s` and the ex parser, marks. They
compose with the shared grammar; they do not belong in a composer.

## 3. Migration

Recommendation: promote `lua/tui/vim.lua` to `lua/vim.lua` and generalise it
behind the adapter. It is the cleanest of the three and already surface-agnostic
in spirit. Retire engine 2 outright; fold engine 3's editor features onto the
shared grammar as adapter extensions.

Phase each step so it ships alone and nothing in daily use breaks.

- **P0 -- extract, no behaviour change.** Move the codepoint/position helpers and
  the buffer primitives out of `tui/vim.lua` into a TUI adapter; the engine now
  calls the adapter but is otherwise byte-for-byte the same. cTUI unchanged.
- **P1 -- promote.** Rename to `lua/vim.lua`, define the adapter interface,
  point the cTUI at it through the TUI adapter. Ships; cTUI behaviour identical.
- **P2 -- studio composer.** Write the composer adapter over `agentview`'s
  `{lines, cy, cx}`; route `on_text_input`/`on_key_pressed` through `lua/vim.lua`;
  delete the inline modal branch. The composer gains the full grammar. Ships.
- **P3 -- DocView.** Write the DocView adapter; move engine 3's grammar onto
  `lua/vim.lua`; keep its editor-only features (multi-cursor, visual-block,
  dot-repeat, `:s`, named regs, marks) as adapter extensions and `a:motion`
  overrides. Delete the duplicated grammar. Ships last, lowest surface churn per
  step. This is the risky phase; see below.
- **P4 -- config.** Retire `config.vim_mode`; every surface reads `vimmode`.

Composers before DocView because they share a buffer model with the core, so the
adapter is trivial and the grammar drops in with almost no bridging. DocView last
because its substrate, undo and multi-cursor need the most bridging.

## 4. Config

Everything reads `lua/vimmode.lua`. `config.vim_mode` is retired; engine 3's
`M.enabled = config.vim_mode == true`, `:set vim/novim`, and `vim:toggle` all
route through `vimmode.enabled()` / `vimmode.set(...)`, which already emits
`vimmode:changed` for live reaction (both surfaces already subscribe).

Per-surface mapping of the three modes:
- **off** -- no modal state reachable. Composers are plain insert-only. DocView
  is the native modeless lite editor (`is_text_input` always true). The adapter
  is not even attached.
- **on** -- modal available, opens in insert. Esc enters normal; i/a/o/c/: (or a
  click, or send) return to insert. `starts_normal()` is false.
- **mandatory** -- opens in normal (`starts_normal()` true) and the UI cannot
  turn it off, per the existing `cycle()` asymmetry.

One setting, one policy, every surface.

## 5. Keymap and eventing

The core consumes ONE normalized event shape:

```
{ type = "key", key = <name>, char = <utf8 string | nil>,
  shift = bool, alt = bool, ctrl = bool }
```

`key` is a normalized name: `"char"`, `"esc"`, `"enter"`, `"backspace"`,
`"delete"`, `"tab"`, `"ctrl"`, `"up"`, `"down"`, ... . `M.key(adapter, ev)`
returns `(handled, action)`; `action` is only ever `"submit"` (from `:w`/`:wq`).
This is already the cTUI's shape, so it is the target.

Thin per-surface translation into that shape:
- **cTUI** -- already emits it; pass through (the current `tui/input.lua` path).
- **studio composer** -- `on_key_pressed` gives lite names (`"shift+left"`,
  `"ctrl+c"`, `"escape"`, `"return"`); `on_text_input` gives printable text. A
  small translator splits modifiers, maps `return`->`enter`, and wraps printable
  text as `{key="char", char=text}`.
- **DocView** -- keep the existing two-mechanism trick as the translator:
  printable text arrives through the wrapped `DocView:on_text_input` as
  `{key="char", char=text}`; the handful of special keys (esc, backspace, delete,
  return, tab, ctrl-r/d/u/v/n) arrive through the keymap-prepended `vim:*`
  commands, each synthesizing its core event. Nothing about that plumbing
  changes; only the engine it feeds does.

## 6. What stays per-surface (and why that is fine)

The valuable shared thing is the grammar. Pixels and host-widget glue are not
shared, and should not be:
- Rendering the buffer -- cTUI cell-grid runs, the composer's markdown/token
  rows, DocView's glyph draw.
- Caret shape and blink -- block vs bar (`core.vim_caret`), the composer's blink
  bar, the cTUI amber caret.
- Selection highlight painting and the mode/status chip.
- The `:`/`/` command line UI -- cTUI `overlay_runs` vs lite `CommandView`.
- The undo substrate itself -- snapshot stack vs `doc:undo` (abstracted by
  `begin_undo`/`undo`, but implemented per surface).
- Scroll/viewport, history, completion, voice, clipboard.

These are per-surface because they are about a specific widget's screen and API,
not about what `d i w` means. The grammar is the same on all three; the paint is
not, and forcing shared paint would only couple three unrelated renderers.

## 7. Build order (each shippable, lowest-risk first)

1. P0 extract helpers + primitives behind a TUI adapter (no behaviour change).
2. P1 promote to `lua/vim.lua`, define the interface, cTUI through the adapter.
3. P2 studio composer adapter; delete the inline modal stub; composer gains grammar.
4. P4 config: retire `config.vim_mode`, read `vimmode` everywhere.
5. P3 DocView adapter; fold engine 3's grammar in, keep its editor features.

(P4 pulled before P3: the config switch is independent and small, so DocView
lands last and alone.)

## 8. Non-goals

- Not rewriting lite's `Doc` or its undo.
- Not unifying rendering, caret drawing or selection highlight.
- Not adding new vim features during the merge -- feature parity only; behaviour
  changes land as separate later work.
- Not changing `vimmode` policy semantics (off/on/mandatory stay as they are).
- Not merging the composer's approval "mode" with the edit mode -- they share a
  word and nothing else.
- Not sharing history, completion, voice or clipboard between surfaces.
- Not giving the composers multiple simultaneous cursors; multi-cursor,
  dot-repeat and macros stay DocView-only.

## The single biggest risk

Folding DocView on. The core is written as the **sole mutator of a single-caret
buffer with snapshot undo**; DocView is a live, multi-cursor, real-undo,
syntax-highlighted document whose every edit also fires events (marks, dirty
reload, the tokenizer). The grammar drives edits through fine-grained
`delete_range`/`insert_at`, and each vim command must still collapse into exactly
one undoable, event-consistent transaction -- and then replay atomically at N
extra cursors. Getting that undo-atomicity + multi-cursor fan-out to match what
users rely on today, when the edits now come from a shared core instead of engine
3's bespoke paths, is where it will silently diverge (`u` undoing half a command,
or a fan replay desyncing). Everything else -- byte vs codepoint indexing, richer
motions -- is cleanly contained by the adapter; this is not.
