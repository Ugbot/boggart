# boggart TUI quality bar — the acceptance checklist

**Purpose.** Define "Claude Code quality" for boggart's terminal UI as a list of
**observable, testable** properties. Each item is phrased so a reviewer can sit
down with a terminal (and a pipe, and a resized window) and mark it pass/fail —
no taste required, no "feels nice." This is the bar the work in
[`cli-plan.md`](./cli-plan.md) builds to.

**How to read a row.** Every checklist item carries two tags:

- **Surface** — `REPL` (surface A, the scrolling REPL), `cTUI` (surface B, the
  full-screen mode), or `both`.
- **Phase** — the `cli-plan.md` deliverable that must make it pass:
  substrate (`S1` registry, `S2` `bog.complete`, `S3` `lterm.c`), REPL phases
  `A1`–`A4`, cTUI phases `B0`–`B4`.

**How to test.** Where a check is machine-verifiable, the *Verify* note gives the
literal command or key. Prefer scripted checks (`expect`, a PTY harness, golden
ANSI captures) over eyeballing; anything a human has to judge visually is
flagged **(visual)**. A capture means: run the surface under a PTY, record the
raw byte stream, assert on it.

The bar: **every `[ ]` in a phase's column must be checked before that phase is
called done.** A half-passing row is a fail.

---

## 0. Ground rules (apply to every item below)

- **G1 — No corruption, ever.** No sequence of the operations described here
  (resize, paste, Ctrl-C mid-stream, completion, scrollback) leaves the terminal
  with a stuck cursor, a wrong-colour region, a duplicated line, or a wedged
  cooked/raw mode. *Verify:* after any test in this doc, the shell prompt returns
  clean and `stty sane` is a no-op. **Surface:** both · **Phase:** S3/B0
- **G2 — The transcript is the truth.** In the REPL, scrollback contains the full
  literal transcript; nothing that mattered is painted only in a transient region
  that scrolls away or gets cleared. *Verify:* pipe a full session to a file, and
  every model/tool/user line is present. **Surface:** REPL · **Phase:** A3/A4
- **G3 — One binary, no runtime deps.** None of these behaviours require a
  library not already vendored/linked. *Verify:* `ldd`/`otool -L` on the binary
  shows no new dynamic dep for TUI features. **Surface:** both · **Phase:** all

---

## 1. Streaming output & perceived latency

- [ ] **1.1** After submitting a turn, a visible activity indicator (spinner +
  elapsed seconds) appears within **200 ms** if no model bytes have arrived yet.
  *Verify (capture):* timestamp of first spinner frame − submit time < 200 ms.
  **Surface:** both · **Phase:** A4
- [ ] **1.2** Model text is rendered **incrementally as it streams**, not buffered
  to end-of-turn. *Verify (capture):* output bytes appear on the PTY before the
  turn's stop event; token N is visible before token N+50 arrives. **Surface:**
  both · **Phase:** A4
- [ ] **1.3** The spinner/elapsed indicator **disappears the moment** real output
  begins or the turn completes — it is never left spinning next to finished text.
  *Verify (capture):* no spinner glyph on any line after the stop event.
  **Surface:** both · **Phase:** A4
- [ ] **1.4** During a long reasoning/tool phase with no visible tokens, the
  elapsed timer keeps advancing (proves "still working," not "stalled").
  *Verify (capture):* elapsed value strictly increases across frames. **Surface:**
  both · **Phase:** A4
- [ ] **1.5** Streaming never tears mid-glyph: a partially-received multi-byte
  UTF-8 sequence is not painted until complete. *Verify:* feed a stream chopped
  mid-codepoint; no replacement char (U+FFFD) appears. **Surface:** both ·
  **Phase:** A4
- [ ] **1.6** Streamed markdown/code that is still incomplete does not thrash: an
  unterminated fenced block renders as plain/pending text and is re-styled once
  the closing fence arrives, without rewriting already-scrolled lines in the
  REPL. **(visual)** **Surface:** both · **Phase:** A4
- [ ] **1.7** Ctrl-C during a stream stops the turn within one frame, prints a
  clear interrupted marker, and returns to a usable prompt — no orphaned spinner,
  no half-open ANSI style. *Verify:* send SIGINT mid-stream; prompt returns and
  `stty` state is sane. **Surface:** both · **Phase:** A4/G1

