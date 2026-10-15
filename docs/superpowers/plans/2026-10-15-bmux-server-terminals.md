# Server-owned terminals implementation plan

Continue BMUX-30 and the persistent-host design in `docs/tmux.md`. The native
PTY/grid now exists outside Studio; one server Lua registry will retain it on
the existing libuv loop. This is the ownership foundation for BMUX-32/34, not a
claim that Studio is already a reconnectable client.

- [x] Add `lua/terminal/registry.lua`: opaque per-server IDs and runtime
  generations, bounded record/history and reserved grid-cell budgets, literal
  validated argv/env/cwd, native spawn/exit status, terminal writes/resizes and
  bounded visible-screen retrieval. Keep native userdata private; returned
  metadata is copied, environment secrets are not enumerated, client connection
  lifetime never owns a terminal. Evict only completed history. Close all owned
  native terminals on server shutdown.
- [x] Add `lua/terminal/routes.lua` to the existing authenticated/policy-scoped
  control dispatch. Implement `/terminals` create/list, `/terminals/:id` get,
  `/input`, `/resize`, `/screen` and `/close`; mutating per-terminal requests
  require the exact runtime generation. Reject malformed JSON/options, unknown
  fields, unbounded pages/screens and unsupported operations. Keep route state
  owned by `control.start/stop` so the ordinary `boggart serve` command owns it.
- [x] Test the registry with actual native PTYs, Unicode/environment/literal
  arguments, native exit/failure, bounded capacity/eviction, resize budget,
  stale/unknown IDs, backpressure, retained output and deterministic close.
- [x] Test actual UDS requests and a separate `boggart serve --socket` process:
  client A starts a shell and disconnects; client B reads its existing output,
  sends input/resizes the same PID, sees natural exit and closes history. Verify
  policy/auth denial, non-destructive malformed requests and server shutdown.
  No remote model requests or new runtime.
- [x] Run relevant normal/sanitizer control/PTY/server tests, document API,
  evidence and limitations, update tracker criteria, review, commit and push.

Use the existing native `terminal.open`, libuv-owned process feeds and
shutdown handles. No worker thread, duplicate terminal parser, client-owned
lease, timer-per-pane, shell-expanded argv or transcript parser is introduced.
