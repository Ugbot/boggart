# Bmux native attachment client implementation plan

**Goal:** Product Lua/libuv UDS attachments survive client replacement while the
server keeps the PTY, grid and history. This implements the client portion of
BMUX-32; Studio and cTUI presentation remain BMUX-34/35.

**Architecture:** A bounded HTTP/SSE transport owns cancellable libuv handles.
A pure replica validates each complete v1 frame before publishing a new view.
An attachment session owns credentials, stream, cursor and explicitly acquired
controller lease. It never owns or closes the server PTY.

**Tech stack:** Existing C11 host, Lua and native libuv/json bindings; no new
runtime or subprocess transport. Continue the approved server attachment design.

## Tasks

- [x] Add `lua/terminal/transport.lua`: asynchronous one-request UDS connections,
  16KiB headers, 4MiB JSON/events, Content-Length JSON and unchunked SSE; reject
  conflicting lengths/transfer encodings; deadline until full JSON or first SSE
  event, explicit cancellation, callback errors close all native handles.
  Test fragmented framing, malformed/oversized/truncated responses, timeout,
  cancellation and idle SSE in `tests/terminal_transport.lua`.
- [x] Add `lua/terminal/replica.lua`: validate identity/version, monotonic cursor,
  geometry/cell budgets, row arrays, UTF-8 clusters, styles/links, state/process
  and bounded history. Publish screen/history atomically; reject malformed
  late rows and gaps without changing the previous view. Test against actual
  native snapshots and adversarial frames in `tests/terminal_replica.lua`.
- [x] Add `lua/terminal/client.lua`: asynchronous attach/stream/reconnect,
  explicit control/takeover, sequenced input/resize, exact pending-command
  retry, disconnect and detach. An uncertain command blocks new writes until
  resolved or control is explicitly relinquished. No automatic takeover or
  replay across changed leases; observation never renews writer authority.
- [x] Add actual-daemon integration and separate process fixtures in
  `tests/terminal_client.lua` and `tests/fixtures/terminal_attach_process.lua`.
  Kill a client, compare fresh native screen AND nonempty scrollback tail,
  verify two replicas converge across output/resize/exit. Measure reconnect
  through complete validated first snapshot and stream replay; report normal
  and sanitizer timing separately, retaining the parent gate if unproven.
- [x] Register CTest suites, document API and measured limits/results, review
  diffs and run normal and sanitizer suites. Results are in
  `docs/benchmarks/2026-10-15-native-client-verification.md`.

Landing: commit with BMUX-72 and push the existing feature branch under the
user's standing instruction. Keep BMUX-32 and the overall roadmap goal active:
the exact-image reconnect passes, but measured reconnect still exceeds 50ms.

## Verification

Run `ctest --test-dir build -R '^terminal_(transport|replica|client|server|attachments|push|watch)$' --output-on-failure`
and the same in `build-asan`, after building both with the existing ccache
environment. Build source embedding includes new Lua modules. Compare view JSON
to a separately attached native snapshot, including per-cell text/style/link,
wrapping and history indices. Do not use plain-text equality to claim byte
identical cell images. The <50ms parent gate includes actual client death and
rejoin; process startup timing is recorded separately from warm attachment.

Primary transport references: [libuv pipes](https://docs.libuv.org/en/v1.x/pipe.html)
and [streams](https://docs.libuv.org/en/v1.x/stream.html). The client accepts only
the native server's documented Content-Length JSON / unchunked SSE subset.
