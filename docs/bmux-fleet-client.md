# Native shared Fleet client

`bmux.fleetclient` uses the existing owned-private-UDS `terminal.client` and
transport. Studio and terminal Bmux can share its observation and sequence
policy without another execution owner or provider runtime.

Construct with `socket`, optional `token`, an expected `host_id` when joining an
existing layout, and `on_change`. `start(callback)` observes the dedicated Fleet
stream; `view()` and `find(agent_id)` borrow read-only validated metadata.
`refresh(callback)` fetches a current snapshot; reconnect uses `start` after the
previous stream has ended. Host identity stays pinned across both operations.

`fleetsnapshot` copies and validates the whole bounded publication first: dense
arrays, unique IDs, UTF-8 labels, safe integers, terminal reference pairs,
capabilities, approval/result shapes and noncyclic bounded parent chains. A
retained same-generation row cannot change its terminal reference; higher
runtime generations are distinct. Informational session/model state can change
within a process. Malformed events retain the last coherent image and end the
stream. Old revisions are ignored and same-revision changes are refused.

Mutations use `launch(options, callback)` or
`command(agent_id, generation, action, payload, callback)`. The client validates
caller shapes and capabilities before transport, supplies its pinned host and
opaque command-client ID, and permits one outstanding mutation. Prompt uses an
observed input revision; approvals need an explicit request ID and decision.

Native HTTP errors now retain bounded JSON details as `error.response`, while
existing error messages/status remain compatible. The Fleet client uses the
exact receipt identity/sequence to advance after a consumed success or refusal.
A missing/malformed receipt on apparent success, or an ambiguous transport
failure, keeps the original bytes pending and blocks another mutation.
`retry(callback)` explicitly resends those exact bytes. Refresh and stream
reconnect only observe; they never clear uncertainty or replay a mutation.

A command-client ID allocates a server receipt slot only when first used for
mutation. Reconnecting the same object retains that ID and sequence. Optional
`client_id`/`sequence` construction supports trusted transfer of known state;
callers must not invent a sequence for an existing ID. `close()` cancels owned
transport/observation, never the server agent/terminal. It does not replay
pending work on a future client object.

See [server protocol](bmux-server-agents.md),
[client plan](superpowers/plans/2026-10-16-bmux-fleet-clients.md) and
[verification](benchmarks/2026-10-16-fleet-client-verification.md). Common-Fleet
presentation and attached Studio/cTUI controls remain BMUX-90 work.
