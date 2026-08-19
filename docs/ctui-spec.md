# The full-screen cTUI — component contracts

`boggart --tui` (chat) becomes a full-screen terminal app built on `termctl`
(src/termctl.c, B0). This spec fixes the interfaces between its pieces so they
can be built in parallel and still fit. The ltui swarm dashboard is **not**
retired; the cTUI coexists with it.

## The hard constraints

1. **One terminal owner.** isocline (the scrolling REPL's line editor) and
   termctl (the full-screen cell grid) both drive raw mode and rendering. They
   cannot run at once. So the cTUI does **not** use isocline: it renders with
   termctl and has its own input widget. The scrolling REPL keeps isocline. They
   are separate modes.
2. **One renderer.** Transcript content is rendered to **styled runs** (below),
   which the scrolling REPL serialises to ANSI and the cTUI blits into cells.
   Same markdown/code/diff logic, two outputs -- the studio↔CLI parity rule.
3. **Scheduler owns the frame.** The cTUI paints one frame per scheduler
   iteration (poll once, paint once) -- never its own blocking loop -- so an
   in-flight agent HTTP request never stalls. This is dash.lua's rule.

## Contract A -- `tc`, the Lua binding for termctl (src/ltermctl.c)

A thin C module wrapping src/termctl.c, registered as the global `tc`. Colours
are **hex strings** ("rrggbb") or nil (terminal default); the binding converts
hex to the nearest xterm-256 index that termctl emits, so callers speak one
colour language (the same hexes termrender uses).

    tc.init()                         -> ok:boolean        -- raw mode + alt screen
    tc.shutdown()                                          -- restore the terminal
    tc.size()                         -> w, h              -- cells
    tc.clear()                                             -- blank the back buffer
    tc.set(x, y, ch, fg, bg, attr)                         -- one cell; ch = codepoint or 1-char string
    tc.puts(x, y, s, fg, bg, attr)    -> x2                -- utf8 string, advances by display width
    tc.flush()                                             -- diff + emit changed cells
    tc.poll(timeout_ms)               -> ev                -- exactly one poll; see below

`fg`/`bg`: "rrggbb" hex or nil. `attr`: a table like {bold=true, dim=true,
underline=true, reverse=true} (any subset), or nil. `x,y` 0-based, clipped.

`ev` (event) is a table:
    { type = "key" | "resize" | "mouse" | "paste" | "none",
      key  = "up|down|left|right|home|end|pageup|pagedown|enter|tab|backspace|
              esc|delete|insert|char|ctrl|f1..f12",   -- when type=="key"
      char = <codepoint>,   -- when key=="char" (the scalar) or key=="ctrl" (the letter)
      shift, alt, ctrl,     -- booleans, when a modifier was held (type=="key")
      text,                 -- when type=="paste" (bracketed-paste payload)
      w, h,                 -- when type=="resize"
      mx, my, button }      -- when type=="mouse" (0-based cell)

Shift-Tab is `key="tab"` with `shift=true`. Ctrl-J / Shift-Enter are `key="enter"`
with `ctrl` / `shift`. Alt+char is `key="char"` with `alt=true`. Bracketed paste
is enabled for the life of `tc.init` and restored on shutdown.

`tc.init` degrades gracefully with no tty (returns false; other calls are safe
no-ops) so `--eval` harnesses do not wedge. Register in src/boggart.c and add
src/ltermctl.c to the boggart target in CMakeLists.txt.

## Contract B -- `termrender.runs`, the styled-runs core (lua/termrender.lua)

Refactor termrender so its core produces **styled runs**, and the existing ANSI
`termrender.entry`/etc. become a serialiser over runs. All 32 existing tests in
tests/termrender.lua must stay green (they assert the ANSI output, which must not
change).

    termrender.runs(entry, opts) -> lines
      lines      = { line, line, ... }
      line       = { run, run, ... }
      run        = { text = <string>, fg = <"rrggbb"|nil>, bg = <"rrggbb"|nil>,
                     attr = {bold?, dim?, italic?, underline?, reverse?} | nil }
      opts       = { width = <cols|nil> }   -- wraps prose (never code)

Every visible character is in exactly one run; concatenating a line's run texts
gives the plain text of that line. The ANSI path (`termrender.entry`, .assistant,
.diff, ...) stays byte-for-byte identical -- implement it by serialising runs
(honouring `opts.color` and NO_COLOR). Add tests for `runs` (a heading run is
bold; a diff's +/- runs carry good/error fg; plain text is one run) without
disturbing the existing 32.

## Contract C -- `lua/tui/input.lua`, the input widget

A line editor driven by `tc` key events (Contract A), reusing the REPL's own
policy: `bog.complete` for Tab, `bog.repl_style` for colour. Pure state + logic,
no terminal control of its own -- it renders to runs the layout blits.

    local Input = require("tui.input")
    local box = Input.new{ history = {...}, history_file = path }
    local action, value = box:key(ev)
      -- action: "submit" (value = the line), "cancel", "stash", "editor",
      --         "eof", "search", "redraw", or nil (edited in place)
    box:runs(width) -> line_runs, cursor_col   -- one scrolled row (tests)
    box:visual(width) -> rows, cursor_row, cursor_col
    box:overlay_runs(width) -> menu or history-search run-lines
    box.line / box.cursor

Behaviour: insert printable chars and pastes; backspace/delete; left/right/home/end
(and Alt-left/right for words); Up/Down move physical lines or history; Shift-Enter
/ Ctrl-Enter / Ctrl-J insert a newline; Enter submits; Ctrl-C or Esc on empty
cancels. Tab completes via `bog.complete` (one hit replaces; several insert the
common prefix and open a pick menu). Ctrl-A/E/K/U/W/Y are readline. Ctrl-R is
history search. Ctrl-S stashes the buffer. History is optional in-memory, or
persisted when `history_file` is set.

## Integration (owned by the main agent, not fanned out)

`lua/tui.lua` composes the pieces: a transcript pane (termrender.runs blitted via
tc), a status row (bog.api.status, like the scrolling REPL's), the input widget's
runs, and an optional swarm pane (worker.list + claims). The frame loop polls tc
once and paints once per scheduler iteration; `boggart --tui` (chat) is the entry
point. Reconciles A/B/C and wires the scheduler hook.
