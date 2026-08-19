# cTUI completeness

Work remaining to bring `boggart --tui` up to the Claude Code floor. Skip by
design: voice, images, full vim, `keybindings.json`, OSC-8 hyperlinks, rewind UI.

The quality bar (observable pass/fail) lives in [`tui-quality.md`](./tui-quality.md).
Component contracts live in [`ctui-spec.md`](./ctui-spec.md).

## Done

- [x] **termctl** — Shift/Alt/Ctrl modifiers, Shift-Tab, Shift-Enter / Ctrl-J
      newline, bracketed paste, Alt+char. Lua `tc.poll` reports `shift`/`alt`/`ctrl`
      and `{ type="paste", text=... }`.
- [x] **Composer** — multiline wrap (`visual`), readline (Ctrl-A/E/K/U/W/Y,
      Alt-B/F), persist history, Ctrl-R search, Ctrl-S stash, paste insert.
- [x] **Completion overlay + skills in `/`** — Tab with several hits opens a
      pick menu; `/` completion includes skill names; `/<skill>` hands that
      skill's instructions to the agent.

## Next

- [ ] **Permission bar + Shift-Tab modes** (`auto` / `smart` / `manual` / `chat`).
      Studio already has this (`perm.lua` / AgentView); the TUI does not gate
      `run_tool` or draw an approval bar.
- [ ] **Chrome** — `?` help overlay, footer, Esc interrupts a turn (does not
      quit), Ctrl-D double-tap exit, `/clear` `/compact` `/cost`, `!` bash,
      Ctrl-G `$VISUAL`/`$EDITOR`.
- [ ] **Transcript** — tool cards, diffs at the decision point, thinking
      blocks, search, `{` `}` jump to previous/next user prompt, Ctrl-O expand
      tools.
- [ ] **Too-small terminal** — if the grid is below a usable size, draw a
      message instead of a blank frame.

## Notes

- Keep files under ~500 lines. Lua 5.5: never `table.insert(t, 1, x)` on an
  empty table.
- Composer tests: `./boggart --eval tests/tui_input.lua`.
- Completion tests: `./boggart --eval tests/complete.lua`.
