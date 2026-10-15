# Server-native input batches

BMUX-74 adds semantic input for attached views. The server's native terminal
encodes keys, paste, focus and mouse events using its current negotiated modes.
The client does not need a second VT parser. Connecting Studio's SDL/IME
controller and native renderer to attachments remains BMUX-34 work.

The existing controlled `POST /terminals/:id/input` accepts **either** `text`
(unchanged raw bytes) **or** `events`, plus generation, attachment/controller
credentials and command sequence. No additional route capability is introduced.

```lua
session:events({
  {kind='key', value={key='up', action='press', macos=true}},
  {kind='paste', value='hello 🦊\n'},
  {kind='focus', value=true},
  {kind='mouse', value={action='press', button=1, x=16, y=32,
    cell_width=8, cell_height=16, modifiers=0}},
}, function(error, result)
  -- result: id, generation, accepted_bytes, accepted_events
end)
```

Key values use the existing normalized fields: `key`, `action`, `modifiers`,
`consumed_modifiers`, `right_modifiers`, `unshifted`, `base_layout`, `composing`,
`option_as_alt`, `text`, and optional `macos`. Omitted `macos` retains the host
build's default; explicit values select the input source platform. UI scancodes
are not wire fields. Mouse fields are `action`, `button`, `modifiers`, `x`, `y`,
`any_button_pressed`, `cell_width`, `cell_height`. Unknown/nested fields,
malformed arrays and kinds are rejected; native encoders validate names, ranges,
UTF-8 and negotiated suppression.

Bounds: **1..64 events**, **64KiB combined source text**, **4096 text bytes per
key**, **64KiB encoded output**. Expansion counts: a full 64KiB bracketed paste
plus framing does not fit. Oversized batches fail whole; callers must split
input deliberately. Clipboard authorization and event ordering remain UI policy.

Arguments/text roots are staged before native borrows. Encoding and queue
admission have no Lua allocation/callback boundary. The batch calls the native
PTY queue sink once; late errors, overflow and refused admission emit no batch
bytes and restore focus/mouse-motion state, including motion geometry. Once
admitted, later errors follow the existing asynchronous PTY write contract.

Successful empty output is still an accepted command. Focus can change with
reporting disabled, so it schedules a native watch without queued bytes.
Retries use the original semantic payload and return cached success **before
re-encoding**. Later modes or process exit cannot change the bytes of an
identical accepted retry. `session:events` shares input/resize's single pending
command, explicit lease and exact-byte uncertain-response retry discipline.
Missing ownership never acquires control implicitly.

Changed attachment snapshots/deltas include validated native `input_state`:
`mouse_mode`, `mouse_format`, `kitty_flags`, `backarrow`, `ignore_keypad_numlock`,
`alt_prefix`, `modify_other_keys_2`, `bracketed_paste`, `focus_reporting`,
`focused`. Mode-only changes participate in coherent capture/push without cell
damage. Older frames that never supplied this remain readable; once supplied
it cannot disappear from changed frames. This supports gesture routing; server
state determines bytes at execution.

`bterm_input_batch.c` owns native transaction/rollback. `lterminal_input.c`
shares encoder parsers and Lua methods, including `terminal:send_events(events)`
for a live PTY owner. Existing key/paste/focus/mouse defaults remain. CLI/Studio
source identities include both new C modules.

Tests: [native rollback/oracle](../tests/c/terminal_input.c),
[actual daemon/child bytes, retry and finalizer closure](../tests/terminal_input_events.lua),
[mode-only push](../tests/terminal_push.lua).
See [verification](benchmarks/2026-10-15-semantic-input-verification.md).
BMUX-34 stays in progress for wire-image rendering, remote-pane lifecycle and
visible attach/control actions. This adds no new UI flow or runtime.
