# A vim-style editor for the cTUI

`boggart --tui` (the full-screen chat, `lua/tui.lua`) gets an optional
**neovim-style modal layer** over its composer, and over a new scratch/file
buffer the cTUI gains along the way. It is a layer, not a rewrite: it reuses the
composer's existing caret and edit primitives (`lua/tui/input.lua`), the cTUI's
event model (`tc.poll`, see `docs/ctui-spec.md` Contract A), and the same mode
vocabulary the studio already uses (`studio/data/core/agentview.lua`,
`studio/data/core/vim.lua`). Off by default; when off the composer behaves
exactly as it does today.

The rule that governs every decision here: **type a message and press Enter must
never break.** Vim is opt-in, the composer opens in insert mode, and Enter sends
in every mode. A user who never presses `Esc` never meets a mode.

## 1. Scope and goal

"Full vim-style editor experience" means the composer is a modal text field with
the motions, operators, text objects, and search a vim user reaches for without
thinking -- not a re-implementation of vim. Two surfaces:

- **The composer** (`lua/tui/input.lua`). The primary target. Short buffers, but
  the place fingers live.
- **A scratch/file buffer** (new, `lua/tui/edit.lua`). The cTUI cannot open a
  file today; `edit_in_editor` shells out to `$VISUAL`. A modal in-process
  editor makes the terminal a real editor for a prompt draft, a pasted diff, or
  a small file, without leaving the frame. It reuses the same engine as the
  composer.

Both drive one pure module, `lua/tui/vim.lua`, over a shared buffer interface
(below). The studio's `vim.lua` is the reference for grammar and register
behaviour; this is its terminal sibling, deliberately smaller.

Out of scope entirely: a general code editor with LSP, syntax, or multiple
windows. The scratch buffer is a text box, not an IDE.

## 2. Modal model

Four modes, named to match the studio chip (`docs/vim.md`):

| mode          | field on the buffer      | shown as |
| ------------- | ------------------------ | -------- |
| insert        | `edit_mode = "insert"`   | `INSERT` |
| normal        | `edit_mode = "normal"`   | `NORMAL` |
| visual        | `edit_mode = "visual"`   | `VISUAL` |
| visual-line   | `edit_mode = "vline"`    | `V-LINE` |

This extends `agentview.lua`'s existing `self.edit_mode`, today only `"insert"`
| `"normal"`, with the two visual modes -- so a mode word means the same thing in
the studio and the cTUI. `set_edit_mode` in both surfaces takes the same enum.
Visual-block is **not** a mode here (non-goal, section 9).

**Transitions.**

- `Esc` -> normal (from any mode). On an already-normal buffer, `Esc` is a no-op
  for the vim layer and falls through to the cTUI's existing meaning (cancel a
  running turn, dismiss help).
- `i a I A o O` -> insert, at the usual places (`i` before caret, `a` after, `I`
  first non-blank, `A` end of line, `o`/`O` open line below/above).
- `v` -> visual, `V` -> visual-line. `v`/`V`/`Esc` from visual toggles back.
- `c`, `s`, `cc` and friends -> insert after the delete (section 4).

**Cursor and chip.** The cTUI draws a single block cell for the caret
(`tc.set(cx, cy, 32, nil, C.cursor, nil)` in `draw`). A thin bar caret is not
cheap in a cell grid, so mode is carried two ways instead: the block is coloured
by mode (accent in insert, amber in normal/visual) and a mode chip renders in the
status row beside the approval mode (`status_runs`). The two never collide: the
approval mode is a word like `smart`; the vim mode is the fixed chip
`NORMAL`/`INSERT`/`VISUAL`/`V-LINE`, only drawn when the vim layer is enabled.

## 3. Motions

The buffer interface the engine drives (shared by composer and scratch):

    buf.lines            -- array of strings, no embedded newlines
    buf.cy, buf.cx       -- caret line (1-based) and column (codepoint, 1-based)
    buf:clamp_caret()    -- keep cx on a boundary inside the line

This matches `agentview.lua` (`self.lines`, `self.cy`, `self.cx`,
`clamp_caret`) rather than `input.lua`'s single-string-with-`\n` model. Part of
phase 1 is refactoring `input.lua` onto the line-array buffer so the composer and
the studio speak one shape. Word classing reuses `input.lua`'s `is_word` /
`cp_at` (codepoint-indexed, UTF-8 safe).

Motions, each usable alone and as an operator target:

- **Char:** `h l`, and `0 ^ $` (line start, first non-blank, line end).
- **Vertical:** `j k`, `gg` (first line), `G` (last line, or `NG` to line N).
- **Word:** `w b e` and `W B E` (WORD = non-blank run, word = `is_word` run).
- **Find:** `f{char}` `t{char}` `F{char}` `T{char}`, with `;` / `,` to repeat.
  The target char is the next key event, held in an operator-pending state
  (section 5) -- no timeout.
