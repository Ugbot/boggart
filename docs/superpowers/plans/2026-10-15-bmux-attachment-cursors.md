# Terminal attachment cursors and controller leases

Continue BMUX-32's approved persistent-host architecture with a bounded,
testable wire contract. C/Lua only, same native PTY/grid and libuv loop. The
parent remains open for push delivery, thin clients and its latency gate.

- [x] Expose non-consuming native visible/history-tail row versions. Copy
  borrowed revisions before Lua allocation can run finalizers. Native damage
  acknowledgements must not invalidate another reader's baseline.
- [x] Add `lua/terminal/attachments.lua`, owned by the server registry. Default
  bounds: 128 attachments, 30s reader expiry, 10s controller lease, 32768 cells
  per snapshot, 256 tail rows, 4MiB encoded frame and 32MiB retained frames.
  Each reader gets random identity/token, frozen initial full grid/tail,
  independent cursor/version baseline and one immutable retry frame. Changes
  replace only damaged visible rows; changed history sends its bounded tail.
  Geometry/alternate-screen changes send a fresh full image. A cursor older
  than the retained frame requires explicit resynchronization.
- [x] Add authenticated/policy-scoped attachment create/updates/control/detach
  routes. Initial attach defaults to read-only. First attachment permanently
  enables lease-guarded input/resize for that terminal runtime, closing the
  unleased mutation path. Only explicit controller acquisition/takeover permits
  writes; expiry, detach and takeover revoke the prior token. Controller
  commands require monotonic sequence numbers; retry of the last identical
  accepted command returns its prior result without repeating side effects.
  Admin close remains an explicit lifecycle capability.
- [x] Test actual PTYs and UDS clients: full cells/Unicode/styles/links/tail,
  independent deltas despite native damage acknowledgement, output between
  snapshot and update, cached retry bytes, stale cursors, resize/alternate
  transitions, read-only/expired/taken-over controller rejection, command
  deduplication, capacity and release. Kill/disconnect of a viewer never closes
  the terminal. Fake monotonic time makes expiry deterministic.
- [x] Run affected normal/sanitizer tests, document versioned wire schema and
  limitations, update tracker evidence, review, commit and push. Do not claim
  push streaming or the sub-50ms gate from request/response correctness alone.
