# Server-owned agents verification (BMUX-89)

The server launches actual Boggart and foreign TUIs in its native terminal
registry and common Fleet. Channel/process readiness drives copied metadata
snapshots, worker mirrors and runtime controls. Host/client sequence receipts
make exact launch/control retries return cached outcomes without re-execution.

Normal and ASAN/UBSAN RelWithDebInfo builds passed on macOS arm64. The broad
normal affected set passed **64/64**, 46.00 seconds, in
`build/bmux-server-agents-regressions.log`. The sanitizer native/Fleet/client set
passed **19/19**, 29.18 seconds, in
`build-asan/bmux-server-agents-regressions.log`.

After adding final error-receipt metadata, the complete expanded real-daemon
fixture and existing control suite passed **2/2** in each build: 1.36 seconds
normal and 1.92 seconds sanitizer, `build/bmux-server-agents-receipts-verified.log`
and `build-asan/bmux-server-agents-receipts-verified.log`. Diff checks passed.

Final assertions also inspect actual output in the original TUI: the local
model answer and gated-tool rejection must appear in its streamed native cells.
The complete fixture passed in `build/bmux-server-agents-output-verified.log`
and its sanitizer counterpart after those assertions were added.

## Actual behavior exercised

`tests/bmux_server_agents.lua` starts an independent native daemon, two Fleet
streams and an actual Boggart TUI with deterministic local model turns. No model
API is called. It verifies:

- Separate read/stream/launch/control grants, authentication and stream revocation;
  invalid fields/types/geometry/JSON/oversized bodies allocate no terminal.
- Copied cached outcomes, changed-payload/old/gapped sequence refusal, bounded
  client high-water marks and non-reexecution after an uncertain internal error.
  HTTP error bodies explicitly report consumed receipts.
- One PID/session/terminal for launch retries and live-session resume, metadata
  without IPC/attachment secrets or human draft contents.
- Real prompt delivery, owner acknowledgements, stale revision refusal and
  owner-side rejection while a human draft is present. Exact live approval IDs
  and Reject route through the existing permission gate.
- Server-routed interrupt cancels the actual running turn and returns to idle
  with the same native PID/session. Final expanded logs are
  `build/bmux-server-agents-interrupt-verified.log` and its sanitizer counterpart.
- Nested/short-lived/failing/live workers share the common roster and original
  terminal reference; exact worker cancellation returns actual owner results.
- Every client can detach, then new clients rejoin the original PID/session.
  Native terminal readers coexist with lifecycle observation.
- Foreign programs advertise process-only activity/Stop, with structured prompt
  unavailable. Stale runtime generations cannot stop another execution.
- Frozen terminal eviction remains independent of Fleet history, listener
  failures preserve other registry subscribers, and server shutdown releases a
  remaining owned process rather than leaving it behind.

The existing Studio/Fleet/native terminal suites in the broad set remain green.
This is the server API increment; joined Studio/cTUI Fleet and agent-reference
consumers remain BMUX-90/BMUX-87 work. Rich foreign adapters, manual-shell wrapper
migration, internal scheduler source integration and durable restart recovery
remain follow-up work. No comparative latency/RSS claim is made by these tests.