- **Paragraph:** `{` `}` (blank-line boundaries). In the composer these also keep
  their existing empty-buffer meaning of jumping the transcript between user
  prompts (`jump_user`, `agentview:jump_user`) when the composer is empty and in
  normal mode -- one key, disambiguated by whether the buffer has text.

**Counts.** A leading digit run multiplies the motion: `3w`, `5j`, `12G`. `0` is
a motion (line start) only when no count is being built, exactly as vim. Counts
compose with operators as `{count}{op}{count}{motion}` (`2d3w` deletes six
words), parsed by the same grammar the studio uses.

## 4. Operators, text objects, registers

**Operators:** `d` (delete), `c` (change = delete then insert), `y` (yank).
Each takes a motion or a text object. Doubled forms act on the whole line:
`dd yy cc`. Shortcuts: `x` (delete char under caret), `D C` (to end of line),
`s` (delete char, insert), `p` / `P` (paste after / before), `r{char}` (replace
one char).

**Text objects** after an operator or in visual mode:

- `iw` `aw` -- inner / a word.
- `i"` `a"`, `i'` `a'`, `` i` `` `` a` `` -- quoted spans.
- `i(` `a(` (and `i)` `a)`, `ib`), `i{` `a{` (`iB`), `i[` `a[` -- bracket pairs.
- `ip` `ap` -- inner / a paragraph.

**Undo / redo.** `u` undoes, `Ctrl-R` redoes. The engine keeps a bounded
per-buffer undo stack of `{lines, cy, cx}` snapshots pushed before each
buffer-changing command. Snapshots, not a keystroke journal -- the composer is
short and this is simpler than the studio's replay recorder.

**Registers.** The **unnamed register** only: `{text, linewise}`, written by
`d c x y` and read by `p P`. A linewise yank (`yy`, `dd`) pastes on its own line;
a charwise yank pastes inline. Named registers (`"a`…`"z`), the numbered ring, and
the system-clipboard sync the studio has are **out of scope** for the cTUI layer
-- the composer already reaches the system clipboard through paste
(`ev.type == "paste"`) and `bog.copy_text`, and a fuller register set earns its
weight in the scratch editor later, not the prompt.

## 5. Terminal constraints

Terminals send no key-up and a thin set of chords. The engine is built for that.

**termctl cooks the events.** Unlike a raw terminal, `tc.poll`
(`docs/ctui-spec.md` Contract A) already resolves the two classic ambiguities in
C: a lone `Esc` arrives as `key = "esc"`, while `Alt`+letter arrives as
`key = "char", alt = true`, and a meta/ctrl chord as `key = "ctrl"`. So the Lua
layer never has to time an escape sequence to tell `Esc` from `Alt-j`, and
`Esc` can act **immediately** -- no `timeoutlen`. This is the single biggest
simplification the cTUI buys us over a bare terminal.

