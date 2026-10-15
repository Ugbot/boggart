# Server-native input for attached Studio panes

**Goal:** BMUX-74 supplies the input prerequisite for BMUX-34. The existing
Studio pane already uses a native parser; attached panes must not recreate that
parser or guess server keyboard/mouse/paste modes.

**Contract:** Extend the existing controlled `POST /terminals/:id/input` with
`events=[{kind='key'|'paste'|'focus'|'mouse',value=...}, ...]`, mutually exclusive
with `text`. At most 64 events, 64KiB total source text, 64KiB encoded output.
All events encode on the server using its current native negotiated state and
queue as one write. Invalid later events, output overflow and queue refusal
publish no input and restore host focus/mouse-motion state. Successful empty
output remains an accepted command. Existing raw input, route capabilities,
controller lease/sequence and exact retry rules remain unchanged.

The native client exposes `session:events(events, callback)` with the same
single-pending-command/uncertain-response discipline. Key values use the native
normalized key table; optional `macos` chooses client platform semantics.
Paste values are strings, focus values booleans, mouse values native event
tables. Unknown fields and malformed/sparse arrays are rejected at the route.

- [x] Extract current Lua native input bindings into `src/lterminal_input.c`
  with unchanged key/paste/focus/mouse public methods and shared parsers.
- [x] Add pure-C atomic bounded batch encoding/one sink call with state rollback;
  test failing sink, late invalid event, overflow and negotiated protocols.
- [x] Add native `terminal:send_events`, registry/route validation and client
  method; verify exact retry does not encode twice or duplicate effects.
- [x] Extend real daemon/client tests, normal/sanitizer/native Studio input
  regressions and C11/attribution checks; document results. Both affected sets
  pass 27/27; native rollback mutation fails its regression as intended.

Changed attachment frames also project validated native input negotiation.
Mode-only and zero-byte focus changes push without cell damage or polling.
Landing follows the user's standing commit/push instruction.

BMUX-34 stays open for native wire-image rendering, attached-pane lifecycle,
visible attach/control actions and SDL tests. Closing a view must detach rather
than kill the daemon PTY. No new runtime or application Python is introduced.
