# Studio steals: what we take from the LLM Station editor

Status: plan of record (2026-09-05). Tracker: BSTUD-55 subtree (+ BSTAT-21/30/31
for the AI-flow items). Source survey: llm-station `src/editor_app` (~91k LOC,
NED fork, ImGui); gap analysis: boggart-studio `data/core` + `data/plugins`.

## The rule

We steal **algorithms, data structures, and interaction design** — never the
rendering. The NED fork draws one call per character with a 16-byte color per
file byte; studio's dirty-rect rencache + per-line token runs are strictly
better. Every port lands as idiomatic studio Lua: a plugin or a `core/` module,
a `command.add` + `keymap.add` next to it, and a row in `shell/registry.lua`
so ui-discover passes.

## What the gap analysis changed

- **Cmd+K already exists** (`plugins/inline_edit.lua`, 105 lines): selection or
  current line → command-view prompt → streamed edit → span re-verified →
  applied with `marks.from_edit` for post-hoc accept/revert. The only NED thing
  worth taking is the *pre-accept* diff preview. Big scope cut.
- **@-mentions already exist** (`lua/mention.lua` shared with the TUI +
  `agentcomplete`). The gap is NED's kind classification (`@problems`,
  `@code:`, `@docs:`, `@git:`, `@folder:`, `@url:`) and station-backed
  resolvers, not the parser.
- **The `marks` system is a decoration engine we already own** (Neovim-extmark
  style: line wash, gutter signs, virtual text, floating buttons with
  hit-testing). Merge-conflict UI and a git gutter are thin layers over it,
  not features to build.
- **Smooth scroll / ensure-visible: already have**, full stop. Dropped.
- **A display-row indirection already exists** as the soft-wrap cache
  (`docview.lua:103-207`). Folding is a *unification* of two existing draw
  paths, not a new mechanism.

## Wave 1 — quick wins (independent, each ships alone)

Cheap because the substrate exists. Any order; all parallelizable.

1. **Git gutter + inline blame** (BSTUD-64, new — was an honorable mention,
   promoted because it's nearly free). Recipe: `git show HEAD:path` via
   `system.exec` on a `core.add_thread` coroutine (never sync — see
   libraryview's warning), then literally `marks.from_edit(doc, head_text,
   current_text)` — the exact call `inline_edit.lua` already makes — for
   changed-line tint + gutter signs. Blame: parse `git blame --line-porcelain`
   into a dense per-line array (NED's hunk→dense expansion), draw
   `// author · date` as marks virtual text on the caret line only, toggled
   from the menu.
2. **Merge-conflict CodeLens** (BSTUD-58). Detector scans `doc.lines` for
   `^<<<<<<<`/`^=======`/`^>>>>>>>` (NED's rule: exactly 7 marker chars then
   EOL/whitespace, so `========` walls don't false-positive; FNV change gate
   optional — `doc:get_change_id()` is our cheaper equivalent). One mark group
   per region: side washes (`kind` colors exist), dimmed marker lines, and
   accept-current/incoming/both buttons via the existing `draw_line_marks` +
   `mark_hits` machinery. Steal NED's two subtleties verbatim: byte-span
   accept built from the *original* buffer, and the deferred-mutation loop
   (at most one accept per frame; apply after iteration because accepting
   resizes the region list). Wrap each accept in the undo boundary from
   BSTUD-57.
3. **Minimap** (BSTUD-59). One `renderer.draw_rect` per line, width ≈ char
   count, `per_line_h = clamp(strip_h/lines, 0.75, 2.5)`, blank lines get a
   stub so the silhouette breathes; translucent viewport overlay;
   click-to-scroll via `scroll_to_line`. The core even pre-built the hook:
   `Highlighter:update_notify(line, n)` exists solely for this. ~150 lines of
   plugin. No glyphs, no syntax color — the silhouette is 90% of the value.
4. **Bookmarks** (BSTUD-61). 9 slots of `{file, line, col, scroll_y}`;
   set `cmd+shift+1..9`, jump `cmd+1..9`, `cmd+b` list via `menu.show`.
   Cross-file: `core.open_doc` → apply selection + scroll after the open (the
   NED trick: scroll in the load path, not before). Pure plugin.
5. **Frame pacing** (BSTUD-60). Studio already blocks in
   `SDL_WaitEventTimeout`; take NED's *policy*: tiered timeouts (short while
   `View:move_towards` animates, ~16ms within 0.5s of input, long idle) and a
   `core.frames_to_render = max(n, k)` counter consumed by `core.step` so
   discrete events (keybind fired, font reload, theme switch) get a few
   settled frames without each animation hand-cranking `core.redraw`. Also
   fix the existing inversion: focused cap is 0.4s but unfocused is 0.25s —
   the unfocused window currently wakes *more* often, contradicting its own
   comment (`init.lua:1041`).

## Wave 2 — substrate (small, but other work stands on it)

6. **Token color-override hook** (BSTUD-65, new). `draw_line_text`
   (`docview.lua:537-545`) colors straight from `style.syntax[type]` with no
   per-span override. Add one: a per-view list of `{line, col1, col2, color}`
   spans honored by both draw loops — `draw_wrapped_text` (:697-712) already
   demonstrates clipping a token run to a byte interval and advancing x
   correctly, so it's the template. This is what ghost text (BSTAT-21),
   conflict marker dimming, and any future semantic overlay draw through.
