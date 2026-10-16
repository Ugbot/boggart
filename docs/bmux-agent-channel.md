# Boggart TUI control channel

Studio launches Boggart with one inherited socket endpoint, separate from its
PTY. `terminal.open{control=true}` creates a Unix socketpair and retains the
parent endpoint in a rooted userdata returned by `terminal:channel()`.
`bpty_open` preserves only the designated descriptor and the exec-error pipe.
Other process launches strip the bootstrap environment variable. This is a
local inherited capability, with no public socket path or TCP listener.

The child calls `agent_channel.adopt_env()` once. It removes
`BOGGART_AGENT_CHANNEL_FD`, verifies a stream socket and restores CLOEXEC so
executed tools do not inherit the endpoint. On unsupported Windows PTY builds,
channel creation returns ENOSYS; this does not implement ConPTY.

`src/bchannel.c` owns native framing and I/O; `src/lchannel.c` exposes
`send(bytes)`, `receive()`, `state()` and idempotent `close()`. Frames have a
four-byte big-endian payload length. Empty frames and lengths over 64KiB close
the receiver with EMSGSIZE. Each direction admits at most 128 frames/1MiB;
send overflow rejects the whole frame, receive overflow closes the channel.
Callbacks process at most 256KiB and never enter Lua. Completed frames remain
available after EOF; an incomplete frame reports EPROTO. Polling stops before
the descriptor closes, as required by [libuv's poll contract](https://docs.libuv.org/en/v1.x/poll.html).
Both entrypoints retire channel handles before luv destroys its loop.

`channel:watch(callback)` supplies deferred native readiness. It queues one
initial callback with the channel, then coalesces complete inbound frames and
EOF/error changes until delivery on the owning main Lua thread. Native I/O never
enters Lua. `watch(nil)` and explicit close cancel pending delivery; callback
failure removes observation and records a bounded error in `watch_state()`.
The transport remains usable after an observer error. A failing old callback
cannot disable a replacement installed during that callback.

An idle watch emits no periodic callbacks and its async handle is unreferenced.
Completed frames remain readable after EOF, including from the final callback.
Weak owner mappings keep callback/channel cycles collectable. CLI, Studio and
workers quiesce channel callbacks before teardown routines drain their loops,
then close native channel handles before luv destroys the loop.

Studio's Boggart adapter now refreshes its exact Fleet owner on channel
readiness through `registry:poll(agent_id)`. It drains the two bounded batches
needed for the native queue. Process and foreign-provider scans retain their
existing behavior. `tests/studio_agent_control.lua` disables periodic registry
polling during a real TUI handshake and verifies that readiness publishes the
original session's state and capabilities. See the
[readiness verification](benchmarks/2026-10-16-agent-readiness-verification.md).

Messages use JSON version `v=1`. The host first sends `bind` with an opaque
Fleet `id` and `generation`; a channel binds once. The TUI's `state` includes a
monotonic sequence, actual session ID/model, phase, draft byte count/revision,
supported actions and the current approval request. Draft contents and model
stream text are not copied into Fleet metadata. `lua/agentcontrol.lua` validates
the host side; `lua/tui/agentbridge.lua` owns the TUI policy.

A `command` supplies the bound ID/generation, a command ID and a strictly
increasing integer `command_seq`. Repeated or out-of-order sequences do not
execute. A `result` acknowledges acceptance or the rejection reason. Host
outstanding commands are capped at 32; there is no automatic retry/outbox.
Acceptance means the command entered the existing control path, not that a
model turn or tool has completed.

The TUI polls commands after buffered keyboard input drains. A prompt must
match the current input revision, find an empty draft and no owned dialog,
help/voice input or queued idle prompt. It starts `run_turn` on the existing
coordinator, or appends literal steering text to that session's bounded inbox
(32 messages/256KiB). Slash and shell syntax in a structured prompt remains
literal model input. Interrupt uses the existing turn-cancellation path.
The input revision advances when the draft changes, the coordinator's session
object is replaced, or that session's ID changes. The owner observes those
changes before reading commands, so a prompt prepared for an older conversation
cannot become input to the replacement, even when both drafts are empty. A
model metadata change alone preserves the input revision and runtime generation.
Approve/reject checks the current request's runtime-local identity before
setting its existing decision field. It does not widen the permission policy.

`core.fleetagents` combines native process status with semantic state. Exit
still comes from the native PTY. A lost/malformed channel removes semantic
capabilities and reports unknown activity while retaining focus/stop. The
existing Fleet also keeps foreign/custom processes whose adapters only know
process liveness.

## Keyboard controls in Fleet

Use **Up/Down** or **j/k** to select an agent, then **Tab / Shift-Tab** to move
through the toolbar and that agent's supported actions. The focused button has
an accent border; **Enter** or **Space** activates it. **Escape** returns to the
roster. Stopping agents uses the explicit Stop/Kill action. Space on the roster
retains the shell's leader shortcuts. Menus and text entry keep keyboard priority.

Send prompt and New agent use the existing command/chooser field. Submitting or
cancelling returns focus to the same action when it still exists. Pasted newlines
do not submit the field. New roster entries preserve the selected agent/action;
replaced runtime or approval identities drop focus rather than transferring a
pending activation. Unsupported or clipped actions do not enter traversal.
Toolbar/detail rows wrap in narrow windows. Mouse and keyboard use the same
action descriptors and existing owner checks; internal approvals also validate
the exact pending request object before deciding.

`tests/studio_fleet_keyboard.lua` sends SDL events through the real application
loop to a native Boggart TUI with deterministic local turns. It covers chooser
and prompt return, paste, interrupt, approval/rejection, worker cancellation,
foreign attention/focus/stop, in-process actor pause/resume/kill, narrow layout
and stale runtime/request actions. `tests/actionfocus.lua` verifies key-based
focus preservation, replacement, revocation and traversal. See the
[verification ledger](benchmarks/2026-10-15-fleet-keyboard-verification.md).

## Channel verification and worker reporting

Verification is in `tests/c/agent_channel.c`, `tests/agentbridge.lua`,
`tests/studio_agent_control.lua` and the normal launcher test. The Studio test
launches the actual TUI/session/scheduler/permission gate with local model
fixtures; it never calls a model API. It exercises keyboard draft contention,
stale revisions/generations/request IDs, steering, interrupt, approval and the
visible Fleet controls. Persistent server ownership, durable reconnect and foreign
structured adapters are not supplied by this channel.
[Manual shell registration](bmux-manual-agents.md) uses a separate native wrapper
and private local registrar.

The host requests `features.workers=true` in `bind` before the TUI observes or
reports child agents. Worker messages carry a separate ordered sequence and
bounded metadata: native session ID, per-start incarnation, parent session,
name/model, state and cancellation eligibility. Start/stop events retain even
workers that finish in one scheduler sweep; live scans backfill existing agents.
At most 512 live/dirty records are retained, with at most 32 reports per publish.
Completed pending records drop their coroutine/transcript references. Reporting
overflow or lost observation closes semantic control rather than claiming a
complete roster.

`lua/fleetworkers.lua` maps native worker references to opaque Fleet IDs beneath
their owning TUI. Child Cancel routes `worker_stop` through the same channel;
the receiver checks both session/incarnation and the actual scheduler actor
before using its supervisor. Responses attach to the child row. A worker's
pending approval is rejected/cleared when it is cancelled, so the owner's UI
does not stay parked. Natural completion, failure and cancellation release live
slots and preserve distinct final states. Finished worker history can be
evicted under the shared roster bound, and idle mirrors prune evicted references
when the registry eviction revision changes. Channel loss marks live workers
unreachable; process exit ends them without claiming successful completion.

Worker coverage: `tests/fleetworkers.lua`, the worker protocol cases in
`tests/agentcontrol.lua`, and `tests/studio_fleet_workers.lua` (actual TUI,
local-model workers, nested/short-lived/failing agents, visible Cancel clicks,
approval cancellation, repeated waves and loss/closure).

The full normal checkpoint passed 162/162 tests (225.31s); the expanded focused
normal run passed 18/18 (23.10s). Sanitizer checks passed 17/17 before the final
host failure guard. A regression then demonstrated that a failed protocol could
consume a later buffered state and republish capabilities. Failed hosts now
remain failed. The final bridge/host/launcher/real-TUI checks pass 4/4 normal
(2.26s) and ASAN/UBSAN. C11/Werror, attribution and diff checks pass.
Real SDL/Metal tests exercise the visible controls and channel-loss teardown.
No new Python implementation was added.

![A local-model fixture waiting for a real permission decision in the SDL Fleet view](images/bmux-fleet-approval.png)
