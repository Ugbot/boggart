# Attached Studio terminals

Start a host in a private directory, then use **Bmux → Attach** (or
**Ctrl-Alt-A** from another mode). Enter its socket path, choose an existing
terminal, or choose **+ New shell on server**.

```sh
mkdir -p "$HOME/.boggart/bmux"
chmod 700 "$HOME/.boggart/bmux"
./boggart serve --socket "$HOME/.boggart/bmux/control.sock"
```

The pane starts **read-only**. Click **Take control** to type and resize it.
If another viewer owns it, **Take over** appears after the refusal. **View only**
releases your controller. **Reconnect** rejoins a disconnected reader without
restarting the child; closing the pane leaves the server process running.
**Retry pending command** resolves an uncertain acknowledgement using its exact
command bytes. Unsent queued input is discarded after such a failure.

The same actions are in the command palette under Terminal. Ctrl-Alt-C requests
control; Ctrl-Alt-R reconnects. Reserved Ctrl-Alt pane/workspace shortcuts stay
application-owned. The remote header stays outside the terminal mouse grid.
Passive window resizing never changes server geometry.

An optional Studio Lua setting pre-fills the endpoint:

```lua
require('core.config').bmux_server = {
  socket = bog.userdir .. '/bmux/control.sock',
  -- token = 'your configured BOGGART_SERVE_TOKEN',
}
```

A configured bearer is used only when the typed path exactly matches that
configured socket. Selecting another socket does not forward it. The endpoint
must satisfy the native client's same-user/private socket and directory checks.
The toolbar chooser lists server terminals in pages of 64 and filters their
displayed labels. Ctrl-Alt-A can create the first attached Bmux pane without
also spawning an unintended local shell.

The attachment backend uses the native libuv client and native row image.
`core.terminalremote.new({socket, token?, id, generation, tail?, cols?, rows?},
changed?)` attaches read-only. `image` is the source for
`renderer.new_terminal`; `geometry/state/row/process_state/process_revision`
project the accepted replica. Publication applies cells before exposing the
new pane state. No local PTY/parser is created.

`control(false)` explicitly requests a controller; a conflicting owner is
reported as HTTP 409. `control(true)` explicitly takes over. Only successful
explicit control enables input/resize and a one-shot, unreferenced renewal
timer. Observation alone never renews a controller. Disconnect, lost authority,
uncertain input and closure stop renewal. `view_only()` detaches the controller
reader and opens a fresh passive reader.

`event(kind,value)` queues key/paste/focus/mouse events; UI-only scancodes are
removed and the host macOS flag is supplied. The server uses its current native
negotiated modes. A FIFO preserves semantic/raw input order with one command
in flight, at most 8192 waiting entries and 32MiB source bytes. Admission is
all-or-nothing. Batches contain at most 64 events with a conservative 64KiB
output estimate. Paste chunks are at most 16KiB and preserve valid UTF-8 scalar
boundaries. Raw `write(bytes)` chunks are at most 64KiB. Resize requests coalesce
to the latest geometry and send only under controller authority.

An uncertain acknowledgement retains the client's exact encoded pending
command, drops unsent queued input and requires explicit `retry()`. Successful
retry does not silently resume controller intent. New input cannot bypass the
pending command. `reconnect()` reuses the reader cursor; expired/unavailable
readers obtain a fresh image only when no uncertain command would be lost.
`close()` releases local resources and detaches the reader; the server PTY
continues running.

The control client also preserves HTTP refusal identity for bounded plaintext
responses such as native 401 authentication errors. Successful responses
continue to require JSON, and error bodies are not shown or decoded.

Backend evidence: `tests/studio_terminal_remote.lua` runs a real daemon under
Studio's central loop, with an independently shortened test-only lease. It
checks passive authority, exact native input, UTF-8 paste spanning chunks,
renewal, takeover/revocation, lost-ACK retry, fresh-reader reconnect, atomic
byte-quota rejection and detach preserving PID. The real SDL test
`tests/studio_terminal_attached.lua` covers the visible chooser/header, native
pixels/history, normalized input, passive resize, takeover and same-PID reopen.
See [verification](benchmarks/2026-10-15-studio-attachment-verification.md).
