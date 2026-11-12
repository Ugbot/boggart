# Attached Fleet and agent views

Continuation of the approved common Fleet/server-agent design, BMUX-90.

**Goal:** Joined Studio and native terminal Bmux views launch and control the
actual server-owned agents while preserving local Fleet entries and owners.

**Architecture:** One `bmux.fleetclient` owns validated observation and sequence
receipts. `bmux.fleetsnapshot` copies bounded metadata and validates identities.
Presentation adapters mount remote rows in the existing Fleet and display their
referenced native terminals. No adapter starts another runtime for an agent view.

- [x] Add strict Fleet snapshot validation and a shared native client. Retain
  bounded HTTP error bodies on native request errors, without changing existing
  error messages. Pin host/runtime terminal references; preserve coherent state
  after malformed or stale publication. Distinguish informational session changes
  from process/runtime identity.
- [x] Add single-flight launch/control with exact consumed receipts. Cache the
  uncertain request bytes for explicit Retry; reconnect/refresh only observe.
  A missing/invalid receipt on apparent success remains uncertain. Validate
  caller shapes before transport; never silently skip a command sequence.
- [x] Add source-owned record lookup/control to the existing Fleet registry,
  keeping local/internal sources and process owners intact. Mount namespaced
  remote rows with stable objects until their runtime changes, invalidate stale
  actions on generation/request replacement and disable execution on disconnect.
- [x] Studio: joined New agent launches on the server; retain explicit local
  launching. Agent layout references use their published terminal reference,
  Fleet Focus reveals it, and existing Fleet prompt/interrupt/approval/Stop
  widgets route through the shared client. Closing/disconnecting releases views.
- [x] cTUI: a compact Fleet overlay and launcher provide the same server agent
  actions; compose text with grapheme-safe editing and keep drafts isolated from
  terminal typing. Existing pane input/leases stay with their native owner.
- [x] Exercise both actual clients against one real daemon: launch, model output,
  draft contention, approvals, worker cancel, foreign processes, narrow display,
  generation/request expiry, lost acknowledgements, all-client detach/rejoin and
  exact PID/session preservation. Record evidence, commit and push each slice.

Client IDs allocate a server receipt slot only when first used for mutation.
Stream reconnect reuses the same client/sequence and pending bytes. Explicit
Disconnect closes the transport and never automatically replays a command on a
new connection. Host changes require a fresh explicit join.
