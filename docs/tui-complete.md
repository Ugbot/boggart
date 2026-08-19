# cTUI completeness

Work remaining to bring `boggart --tui` up to the Claude Code floor. Skip by
design: voice, images, full vim, `keybindings.json`, OSC-8 hyperlinks, rewind UI.

The quality bar (observable pass/fail) lives in [`tui-quality.md`](./tui-quality.md).
Component contracts live in [`ctui-spec.md`](./ctui-spec.md). Why Claude Code
is the floor, and how Codex / Goose compare on the same surfaces, lives in
[`peers.md`](./peers.md).

## Done

- [x] **termctl** — Shift/Alt/Ctrl modifiers, Shift-Tab, Shift-Enter / Ctrl-J
      newline, bracketed paste, Alt+char. Lua `tc.poll` reports `shift`/`alt`/`ctrl`
      and `{ type="paste", text=... }`.
- [x] **Composer** — multiline wrap (`visual`), readline (Ctrl-A/E/K/U/W/Y,
      Alt-B/F), persist history, Ctrl-R search, Ctrl-S stash, paste insert.
- [x] **Completion overlay + skills in `/`** — Tab with several hits opens a
      pick menu; `/` completion includes skill names; `/<skill>` hands that
      skill's instructions to the agent.
- [x] **`@` file autocomplete** — `@lua/comp` lists that directory; `@complete`
      finds `lua/complete.lua` by basename; typing `@` opens the file menu and
      further keys filter it; Tab into a unique directory keeps descending.
- [x] **Studio parity** — AgentView uses the same `bog.complete` / slash-command
      / `perm` / `take` engines as the cTUI. The old single-primary-node studio
      layout is marked LEGACY (`BOGGART_STUDIO_LEGACY=1`); the shell is the default.
- [x] **Permission bar + Shift-Tab modes** (`auto` / `smart` / `manual` / `chat`).
      Shared `perm.lua` state; TUI gates `run_tool` and draws the approval bar.
      `/mode` works on every surface.
- [x] **Chrome** — `?` help overlay, footer shows the mode, Esc interrupts a
      turn (does not quit), Ctrl-D double-tap exit, `/clear` `/compact` `/cost`
      `/copy`, `!` bash, Ctrl-G `$VISUAL`/`$EDITOR`. Too-small terminals draw a
      message instead of a blank frame.
- [x] **Shared submit door** — `lua/take.lua` parses `/` `!` `@` the same way in
      the TUI and the studio. Composer history is the same file. `{` `}` jumps
      user prompts. Ctrl-O expands the TUI tool strip.

## Next

- [ ] **Transcript polish** — thinking-block collapse in the TUI (studio has
      it), in-transcript search, Ctrl-O expand of a single tool card (TUI
      currently toggles the activity strip height).

## Notes

- Keep files under ~500 lines. Lua 5.5: never `table.insert(t, 1, x)` on an
  empty table.
- Composer tests: `./boggart --eval tests/tui_input.lua`.
- Completion tests: `./boggart --eval tests/complete.lua`.
- Shared front-end tests: `./boggart --eval tests/front.lua`.
