# Server-owned agent sessions

Continuation of the common Fleet/agent-control design and BMUX-86 readiness.

**Goal:** Launch and control one actual agent TUI on the server, keep its Fleet
and terminal identities across client detach, and let both clients observe it.

**Architecture:** `fleet.default` remains the common roster. A server agent host
binds `agentcontrol` and `fleetworkers` to native terminals in the existing
registry. Channel and process readiness drive publication. Terminal attachment
streams and Fleet lifecycle listeners share one registry-owned native watcher.

- [x] Add a bounded terminal observer broker in `terminal.registry`, switch
  `terminal.push` to it and cover real shared-reader/lifecycle/error/close cases.
  Add a trusted internal open bootstrap for agent IPC; public `POST /terminals`
  keeps its existing option schema. Verify and commit this independent seam.
- [ ] Implement a server agent owner: validate literal provider/cmd/argv/cwd,
  register once, launch once, bind the existing channel and mirror workers.
  Exits and Stop come from the native terminal owner. Closing a view or reader
  never stops the agent; server shutdown explicitly releases owned runtimes.
- [ ] Expose copied bounded Fleet snapshots and a dedicated native stream.
  Launch and runtime-control routes have separate existing control capabilities.
  Do not expose draft contents, execution objects, channel or pane secrets.
- [ ] Add host-scoped, bounded client sequence receipts for launch/control.
  First sequence is 1; subsequent sequences advance exactly once. Exact latest
  retries return the cached outcome, changed payloads and older/gapped sequences
  are rejected. Exhausting the client receipt bound rejects new clients; never
  evict high-water marks and accidentally repeat a spawn or accepted command.
- [ ] Verify real Boggart TUI/session/approval/worker control through independent
  clients, unknown foreign activity, stale generations/revisions/requests,
  subscriber permissions, stream revocation, reader coexistence and detach.
- [ ] Add attached-client Fleet and agent-view consumers with preserved runtime
  identities and honest capabilities. Keep BMUX-31 open until both clients work.

## Network contract

`GET /fleet` and `GET /fleet/stream` use separate read/stream capabilities.
Snapshots carry version, host ID, revision and copied agent metadata. Host ID is
pinned to the running layout/terminal host. Structured capabilities are supplied
by the actual runtime adapter. Foreign programs initially have process status
and explicit Stop only. Client-local focus uses the terminal reference; a server
cannot claim to have focused a window it does not own.

`POST /fleet/launch` accepts a bounded object with host/client/command sequence,
provider/name, literal cmd/args/cwd and geometry. Boggart's default command is the
host's actual sibling CLI plus `--tui`; explicit argv supports configured profiles.
`POST /fleet/commands` accepts the same sequence envelope and exact agent ID,
runtime generation, supported action and action-specific fields. Prompt requires
an observed input revision; approvals require an exact live request ID. Accepted
channel commands return their command ID; later Fleet results report whether the
owner accepted them. Launch acceptance and model/tool completion remain distinct.

Authentication, UDS ownership, peer credentials, Origin refusal and transport
budgets remain native. Every route passes existing control capability dispatch.
Existing scheduler `/agents` stays compatible. Provider-specific rich protocols,
manual-shell wrapper migration and durable server restart recovery remain work
beyond the initial server owner; they do not justify inferring capabilities.
