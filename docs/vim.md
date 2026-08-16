# Modal editing — the good bits of neovim, in the studio editor

`boggart-studio`'s code editor has an optional **neovim-style modal layer**
(`studio/data/core/vim.lua`). It is a layer *over* the existing lite-xl editing
engine, not a rewrite: it reuses the motions in `core.doc.translate`, the
`Doc` selection API, the `doc:*` command family, and `core.doc.search`. The
core `Doc` is untouched — everything below is contained in `vim.lua` plus a few
lines of wiring, and none of it changes behaviour when modal editing is off.

## Turning it on

Off by default. Turn it on any of three ways (no restart needed — the module
always loads, it just stays dormant until enabled):

- `config.vim_mode = true` in your user config, or
- the `vim:toggle` command, or
- `:set vim` (and `:set novim` to turn it back off) from the command line.

The current mode shows as a chip in the status bar (`NORMAL`, `INSERT`,
`VISUAL`, `V-LINE`, `V-BLOCK`), the caret is a **steady block** in normal/visual
modes and a **blinking bar** in insert.

## How it hooks in (why it doesn't fork the core)

Two mechanisms carry the whole feature:

1. **Characters** arrive through `DocView:on_text_input`, which the module
   wraps. In any mode but insert the character is swallowed and fed to the
   grammar, so the *actual glyph* — `$`, `%`, `}` — reaches the parser
   regardless of keyboard layout. Insert mode falls through to normal typing.
2. **Non-printable keys** that are bound to destructive doc commands
   (`backspace`, `delete`, `return`, `tab`, and `ctrl+v`/`ctrl+n`/`ctrl+r`/
   `ctrl+d`/`ctrl+u`) get vim commands **prepended** in the keymap, gated to
   non-insert mode. In normal mode they move/act; in insert mode (or with vim
   off) the predicate fails and they fall through to their original binding.

State lives on each real `DocView` as `dv.vim`. `CommandView` extends `DocView`
but is deliberately excluded (a metatable check), so `:` and `/` still type.

## What works

**Modes.** normal, insert (`i a I A o O`), visual (`v`), visual-line (`V`),
visual-block (`Ctrl-V`). `Esc` always returns toward normal.

**Motions** (usable on their own and as operator targets), with counts:
`h j k l w W b B e E 0 ^ $ { } gg G f F t T ; , %`, `Ctrl-D`/`Ctrl-U` half-page.
Grammar is the usual `{count}{operator}{count}{motion|text-object}` — `2d3w`
deletes six words.

**Operators:** `d c y > <` (and doubled `dd cc yy >> <<`), plus the direct
verbs `x X D C s S r ~ J p P u` and `Ctrl-R` (redo). Ranges bridge vim's
inclusive/linewise semantics onto the engine's exclusive-end edits.

**Text objects** after an operator or in visual mode: `iw aw`, `i( a(` (`ib`),
`i{ a{` (`iB`), `i[ a[`, `i" a"`, `i' a'`, `` i` a` ``, `ip ap`.

**Registers.** The unnamed register (synced to the system clipboard for
charwise yanks) plus named registers via the `"a`…`"z` prefix.

**Dot-repeat.** `.` replays the last buffer-changing command. It works by
recording the *keystrokes* of a change (including typed insert text and the
terminating `Esc`) and replaying them — one path serves both "repeat the last
change" and multi-cursor fan-out.

**Ex commands** (`:`) — parsed by the pure, unit-tested `M.parse_ex`:
ranges (`%`, `.`, `$`, `N`, `a,b`); `w q wq x q!`; `:s/pat/rep/[g]` (Lua
patterns, per line, with a range); line ops `d y m t`; `noh`; `:set vim`; and a
bare number or range as a jump.

**Search:** `/` and `?` (with `n`/`N` to repeat), `*`/`#` for the word under the
caret.

## Multi-line "magic": visual-block and multi-cursor

Both are **additive** — the `Doc` keeps its single selection; `vim.lua` tracks
the extra structure and fans edits across it.

- **Visual-block** (`Ctrl-V`): a rectangular region. Motions move the caret
  corner; `d`/`x`/`y`/`c` act on the column span of every line; `I` inserts at
  the block's left column and `A` appends at its right — the text you type on
  the top line is **replicated down every line** of the block on `Esc`.
- **Multi-cursor**: `Ctrl-N` adds the next occurrence of the word under the
  caret as an extra caret (repeat to collect more; the count shows in the status
  bar). Type one change at the primary caret and it is **fanned to every other
  cursor** (bottom-to-top, so edits never invalidate a not-yet-visited caret) by
  replaying the recorded change. `Esc` clears the extra cursors.

## Verification

`tests/vim.lua` drives the real grammar against a real `Doc` + `DocView`
headlessly (it stubs the handful of window globals the doc/view chain reads),
feeding keystrokes and asserting the buffer. It covers motions, operators,
visual modes, insert entry, counts, `parse_ex` + `:` execution, search, text
objects, registers, dot-repeat, visual-block (`d/y/c/I/A`) and multi-cursor
fan-out. Run it with `ctest --test-dir build -R '^vim$'` (or
`boggart --eval tests/vim.lua`). The rendered-frame `ninja -C build ui-check`
confirms the caret/status/overlay wiring against a live layout.
