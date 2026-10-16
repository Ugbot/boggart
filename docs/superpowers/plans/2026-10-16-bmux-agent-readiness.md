# Native agent readiness and server ownership

Continuation of the existing Bmux common-Fleet/agent-control design.

**Goal:** Agent sessions can remain owned by the server and expose their actual
state and capabilities to attached clients without another polling loop.

**Architecture:** Retain the bounded native channel and `agentcontrol` protocol.
Add a native notification hook and a Lua deferred watcher with the same lifetime
contract as terminal watchers. Use it in Studio now, and in the server agent
adapter next. Fleet remains the single provider-neutral roster; PTY and scheduler
owners remain unchanged.

## Native readiness contract

`channel:watch(fn)` replaces the sole callback and queues one initial delivery.
The callback receives its channel after native I/O returns, on the owning main
Lua thread. Complete received frames and transport closure schedule delivery;
multiple changes coalesce until that delivery. Taking frames or draining the
outbound queue does not generate notifications. Native queues and frame limits
remain unchanged. Callback failure removes only observation and records a
bounded error in `watch_state()`; the channel itself remains usable.

`watch(nil)`, explicit close, GC and interpreter shutdown cancel pending
callbacks. Callback/owner cycles remain collectable. Pending delivery keeps the
loop alive until handled; idle notification handles are unreferenced. EOF still
retains completed frames for the final callback. Observing a closed native
channel produces the initial state delivery without reviving it.

- [x] Add a native `bchannel_set_notify` hook with frame/EOF/error evidence in
  `tests/c/agent_channel.c`. C callbacks only schedule; they do not enter Lua.
- [x] Add Lua watch/watch_state and safe deferred lifecycle in `src/lchannel.c`.
  Verify actual controlled child processes, replacement, errors, EOF drain,
  GC cycles, self-close, coroutines and retained interpreter/worker shutdown.
- [x] Connect Studio's existing Boggart Fleet owner to readiness updates while
  preserving its process polling and foreign-provider observation behavior.
  Exercise actual TUI prompt/interrupt/approval/workers and channel-loss guards.
- [x] Run normal/sanitizer gates, record results, commit and push.

## Following server increment

Use `fleet.default`, `agentcontrol` and `fleetworkers` for server-owned agents;
public launch validates literal argv/provider/cwd and creates one native PTY.
A trusted terminal-registry bootstrap supplies its inherited private channel.
A shared process-observer seam must let attachment streams and agent lifecycle
observers coexist without replacing each other's terminal watch.

Bounded `/fleet` and `/fleet/stream` snapshots expose copied metadata and actual
capabilities, not transcripts, drafts, channel/pane tokens or execution objects.
Body-addressed commands carry opaque agent ID plus runtime generation and exact
input/request revisions. Retain accepted-vs-completed results and uncertainty;
never silently replay commands. Existing `/agents` scheduler API remains
compatible. Studio and cTUI then attach to these identities and controls instead
of inventing new owners from layout references. Provider-specific rich protocols
and durable server restart recovery remain separate work.
