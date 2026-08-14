# The CLI / TUI overhaul — the plan

The terminal is where boggart is actually driven, and it is the least finished
surface. Line editing is already C (isocline, in `src/lsys.c`), but nothing is
wired on top of it: **Tab does nothing, the input line is un-highlighted, and
there is no status line telling you what model a turn will hit.** The SDL studio
got the rich treatment; the terminal did not.

This plan fixes that as **two surfaces over one C substrate**:

- **A. the enriched scrolling REPL** — the default. Stays a scrolling terminal
  (piping keeps working, scrollback stays the transcript), but gains completion,
  hints, highlighting, a persistent status line, and streaming polish.
- **B. a full-screen cTUI mode** — an *option* (`boggart --tui`, and
  `boggart swarm --tui`). A C-native full-screen app: transcript + input +
  status + swarm panes. Subsumes the Lua `ltui` dashboard over time.

Both read the **same** completion engine, the same `bog.api.status()`, the same
worker/claims data. Two renderers, one source of truth — the studio↔CLI parity
discipline, applied inside the terminal.

---

## The C / Lua boundary (decided)

**C owns the mechanism; Lua supplies the candidates.** No candidate list is
duplicated into C — the things you complete already live in Lua and SQLite, and
a second copy would be the parity bug this project keeps designing out.

A new **`src/lterm.c`** owns, in C:

- the isocline **completer** callback (`ic_set_default_completer`) — calls one
  Lua entrypoint `bog.complete(line, pos)` and feeds results to
  `ic_add_completion_ex` (each with a display string and a help string);
- **filename completion** via the built-in `ic_complete_filename` (pure C, no
  Lua round trip) for `@file` and path arguments;
- the **highlighter** callback (`ic_set_default_highlighter`) — colourises
  `/command`, `@file`, and arguments; flags an unknown `/command` before Enter;
- **styles** defined once (`ic_style_def`) and feature enables (multiline,
  inline hints, completion preview, Ctrl-R history search, brace matching);
- the **status line** and, for surface B, the **full-screen renderer and input
  loop** — both need raw terminal control (termios + ANSI / a cell grid), which
  is C by nature.

Lua supplies, through `bog.complete(line, pos) -> {items}` and existing
accessors:

- slash-command names + per-command argument completers (from the command
  registry below);
- tool names (`bog.tools`), memory keys, session ids + titles (`bog.store`),
  provider model names (`api.lua`'s per-provider `models`);
- anything dynamic a future command wants to complete — it registers a
  completer, it does not edit C.

---

## Shared substrate (build first)

Nothing in either surface works without these, so they land first.

1. **Command registry** (`lua/repl_cmds.lua` or a table in `boot.lua`).
   Today `handle_command` is a hand-written `if/elseif` chain and `/help` is a
   separate hand-written string — they can already drift. Replace both with one
   table: `{ name, help, args = <completer>, run = <fn> }`. `/help`, dispatch,
   and completion all read it. This is the single source the C completer asks
   about via `bog.complete`.

2. **`bog.complete(line, pos)`** (Lua). Parses the line into
   (command, current-token, token-index) and returns ranked items. Bare `/` →
   command names; `/model ` → model names; `/resume ` → sessions; `/auth ` →
   `key|url|model`; a `@` token → filenames; free text → nothing (the agent
   handles it). Pure function, unit-testable without a terminal.

3. **`src/lterm.c`** (C). Registers the isocline callbacks against
   `bog.complete` and a highlighter, enables the isocline features, and exposes
   `term.*` to Lua (enable/disable, style config, status-line paint). `l_readline`
   moves here from `lsys.c` (or calls into here), so the interactive core is one
   module.

---

## Surface A — the enriched scrolling REPL

*Deliverable per phase; each is useful alone.*

- **A1 Completion.** Tab completes commands, their arguments, and `@files`.
  (substrate + wiring.)
- **A2 Hints + highlighting.** Dim inline hint of the next argument; `/cmd`,
  `@file` and args coloured; an unknown `/command` shown in the error colour
  *before* you submit it.
- **A3 Status line.** A bottom row, painted by C without disturbing scrollback,
  from `bog.api.status()`: **model · local/remote · ctx% · N agents**, with the
  amber remote-spend flag the studio bar already uses.
- **A4 Streaming + render polish.** Spinner + elapsed while a turn streams; tool
  calls and diffs rendered with the studio's colour vocabulary (`+`/`-` diff
  lines, tool headers). Still a scrolling transcript.