**Multi-key sequences are a state machine, not a timer.** Operator-pending
(`d` waiting for a motion), `g`-pending (`g` waiting for `g`), find-pending
(`f` waiting for its char), register/count accumulation -- all are explicit
pending state on the buffer (`op`, `gpend`, `await`, `count`, mirroring
`vstate` in the studio's `vim.lua`). Each subsequent `tc.poll` event advances or
resets the machine. Because every step is an unambiguous discrete event, none of
these needs a timeout, and there is no `dd`-vs-`d`-then-wait guesswork.

**The one place a timer stays** is push-to-talk, which genuinely infers a key
release the terminal will not report: `ptt_key` opens the mic on the first space,
auto-repeat refreshes `st.ptt_last`, and a 120ms timer treats an
`> PTT_RELEASE_MS` gap as the release. That is untouched. The vim grammar borrows
nothing from it -- the distinction is deliberate: PTT infers an event that never
arrives; the vim state machine only ever reacts to events that do.

**Chord budget.** The layer leans on printable keys (the whole grammar is
letters and punctuation, delivered as `key = "char"`) plus `Esc` and
`Ctrl-R`. It does not require any chord a terminal cannot send, and it does not
depend on Shift-arrow or Alt-motion (those remain the composer's non-modal
conveniences, live in insert mode).

## 6. Search and ex-lite

**Search.** `/{pat}<Enter>` searches forward within the buffer, `?{pat}` back,
`n` / `N` repeat in the same / opposite direction. Plain substring match
(case-insensitive) over the buffer's lines -- no regex in the composer. `*` / `#`
search the word under the caret. This is normal-mode `/`; it does not collide
with a slash **command**, because slash commands are typed in **insert** mode on
an empty line (`take.parse`, `slash` in `tui.lua`) -- `/` is only a search when
the buffer is in normal mode.

**Ex-lite.** A minimal `:` line, deliberately tiny:

- `:w` -- for the composer, **send** (write = commit the message, the same path
  as Enter). For a scratch/file buffer, save to disk.
- `:q` -- clear the composer (discard the draft); close a scratch buffer.
- `:wq` / `:x` -- send-and-clear (composer), save-and-close (scratch).
- `:{N}` -- jump to line N.
- `:set vim` / `:set novim` -- toggle the layer, matching the studio.

Everything else is **excluded on purpose**: no `:s///` substitute (use search +
change), no ranges beyond a bare line number, no `:g`, no `:e`/`:r`/`:!`, no
window or buffer ex commands. The `:` line reuses the composer's own single-row
render; it is not a second modal editor.

## 7. Integration with the cTUI

The layer must sit inside the existing send path, history, PTT, and slash
commands without disturbing them.

- **Enter vs newline.** Enter **sends in every mode** (insert, normal, visual),
  preserving "press Enter to send." `Shift-Enter` / `Alt-Enter` / `Ctrl-J`
  insert a newline as they do today (`input.lua:key`). Normal-mode Enter does
  not mean "down a line"; sending wins, because the composer's primary action is
  to send.
- **Push-to-talk and voice.** Dictation inserts at the caret as a tracked span
  (`replace_span`) and is a composing act, so opening the mic forces insert mode
  (mirroring `agentview:voice_toggle`, which calls `set_edit_mode("insert")`).
  PTT's space handling runs before the vim grammar sees the key, so hold-space
  never types in normal mode while PTT is on.
- **History.** `Up` / `Down` and `Ctrl-P` / `Ctrl-N` stay bound to history recall
  (single-line) and physical-line motion (multi-line), unchanged and available in
  every mode. Normal-mode `j` / `k` move the caret within the composer; they do
  **not** hijack history. Keeping the two on separate keys avoids the surprise of
  `k` erasing a draft.
- **Slash commands.** Unaffected: typed in insert mode, parsed by `take.parse`.
  `/` is a search only in normal mode (section 6).
- **The frame loop.** No change. The engine is pure state mutated inside the
  existing `ev.type == "key"` branch of `tui.lua`'s loops; it sets `st.dirty` and
  the scheduler paints as before. A turn in flight still reads `Esc` as abort
  (the composer is not focused for editing mid-answer beyond queuing a steer).

**Enable switch.** `config.vim_mode` (shared with the studio), the `:set vim`
line, or a `/vim` slash command. When disabled, `input.lua` runs its current
non-modal path verbatim -- the layer is never consulted.

## 8. Build order

Each phase is independently shippable and leaves the composer usable.

1. **Buffer + insert/normal + core motions.** Refactor `input.lua` onto the
   `{lines, cy, cx}` buffer; add `lua/tui/vim.lua` with normal/insert, the mode
   chip and coloured caret, `h j k l w b e 0 ^ $ gg G`, counts, and
   `i a I A o O`. Enter still sends. This alone is a usable modal composer.
2. **Operators + text objects + registers.** `d c y` with motions, `dd yy cc`,
   `x D C s r`, `iw aw i" a( ip`, the unnamed register with `p P`, and undo/redo.
3. **Visual + visual-line.** `v` / `V`, motions extend the selection (reusing
   `composer_selection` / `delete_composer_selection` from `agentview.lua` for
   vocabulary), operators act on it.
4. **Search + ex-lite.** `/ ? n N * #`, and the `:` line (`:w :q :wq :{N} :set`).
5. **Scratch/file buffer.** `lua/tui/edit.lua`: a full-screen editor pane over
   the same engine, opened by `:e`-lite or a slash command, `:w` saving to disk.
   This is where a richer register set would land if ever wanted.

Phases 1-2 match how the codebase grows: a small pure module, driven from the
existing key branch, tested headlessly (feed events, assert `buf.lines`) the way
`tests/vim.lua` drives the studio grammar.

## 9. Non-goals

Plainly not in this layer, now or as part of it:

- **Macros** (`q` record, `@` replay) and **dot-repeat** (`.`). The studio has
  them; the composer does not need them.
- **Marks** (`m`, `` ` ``, `'`) and the **jumplist**.
- **Folds**, **windows/splits/tabs**, **plugins**.
- **Full ex**: no `:s///`, `:g`, ranges beyond a line number, `:!`, or file ex
  beyond `:w`/`:q`.
- **Visual-block** and **multi-cursor**. Terminal-cheap in principle, but they
  earn their place in a real editor, not a prompt box.
- **Named / numbered registers** and clipboard-register sync (section 4).
- A general-purpose code editor: the scratch buffer is a text box, not an IDE.
</content>
</invoke>
