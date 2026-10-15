# Studio attached pane implementation plan

> Execute inline with executing-plans, preserving the existing approved Bmux
> terminal-host design and standing commit/push authorization.

**Goal:** A discoverable Studio pane observes and explicitly controls a server
terminal without owning its PTY, parser or history.

**Architecture:** `core.terminalremote` adapts `terminal.client` and the native
image to the pane interface. `core.terminalinput` dispatches semantic events
through an optional callback. `TerminalView` reserves a remote control header
and uses the same native renderer for both sources. `core.terminalattach`
selects a trusted private UDS and server terminal; the Bmux toolbar opens it.
No new runtime, subprocess transport, client VT parser or automatic takeover.

- [x] Backend (BMUX-76): `Remote.new(opts, changed)` attaches read-only;
  `event(kind,value)`, `write(bytes)` use one bounded FIFO, <=8192 entries and
  32MiB source. Batch <=64 events and conservative <=64KiB encoded output;
  raw input <=64KiB, paste chunks <=16KiB. Queue admission is all-or-nothing.
  Coalesce `resize(cols,rows)` and send only with live explicit controller.
  `control(takeover)`, `view_only()`, `reconnect()`, `retry()` expose authority
  changes. Renew with one-shot unreferenced timer while writer intent persists;
  stop on disconnect/close/lost control. On uncertain command discard unsent
  queue and retain Session.pending for explicit exact retry. Apply native image
  before publishing backend snapshot. `close()` detaches, leaving PTY alive.
- [x] Input: `Input.new(term,send,clipboard,dispatch?)`; route key/paste/focus/
  mouse through dispatch if present, preserving local encoder behavior and
  reserved Ctrl-Alt/SDL IME policy. Strip UI scancode before the wire; include
  host macOS flag. Keep transport errors' HTTP statuses even for plaintext
  refusals while successful responses still require JSON.
- [x] Backend evidence: actual private daemon under Studio's existing async
  loop; passive view/no resize, exact native input, ordered batch boundaries,
  quota admission, takeover, lease renewal, uncertainty/retry, reconnect and
  detach preserving PID. Run `ctest -R 'terminal_(transport|client)|studio_terminal_remote|studio_terminal_native'`
  in normal and sanitizer builds. Record commands/results and commit.
- [x] Pane/front door (BMUX-77): adapt TerminalView constructor,
  render source, header/body geometry, read-only input and close. Header actions
  Take control, Take over after conflict, View only, Reconnect, Retry pending
  command. Socket prompt + paginated terminal chooser/new server shell, Attach
  toolbar item/command. Bind configured credentials only to their exact socket.
  First Bmux attachment must not create an unintended local shell.
- [x] Actual SDL integration: drive normalized keyboard/IME, bracketed paste,
  focus, mouse, reserved application chords and visible header controls through
  a real daemon; verify pixels/history, writer-only resize, takeover and close/
  reopen with same PID. Capture visible UI. Run relevant normal/ASan regressions,
  document evidence, commit/push. BMUX-34 retains its BMUX-24/31 dependencies
  and stays in progress until those requirements are also satisfied.
