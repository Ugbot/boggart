# Server-owned agent sessions and Fleet

The control server can own actual Boggart TUIs and foreign programs in its native
terminal registry. They use `fleet.default`, the existing Boggart `agentcontrol`
channel and worker mirror. Disconnecting every observer leaves the same native
PID and Boggart session alive. Stop and server shutdown explicitly release the
execution owner. Closing an attached view remains reference-only.

The server/API and [joined Studio Fleet controls and agent views](bmux-studio-agents.md)
and [terminal-mode Fleet controls](bmux-ctui.md) are implemented. Existing
Studio local agent launching remains available.

## Routes and authorization

Each route passes the existing native authentication/peer/Origin rules and Lua
control capability dispatcher. Ordinary Fleet read, stream observation, launch
and runtime control are separate grants:

| Route | Capability | Result |
| --- | --- | --- |
| `GET /fleet` | `control:GET:/fleet` | Copied bounded metadata snapshot |
| `GET /fleet/stream` | `control:GET:/fleet/stream` | Initial and changed snapshots on a dedicated native channel |
| `POST /fleet/launch` | `control:POST:/fleet/launch` | One native process registration/launch receipt |
| `POST /fleet/commands` | `control:POST:/fleet/commands` | Generation-checked action receipt |

Query parameters are rejected. The existing scheduler `/agents` route remains
compatible. Snapshots carry `v=1`, the layout host's `host_id`, a monotonic
revision and ordered `agents`. Each row includes identity/generation,
provider/name/state/activity, actual supported control capabilities and bounded
available metadata: cwd/model, PID/outcome/byte count, native session ID,
input revision/draft byte count, current approval, worker parent/incarnation and
latest control result. Server-owned rows and their workers include
`terminal_id`/`terminal_generation` for attached views. Local window focus is a
client presentation action, so the server advertises no Focus capability.

Draft contents, transcripts, argv/env, execution objects, IPC and attachment
secrets are excluded. Labels are bounded valid UTF-8 with display controls
removed. A snapshot exceeding 1024 rows or the 4 MiB encoding budget is refused;
existing native connection/backpressure limits still apply. Changes coalesce
through an unreferenced async handle; there is no Fleet polling timer.

## Launch and control

All mutations require `host_id`, an opaque `client_id` of 1–64 ASCII word/dash
characters and a positive safe-integer `command_seq`.

A launch adds `provider`, optional `name`, literal `cmd`/`args`/`cwd` and optional
`cols`/`rows`/`history` using the terminal registry's existing bounds. Foreign
providers require an executable. Boggart defaults to the host CLI and `--tui`;
a Studio-hosted control server can configure its actual CLI with the trusted
`control.start{agent_executable=...}` option. Explicit argv supports configured
profiles. No command string is expanded by the launcher.

Boggart's optional `resume_id` uses its existing `--resume` path and is exclusive
with explicit argv. If that Boggart session is already owned and live, launch
returns its existing agent/terminal identities with `reused=true`. Acceptance is
separate from successful process startup: failed native launches retain their
failed Fleet/terminal records for inspection.

Controls add `agent_id`, `generation`, `action` and these action fields:

| Action | Required fields | Meaning |
| --- | --- | --- |
| `prompt` | `text`, observed `input_revision` | Literal prompt/steering through the existing TUI session |
| `interrupt` | none | Existing turn cancellation, preserving the process |
| `approve` | exact `request_id`, `decision` (`approve` or `reject`) | Existing live permission decision |
| `stop` | none | Release the owned process, or route exact worker cancellation |

The owner must advertise the action. Prompt revisions and live request identity
are checked at the host and again by the receiving TUI after human input drains.
An empty human draft remains an owner-side guard; input revisions also expire
when the coordinator session object or ID changes. A queued prompt can still be
rejected there. The immediate receipt includes the owner's `command_id` when an
asynchronous command was queued. Later Fleet `control_result` reports acceptance
or rejection. This does not mean the model turn or tool completed. Foreign
programs initially expose native liveness/Stop with semantic activity unknown.

## Retry contract

The first command sequence is 1. Each subsequent accepted sequence is exactly
the previous one plus one, across both mutation routes. An exact retry of the
latest request returns a copied cached outcome. Changed payloads, older requests
and sequence gaps return 409 without execution. Internal uncertain outcomes are
cached too; inspect Fleet rather than issuing a fresh launch blindly.

Successful responses and cached operation errors include
`receipt={client_id=...,command_seq=...}`. This marks consumption of that sequence,
even when the action was refused. Authentication, malformed-envelope/shape,
changed-host and stale/gapped-sequence refusals have no consumed receipt. Clients
must retain error response bodies to distinguish these cases. No automatic
command replay is supplied by the generic terminal request client.

At most 128 command clients are retained per host (trusted construction can
configure the bound). Their high-water marks are never evicted into a state
where an old launch could execute again. New clients receive 503 at capacity.
Connections can reuse their existing client identity/sequence after reconnect.
Receipts and native runtimes are not persisted across server restart; the new
host ID invalidates old requests. The [SQLite journal](bmux-journal.md) can reopen
ordinary Boggart profiles on their saved session IDs with fresh runtime owners.

See [server-agent plan](superpowers/plans/2026-10-16-bmux-server-agents.md) and
[verification](benchmarks/2026-10-16-server-agents-verification.md). Rich foreign
provider adapters, manual-shell wrapper migration and client import/recovery
controls remain separate work.
