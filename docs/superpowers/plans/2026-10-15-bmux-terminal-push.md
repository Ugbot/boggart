# Deferred terminal push implementation plan

Continue BMUX-32 using the existing snapshot/cursor/lease contract. C owns native
readiness and bounded transport; Lua owns attachment selection and frame policy.
No Python/JS runtime, per-pane timer or second terminal parser.

- [x] Native PTY changes invoke only an internal scheduling callback. Add
  `terminal:watch(fn|nil)` using a coalesced `uv_async_t`, with weak Lua ownership,
  separate native allocation/deferred close and explicit interpreter shutdown.
  Feeding never calls Lua. Pending notifications keep the loop alive until
  delivered; idle watchers are unreferenced. Expose watch diagnostics and disable
  failed callbacks without closing the PTY. Test GC, replacement, self-close,
  worker/parser-only teardown, native process exit and zero idle callbacks.
- [x] Extend the existing SSE transport with an optional opaque channel,
  initial frame and targeted broadcast/count/close. Global broadcasts reach
  global streams; terminal frames reach only their authorized attachment channel.
  Continue reading SSE sockets solely to detect EOF/unexpected input; close on
  write failure/backpressure. Bound queued writes to 8MiB so 4MiB protocol frames
  fit. Validate channel/event names and initial data before upgrading.
- [x] Add the authenticated POST attachment `/stream` route. Validate token and
  cursor, replay a frozen/current frame before subscribing, then watch native
  changes. Each reader keeps its own cursor. Skip idle/disconnected readers;
  connected streams retain read attachment lifetime while controller renewal
  remains explicit. Detach/retire/revocation closes streams and clears watchers.
  Capture/cache failures require resync rather than silent frame loss.
- [x] Test real UDS streams and a separate daemon: two clients receive exact
  frames, unrelated/global streams receive none, output between snapshot and
  subscription is replayed, reconnect catches up, disconnect leaves PTY alive,
  and slow/revoked/detached clients close correctly. No model API calls.
- [x] Run affected normal/sanitizer tests and C11 checks, update wire contract
  and evidence, review, signed-off commit and push. Parent BMUX-32 remains open
  for native attached clients and its measured sub-50ms reattach acceptance.
