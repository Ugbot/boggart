# Native Bmux attachment client

`require('terminal.client')` supplies asynchronous Lua sessions over the existing
native libuv binding. It uses the [attachment protocol](bmux-terminal-attachments.md)
and has no curl subprocess or new runtime dependency. The daemon owns each PTY,
parser, grid and history. This is the reusable client for the upcoming Studio
and cTUI attachment views (BMUX-34/35), not those views themselves.

```lua
local uv = require 'uv'
local client = require('terminal.client').new { socket = '/private/path/control.sock' }
client:attach(terminal_id, generation, { tail = 32 }, function(error, session)
  if error then return report(error.message) end
  paint(session:view())
  session.on_update = paint
  session:control(false, function(why)
    if why then return report(why.message) end
    session:input('pwd\n', function(failure) if failure then report(failure.message) end end)
  end)
end)
-- A CLI may own uv.run(); Studio must pump its existing loop instead.
```

`new{socket, token?, timeout_ms?}` requires an absolute UDS path of at most 91
bytes and a private, same-user socket and immediate parent directory, using
`lstat` to reject symlinks at those two paths. Missing/not-yet-private sockets
fail setup. The caller selects a trusted endpoint; there is no discovery,
redirect, proxy, TCP fallback or automatic credential forwarding. The portable
91-byte path limit avoids libuv's historical silent UDS-path truncation.
Windows transport/ConPTY remains separate roadmap work.

`client:request(method, path, object_or_encoded_JSON?, callback)` exposes the
bounded control route subset for create/list/admin operations. The callback is
`callback(error, decoded_object, HTTP_status)` and the returned request supports
`:cancel()`. HTTP refusal errors expose `status`; transport/protocol/deadline
failures are distinct error kinds. Messages omit raw response bodies/tokens.
There are at most 64 requests and 64 sessions per client. Attach/control/input/
resize callbacks are required; detach permits an omitted callback. Client/session
objects require explicit close; a live stream intentionally retains its handles.

## Session lifecycle and authority

- `client:attach(id, generation, options, callback)` returns a session immediately.
  Its callback fires after the initial image and first stream replay have been
  validated. `options={tail?, stream?, on_update?, on_disconnect?}`; default
  streaming is enabled. `stream=false` returns a snapshot-only `attached` session.
- `session:view()` returns the current **borrowed read-only** view with cursor,
  geometry, full screen, state, process and bounded scrollback. Consumers must
  not mutate it. A validated frame publishes one new view; invalid late rows
  leave the old image and cursor untouched. Unicode cell clusters, style, OSC 8
  links and wrapping remain native data, without reparsing terminal output.
- `session:disconnect()` cancels observation and keeps its local image/cursor.
  `:reconnect(callback)` tries that reader's retained cursor. Expired capabilities
  or unavailable cursors are returned explicitly; choose a fresh `client:attach`
  for a full image. Reconnect never takes control automatically.
- `session:control(takeover_boolean, callback)` explicitly acquires/renews the
  writer lease. `true` permits taking it from another viewer. Streaming alone
  never renews writer authority. Renew explicitly before the lease expires or
  use accepted commands, which renew the server lease and local deadline.
- `session:input(text, callback)` and `:resize(cols, rows, callback)` require an
  acquired live controller and serialize commands. Each lease has a sequence;
  an uncertain response keeps the **exact encoded pending command** and blocks
  new commands/control changes. `session:retry(callback)` retries those same
  bytes so the server can return its cached acknowledgement without repeating
  input/resize. Malformed successful acknowledgements and server errors also
  stay uncertain, since failure can occur after the effect was accepted.
  Do not infer rejection from a disconnect. No replay occurs across a new lease.
- `session:events(events, callback)` uses the same controller and command queue
  for [atomic server-native key/paste/focus/mouse batches](bmux-terminal-input.md).
  The server encodes using current negotiated modes. Views also carry validated
  `input_state` metadata, including mode-only and zero-byte focus changes.
- `session:close()` cancels local operations and suppresses subsequent session
  callbacks, leaving the daemon PTY running. `:detach(callback)` additionally
  asks the host to release its reader/cache/controller; its callback still runs.
  `client:close()` closes every local session and request. Readers disconnected
  without explicit detach expire under the server's existing TTL/quota rules.

Status is `attaching`, `connecting`, `live`, `attached`, `disconnected` or `closed`.
Stream/callback failure becomes `disconnected` with `session.error` and invokes
`on_disconnect` after initial readiness. Calling attach-session close/disconnect
before readiness intentionally cancels its readiness callback. Request callback
exceptions are captured as `request.operation.callback_error`; stream consumer
exceptions close the transport and report a bounded protocol diagnostic.

## Framing and validation bounds

The transport accepts the native listener's Content-Length JSON and unchunked
SSE subset: headers at most 16KiB, JSON/data at most 4MiB, per-event framing at
most 4MiB + 4KiB. Duplicate headers, unsupported transfer/content encodings,
extra/truncated bodies and malformed framing are rejected. Fragmented UTF-8,
headers and SSE lines are handled. The 5-second default deadline (configurable
1..60000ms) covers complete JSON or the first full SSE event, including connect;
headers/comments cannot satisfy it. After the first event idle streams have no
periodic client timer. Native libuv handles are closed on completion,
cancellation, deadline, peer EOF, write/read error or consumer error.

The client and native listener request 256KiB UDS send/receive buffers when the
current setting is smaller. These are best-effort kernel hints, independent of
application framing/queue bounds; OS clamping/refusal leaves the connection
usable. Larger existing settings are preserved. TCP settings are unchanged.
Unix buffer reporting differs by OS (Linux may return twice the request), so
this is not an exact kernel allocation or RSS guarantee.

The replica checks version/runtime/reader identity and cursor continuity,
1..4096 geometry, 32768 cells including history, at most 256 history rows,
row indices/lengths, Unicode scalar/UTF-8 cell text, styles/links, cursor/margins
and process metadata. Native JSON decoding has its C nesting bound; the Lua
fallback receives an additional 32-level scan before recursive decoding. No
cursor is acknowledged from a partial frame.

Tests: [`terminal_transport`](../tests/terminal_transport.lua),
[`terminal_replica`](../tests/terminal_replica.lua),
[`terminal_client`](../tests/terminal_client.lua). The last uses a separate real
daemon and killed client process, 80×24 screen and a nonempty 32-row tail. Its
timing output records protocol and cold-process costs separately. Set
`BMUX_RECONNECT_GATE=1` to assert both validated attach/replay and kill/reap/rejoin
below 50ms. Set `BMUX_RECONNECT_TRACE=1` for bounded chunk/phase diagnostics;
these test-only probes wrap the existing code and keep policy/evidence enabled.
See [client correctness](benchmarks/2026-10-15-native-client-verification.md)
and [the measured latency gate](benchmarks/2026-10-15-reconnect-latency.md).

Transport references: [libuv pipes](https://docs.libuv.org/en/v1.x/pipe.html),
[streams](https://docs.libuv.org/en/v1.x/stream.html), and the vendored
[`luv` binding](../src/vendor/luv/pipe.c).