## 2. Markdown rendering

- [ ] **2.1** Headings, **bold**, *italic*, inline `code`, bullet and numbered
  lists, and blockquotes each render with a distinct visible treatment (not raw
  `#`/`*`/`` ` `` markup). **(visual)** *Verify:* a fixture doc renders with zero
  literal markup characters left for these constructs. **Surface:** both ·
  **Phase:** A4
- [ ] **2.2** Links render readably (text shown; URL shown or via OSC-8 hyperlink)
  and never dump a raw `[text](url)` blob. **(visual)** **Surface:** both ·
  **Phase:** A4
- [ ] **2.3** Tables render as aligned columns when width allows and degrade to a
  readable form (not scrambled) when narrower than the table. **(visual)**
  **Surface:** both · **Phase:** A4
- [ ] **2.4** Nested lists indent correctly and wrap continuation lines under the
  list text, not back to column 0. **(visual)** **Surface:** both · **Phase:** A4
- [ ] **2.5** Markdown that is malformed or adversarial (unbalanced emphasis, a
  10-level-deep list, a `#` with no space) renders without crashing, hanging, or
  swallowing following content. *Verify:* fuzz fixture completes and later text is
  intact. **Surface:** both · **Phase:** A4

## 3. Syntax-highlighted fenced code blocks

- [ ] **3.1** A fenced block with a language tag (```` ```python ````) is
  syntax-highlighted for that language — keywords, strings, comments, numbers in
  distinct colours. **(visual)** *Verify:* capture shows ≥3 distinct SGR colours
  inside the block. **Surface:** both · **Phase:** A4
- [ ] **3.2** A fenced block with **no** language tag renders as a visually
  distinct monospace block (background/gutter/border) but is not mis-highlighted
  as some guessed language. **(visual)** **Surface:** both · **Phase:** A4
- [ ] **3.3** An unknown/unsupported language tag degrades to the plain-block
  treatment of 3.2 — never an error, never raw fences shown. **Surface:** both ·
  **Phase:** A4
- [ ] **3.4** Code block content is never reflowed or wrapped in a way that breaks
  indentation; long lines either soft-wrap with a continuation marker or scroll
  within the block, but leading whitespace is preserved exactly. *Verify:* copy a
  captured line back; leading spaces match source. **Surface:** both · **Phase:**
  A4
- [ ] **3.5** The fence markers themselves (```` ``` ````) are not printed in the
  rendered output. *Verify (capture):* no backtick-fence lines in rendered
  transcript. **Surface:** both · **Phase:** A4

## 4. Unified-diff rendering

- [ ] **4.1** Added lines render in the add colour with a `+` gutter, removed in
  the delete colour with a `-` gutter, context lines unmarked — matching the SDL
  studio's diff vocabulary. **(visual)** *Verify (capture):* `+`/`-` lines carry
  distinct SGR from context. **Surface:** both · **Phase:** A4
- [ ] **4.2** Hunk headers (`@@ ... @@`) and file headers (`---`/`+++`) are
  visually distinct from body lines. **(visual)** **Surface:** both · **Phase:**
  A4
- [ ] **4.3** A `+`/`-` that is legitimately part of code content (not a diff
  marker) inside a non-diff code block is **not** recoloured as a diff line.
  *Verify:* a Python file with a leading `-` operator line stays code-coloured.
  **Surface:** both · **Phase:** A4
- [ ] **4.4** With colour disabled (NO_COLOR / non-tty), diffs stay legible via
  the `+`/`-` gutter alone. *Verify:* `NO_COLOR=1` capture still shows gutters.
  **Surface:** both · **Phase:** A4/§10

## 5. Tool-call & permission/approval display

- [ ] **5.1** Each tool call renders a distinct **header** naming the tool and its
  key argument (e.g. `Bash · git status`), visually separated from model prose.
  **(visual)** **Surface:** both · **Phase:** A4
- [ ] **5.2** A running tool shows an in-progress state; on completion it shows a
  clear success/failure marker. *Verify (capture):* a failing tool yields the
  error-coloured marker, a passing one the ok marker. **Surface:** both ·
  **Phase:** A4
- [ ] **5.3** Large tool output is truncated/collapsed with an explicit indication
  it was truncated (e.g. `… +N lines`), never silently cut. *Verify:* feed 10k
  lines; a truncation notice is present. **Surface:** both · **Phase:** A4
- [ ] **5.4** A permission/approval prompt (when a tool needs consent) clearly
  states **what** is being approved and **what keys** accept/deny, and blocks the
  turn until answered. *Verify:* prompt text names the action and the accept/deny
  keys. **Surface:** both · **Phase:** A4
- [ ] **5.5** The approval prompt is answerable by keystroke and its accept/deny
  outcome is reflected in the transcript (so scrollback records the decision).
  **Surface:** both · **Phase:** A4/G2
- [ ] **5.6** Declining a tool returns cleanly to the agent (course-corrects)
  without wedging the terminal or dropping the session. **Surface:** both ·
  **Phase:** A4

## 6. Slash-command palette & autocomplete

- [ ] **6.1** Typing bare `/` and pressing **Tab** offers the command list drawn
  from the **registry** (`bog.complete`), not a hardcoded C list. *Verify:*
  add a command to the Lua registry; it appears in completion with no C rebuild.
  **Surface:** both · **Phase:** S1+S2+S3 / A1
- [ ] **6.2** Each completion candidate shows a **help string** beside it. *Verify
  (capture):* the completion menu row contains the command's help text.
  **Surface:** both · **Phase:** A1
- [ ] **6.3** Argument completion is context-sensitive: `/model <Tab>` lists model
  names, `/resume <Tab>` lists sessions (id + title), `/auth <Tab>` lists
  `key|url|model`. *Verify:* each yields its documented candidate set from the
  live source. **Surface:** both · **Phase:** S2 / A1
- [ ] **6.4** A `@` token completes **filenames** via the built-in completer,
  including directory descent, with no Lua round-trip required. *Verify:*
  `@src/<Tab>` lists files under `src/`. **Surface:** both · **Phase:** S3 / A1
- [ ] **6.5** An **unknown** `/command` is shown in the **error colour before
  Enter** — the highlighter flags it during editing, not after submit. *Verify
  (capture):* typing `/nope` recolours the token to the error SGR while the
  cursor is still on the line. **Surface:** both · **Phase:** A2
- [ ] **6.6** A **known** `/command` (and its `@file`/args) is shown in its
  command/arg colour while typing. **(visual)** **Surface:** both · **Phase:** A2
- [ ] **6.7** A dim **inline hint** of the next expected argument appears after a
  valid command with a trailing space. **(visual)** *Verify (capture):* `/model `
  shows a dimmed hint token. **Surface:** both · **Phase:** A2
- [ ] **6.8** Tab with a single candidate completes it inline; Tab with multiple
  shows the menu and cycles/filters as you type. **Surface:** both · **Phase:** A1
- [ ] **6.9** `/help` content is generated from the same registry as completion —
  a command present in one is present in the other. *Verify:* diff `/help` command
  names against completion candidates; sets are equal. **Surface:** both ·
  **Phase:** S1
- [ ] **6.10** Completion never blocks the input loop perceptibly: even if the Lua
  completer is slow, keystrokes are not dropped and the menu appears within one
  frame or not at all. **Surface:** both · **Phase:** S3

## 7. Persistent status line

- [ ] **7.1** A status row is present showing **model · local/remote · ctx% · N
  agents**, sourced from `bog.api.status()`. *Verify (capture):* the row contains
  all four fields. **Surface:** both · **Phase:** A3
- [ ] **7.2** In the REPL the status line is painted **without disturbing
  scrollback** — it does not appear duplicated in piped output and does not push
  transcript lines. *Verify:* pipe session to file; status row is absent or
  appears exactly once as designed, and no transcript line is lost. **Surface:**
  REPL · **Phase:** A3/G2
- [ ] **7.3** Context % updates as the conversation grows. *Verify (capture):* ctx%
  value changes across successive turns. **Surface:** both · **Phase:** A3
- [ ] **7.4** When a turn will hit a **remote/paid** endpoint, the status line
  shows the **amber remote-spend flag** used by the studio bar. **(visual)**
  *Verify (capture):* remote turn shows the amber SGR on the local/remote field.
  **Surface:** both · **Phase:** A3
- [ ] **7.5** The status line reflects **model switches** immediately after
  `/model`. *Verify:* run `/model X`; next status paint shows X. **Surface:** both
  · **Phase:** A3
- [ ] **7.6** The status line survives resize (see §9) and stays pinned to the
  bottom row; it never overlaps the input line or transcript. **(visual)**
  **Surface:** both · **Phase:** A3/B1

## 8. Input affordances

- [ ] **8.1** Up/Down arrows walk **command history**; history persists across
  sessions. *Verify:* submit a line, restart, Up recalls it. **Surface:** both ·
  **Phase:** S3
- [ ] **8.2** **Ctrl-R** opens reverse-incremental history search; typing narrows,
  Enter accepts, Ctrl-C/Esc cancels back to the prior line. *Verify:* Ctrl-R + a
  substring recalls the matching command. **Surface:** both · **Phase:** S3
- [ ] **8.3** **Multiline** input is supported: a continued line (trailing
  backslash, or an unbalanced brace/fence, per design) keeps editing on a new row
  rather than submitting. *Verify:* an unterminated fence does not submit on
  Enter. **Surface:** both · **Phase:** S3
- [ ] **8.4** Standard control keys work: Ctrl-A/E (line start/end), Ctrl-K/U
  (kill to end/start), Ctrl-W (delete word), Ctrl-L (clear/redraw), Ctrl-D on an
  empty line exits. *Verify:* each key has its documented effect. **Surface:**
  both · **Phase:** S3
- [ ] **8.5** **Bracketed paste**: a multi-line paste is inserted as literal text
  in one edit, not executed line-by-line, and newlines in the paste do not
  auto-submit. *Verify:* paste a 5-line block; it lands as one editable buffer.
  **Surface:** both · **Phase:** S3
- [ ] **8.6** A very long paste (e.g. 5 000 chars) does not corrupt the line
  editor or the status line. *Verify:* paste, then edit; line stays consistent.
  **Surface:** both · **Phase:** S3/G1
- [ ] **8.7** Brace/bracket **match highlighting** is shown while editing.
  **(visual)** **Surface:** both · **Phase:** S3
- [ ] **8.8** Wide/CJK and emoji characters in the input advance the cursor by the
  correct cell width; backspace deletes one grapheme. **(visual)** **Surface:**
  both · **Phase:** S3

## 9. Responsiveness, resize & reflow

- [ ] **9.1** A terminal **resize reflows the current view within one frame** —
  input line, status line, and (in cTUI) panes redraw to the new width/height with
  no leftover artifacts. *Verify:* send SIGWINCH; next paint is clean at new size.
  **Surface:** both · **Phase:** A3 (REPL bars) / B1 (cTUI)
- [ ] **9.2** After resize, the cursor is at the correct position and the input
  buffer content is intact. *Verify:* type text, resize, keep typing — text is
  continuous and correctly placed. **Surface:** both · **Phase:** S3/B1
- [ ] **9.3** Shrinking below a minimum sane width/height does not crash or
  infinite-loop; content clips or the app shows a "terminal too small" state.
  *Verify:* resize to 20×5; app stays alive. **Surface:** cTUI · **Phase:** B1
- [ ] **9.4** Keystroke-to-echo latency stays under one frame (~16–33 ms) under
  normal load; input never visibly lags behind typing. **(visual)** **Surface:**
  both · **Phase:** S3
- [ ] **9.5 (cTUI)** The full-screen renderer is **double-buffered**: only changed
  cells are emitted per frame; a static screen produces near-zero output bytes.
  *Verify (capture):* an idle frame writes no cell updates. **Surface:** cTUI ·
  **Phase:** B0
- [ ] **9.6 (cTUI)** The cTUI paints **one frame per scheduler iteration** and
  never runs its own blocking input loop — an in-flight agent HTTP call does not
  stall the paint, and the paint does not stall the agent. *Verify:* start a long
  agent turn; panes still animate/update each scheduler tick. **Surface:** cTUI ·
  **Phase:** B3
- [ ] **9.7 (cTUI)** Swarm roster and detail panes reflect live
  `worker.list()`/claims data and update as workers change state, at parity with
  the retired `dash.lua`. *Verify:* spawn a worker; roster row appears next frame.
  **Surface:** cTUI · **Phase:** B2

## 10. Colour, theming & graceful degradation

- [ ] **10.1** With **`NO_COLOR`** set, output contains **zero ANSI colour escape
  codes** (SGR). *Verify (capture):* `NO_COLOR=1 boggart … | grep -c $'\\x1b\\['`
  → 0 for colour sequences; structure conveyed by text alone (gutters, markers).
  **Surface:** both · **Phase:** A2/A4
- [ ] **10.2** When stdout is **not a TTY** (piped/redirected), the app degrades:
  no status line, no spinner frames, no cursor-movement escapes, no bracketed-
  paste/raw-mode sequences — just the clean transcript. *Verify (capture):*
  `boggart … | cat -v` shows no control sequences beyond newlines. **Surface:**
  REPL · **Phase:** A3/A4/§0-G2
- [ ] **10.3** `TERM=dumb` (or unset) disables completion menus, highlighting, and
  full-screen mode and falls back to a plain line-reader that still works. *Verify:*
  run under `TERM=dumb`; a turn completes with readable output. **Surface:** both ·
  **Phase:** S3/B0
- [ ] **10.4** The theme respects terminal **background (light vs dark)**: colours
  chosen for a dark bg are not illegible on a light bg. Detection uses
  `COLORFGBG`/OSC-11 where available, with a manual override. **(visual)**
  *Verify:* light-bg profile yields legible code/diff colours. **Surface:** both ·
  **Phase:** A2/A4
- [ ] **10.5** On a **256-colour or truecolour**-incapable terminal (8/16-colour),
  styles map down to the nearest palette rather than emitting unsupported codes
  that print as garbage. *Verify:* `TERM=xterm-16color` capture uses only 16-colour
  SGR. **Surface:** both · **Phase:** S3
- [ ] **10.6** All colour roles are defined **once** (`ic_style_def` / a single
  style table) and both surfaces read the same definitions — the REPL and cTUI
  cannot drift in their error/add/delete/command colours. *Verify:* grep for a
  hardcoded colour literal outside the style table → none. **Surface:** both ·
  **Phase:** S3/§0-G3
- [ ] **10.7** A **`--no-color`**/`--plain` flag (or equivalent) forces 10.2-style
  degradation even on a TTY, for screenshots and logs. *Verify:* flag capture has
  no SGR. **Surface:** both · **Phase:** A2

---

## 11. Parity & regression guards (cross-cutting)

- [ ] **11.1** REPL and cTUI render the **same** markdown/diff/tool fixtures
  identically in content (colours may map per terminal, structure must match).
  *Verify:* golden fixture rendered on both surfaces has matching text + marker
  structure. **Surface:** both · **Phase:** B1
- [ ] **11.2** Candidate data (commands, tools, models, sessions, memory keys) has
  exactly **one source** consumed by completion, `/help`, and both surfaces — no
  second copy in C. *Verify:* the only list lives in Lua/SQLite; C holds no
  command-name array. **Surface:** both · **Phase:** S1/S2
- [ ] **11.3** Turning the cTUI on and off (`--tui`) leaves the terminal in a clean
  state each time — enter alt-screen on start, restore on exit, restore on crash
  (SIGINT/panic). *Verify:* `boggart --tui`, Ctrl-C; shell is fully restored, no
  alt-screen residue. **Surface:** cTUI · **Phase:** B0/G1
- [ ] **11.4** A golden-capture test suite exists for §§1–10 and runs in CI under a
  PTY, so these properties are regression-guarded, not one-time manual checks.
  *Verify:* CI job renders fixtures and diffs against goldens. **Surface:** both ·
  **Phase:** A4/B1

---

### The five that matter most

If only five rows can be checked at review time, check these — they are the ones
users feel every turn and the ones most likely to regress:

1. **1.1–1.3** streaming shows life within 200 ms and never leaves a stuck spinner.
2. **6.5** an unknown `/command` turns error-coloured *before* Enter.
3. **7.1/7.4** the status line always shows model · local/remote · ctx% · agents,
   with the amber remote-spend flag.
4. **9.1** a resize reflows within one frame with no artifacts.
5. **10.1/10.2** `NO_COLOR` and non-tty produce zero escape codes and a clean
   transcript.
