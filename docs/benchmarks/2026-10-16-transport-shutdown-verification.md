# BMUX-103: pending transport shutdown

The BMUX-102 separate-process harness reproduced an actual immediate-exit bug:
`joined:disconnect(); core.quit(true)` started a final detach request and returned
to native teardown. `lua_close` then ran luv's loop finalizer, which delivered
the cancelled connect after a pipe/timer userdata had already been finalized.
`terminal.transport` tried to close that finalized handle and crashed.

The minimal CLI regression `tests/terminal_transport_shutdown.lua` also exited
**139 before the fix** (`build/bmux-transport-exit-before.log`). Two original
Studio runs crashed in `luv_close` from the connect callback during `loop_gc`.

The transport now tracks pending operations and has an idempotent shutdown
gate. Native CLI, Studio and final worker teardown invoke it before `lua_close`,
while userdata are alive, then pump cancellation callbacks. Callback-created
replacement requests are refused without allocating a pipe/timer. Unused
transport modules do not get loaded or create a loop during teardown. Plain
workers still run ordinary asynchronous requests to completion before final
teardown; shutdown is not moved ahead of that worker contract.

Verification on the final fix:

- Normal focused CTest **10/10**, 19.29 s,
  `build/bmux-transport-exit-verified.log`.
- ASan/UBSan focused CTest **10/10**, 24.97 s,
  `build-asan/bmux-transport-exit-verified.log`.
- Actual minimal CLI and Studio pending-connect exit regressions now pass.
- Worker regressions cover both an abandoned pending connect and a normal
  asynchronous timeout completing after source return.
- Transport tests verify idempotence and refusal of callback-created work.

Suites: `worker`, `proc`, `terminal_process_shutdown`, `bmux_layout_client`,
`terminal_transport`, `terminal_client`, `terminal_transport_shutdown`,
`terminal_transport_workers`, `studio_bmux_layout`, `studio_transport_shutdown`.

BMUX-102's 100-pane workflow now passes normal shutdown and independently
exposes a 65/100 initial socket attachment limit (BMUX-104). That separate
capacity issue remains open; these focused shutdown results do not close the
system benchmark or comparative performance gates.