---

## Surface B — the full-screen cTUI mode

A C-native full-screen application, opt-in, that reuses the substrate. It does
**not** become the default — it is the mode you pick when you want to watch a
fleet or work without the GUI.

- **B0 Terminal-control layer.** Decide: a small hand-rolled `termctl` (termios
  raw mode + ANSI + a double-buffered cell grid, zero new dependency) **or**
  vendor **termbox2** (single-header C, MIT, ~2k lines). Recommendation:
  hand-rolled `termctl` — it stays in the single-binary/no-heavy-dep spirit and
  is small, and isocline already proves we are willing to own this layer.
- **B1 Layout.** Transcript pane + input line (the *same* isocline editor and
  completion, embedded) + status line. Resize-aware.
- **B2 Swarm panes.** A roster pane (from `worker.list()` + the claims board)
  and a detail pane — the data `dash.lua`/`ltui` already surface, re-rendered in
  C.
- **B3 Scheduler-owned frame.** Critical constraint, inherited from `dash.lua`:
  the cTUI must **not** run its own blocking loop. It paints **one frame per
  scheduler iteration** (non-blocking input poll + one paint), driven from
  `sched.lua`'s hook, so no agent's in-flight HTTP ever stalls. One frame per
  scheduler turn, never the other way round.
- **B4 Retire `ltui`.** Once B reaches parity with the swarm dashboard, drop the
  224K of vendored `ltui` Lua and `dash.lua`. Until then they coexist and keep
  working.

---

## Sequence

1. Command registry + `bog.complete` (+ its unit tests).
2. `src/lterm.c` completer/highlighter wired → **A1, A2**.
3. Status line → **A3**. Streaming polish → **A4**. *(REPL now excellent.)*
4. `termctl` (B0) → cTUI layout embedding the same editor (B1).
5. Swarm panes (B2) + scheduler-owned frame (B3).
6. `ltui` retires once B is at parity (B4).

Steps 1–3 ship the everyday win fast; 4–6 add the full-screen mode without
touching the REPL path.

---

## What is C, what is Lua

| piece | where | why |
|---|---|---|
| isocline completer / highlighter callbacks | **C** (`lterm.c`) | the callback type is C; the mechanism belongs here |
| filename completion | **C** (`ic_complete_filename`) | built in, no Lua needed |
| status-line paint, cTUI renderer, termctl | **C** | raw terminal control |
| `bog.complete`, command registry, per-command completers | **Lua** | the candidate data already lives here; duplicating it is the parity bug |
| candidate sources (tools, sessions, models, memory) | **Lua / SQLite** | already the source of truth |
| scheduler-owned frame hook | **Lua** (`sched.lua`) reaching a **C** paint | the loop is already Lua's; the paint is C |

---

## Open decisions

- **B0: hand-rolled `termctl` vs vendor termbox2.** Recommendation: hand-rolled,
  for the single-binary ethos. Reversible — the cTUI renderer sits behind a thin
  interface either way.
- **How much of the command registry goes in C.** Decided: **Lua** (mechanism in
  C, candidates/registry in Lua). Revisit only if the registry needs to be
  reachable before Lua is up.
- **Does the cTUI ever become default?** Not planned. The scrolling REPL stays
  the default because piping and scrollback are worth more than panes for most
  runs; the cTUI is the deliberate opt-in.