7. **Undo boundaries** (BSTUD-57, re-scoped). Studio's undo is lite's
   inverse-command stack with time-merge at pop (`undo_merge_timeout = 0.3`).
   Do **not** rewrite it to NED's op format — `get_change_id()` (= stack idx)
   is load-bearing for the wrap cache and autocomplete, and `raw_insert`/
   `raw_remove` also drive marks and highlighter invalidation. What we
   actually need from NED is the *boundary* concept: `doc:commit_undo()`
   that breaks the time-merge chain so a structural edit (conflict accept,
   Cmd+K apply, find-all replace) is exactly one undo step. Implement as a
   sentinel entry or a timestamp bump; ~20 lines. NED's prefix/suffix-diff op
   format stays on file as a someday note, nothing more.
8. **Doc edit events** (folded into BSTUD-56/63 as needed). There is no
   observer on edits; `doc/init.lua:291-341` (`raw_insert`/`raw_remove`) is
   the single chokepoint everything passes through. Folding invalidation,
   diagnostic span shifting, and ghost-text cancel each hook there — added
   with the first feature that needs it, kept to the marks/highlighter
   pattern (direct calls, no event bus).

## Wave 3 — the structural ones

9. **Folding** (BSTUD-56). The big one, but it's a unification: promote the
   soft-wrap `wrap.rows` cache into a general display-row table (a row is a
   line slice or a collapsed fold), make the six wrap/non-wrap branch pairs
   (`draw`, `get_line_screen_position`, `get_visible_line_range`,
   `resolve_screen_position`, `scroll_to_make_visible`,
   `get_scrollable_size`) iterate display rows unconditionally, and delete
   the non-wrapping branch. Reuse `wrap.rev = doc:get_change_id()`
   invalidation. Then NED's detection ports directly: bracket-stack scan for
   brace languages, indent scan otherwise, collapsed-state preserved across
   rescan by snapshotting collapsed start-lines. Fold triangles in
   `draw_line_gutter` with `mark_hits`-style click rects. This also
   *simplifies* docview — one draw path instead of two.
10. **Diagnostics squiggles** (BSTUD-63). Gutter dots already exist
    (`draw_line_gutter` + `marks.color`). Squiggles: marks are line-anchored,
    so column ranges ride in `m.data = {col1, col2}`; draw in
    `draw_line_body` after `draw_line_text` using `get_col_x_offset` for
    endpoints and NED's zigzag (alternating y ±2px in 4px steps) via
    `renderer.draw_line`. Consumer arrives later (station `lsp_query
    format=json` over ZMQ, BSTAT-14); this ticket is the rendering + model.
11. **Find-all → multi-cursor** (BSTUD-62, re-scoped). Doc is
    single-selection and this fork deliberately kept it that way; the vim
    layer already has additive cursors with bottom-to-top edit replay. Do
    **not** widen Doc into a selections list (touches every command). Extend
    the vim model instead: per-cursor preferred columns (today one shared
    `last_x_offset`), and a find-all seeder — Ctrl+Enter in find spawns a
    cursor at every match (`search.find` loop → `dv.vim.cursors`), the NED
    interaction that makes multi-cursor pay for itself. Works in vim mode
    first; a non-vim entry point can alias into the same machinery.

## AI-flow items (tracked in BSTAT, listed for completeness)

- **Ghost text** (BSTAT-21): real-bytes + ghost-color representation, on top
  of BSTUD-65's color-override hook; protocol logic (debounce, prefix guard,
  staleness) from station's unwired EditorProtocol.
- **Cmd+K preview** (BSTAT-30, re-scoped down): keep `inline_edit.lua` as-is;
  add the pre-accept diff preview (prefix/suffix line diff — NED's
  deliberately-not-Myers `InlineDiff`, ~40 lines — rendered via marks or
  ReviewView) between response and apply, plus `stripCodeFences` hardening
  and the >400-line-preview refusal from `guiApplyEditToOpenBuffer`.
- **Mention kinds** (BSTAT-31, re-scoped down): extend `lua/mention.lua` with
  NED's kind prefixes (`@problems`, `@terminal`, `@code:`, `@docs:`,
  `@folder:`, `@url:`, `@git:`) and its conservative preceded-by rule;
  resolvers hit station over ZMQ when up, native tiers when down. The
  "expansion rides the payload, not the bubble" contract already holds.

## Explicitly not taken

- The render layer (per-char draw, ImVec4-per-byte colors) — anti-pattern here.
- The shader/CRT stack — studio has its own rendering identity.
- NED's LSP client and its in-editor completion popup — station over ZMQ is
  our LSP story (BSTAT), and `autocomplete.add{}` is our popup.
- Doc-level multi-selection rewrite — vim-additive extension instead.
- Undo op-format rewrite — boundary commit only.
- The embeddable-editor pane, terminal port — studio has both natively.

## Acceptance, per wave

Every landed item: command palette entries, keymap defaults declared beside
the commands, a `shell/registry.lua` row (ui-discover), a `config.*` opt-out
flag following the `config.line_wrap` convention, and no regression in
ui-check/ui-bench. Wave 3 items add: folding round-trips with soft-wrap on
and off; multi-cursor replay passes the vim dot-repeat tests.
