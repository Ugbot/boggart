# Shared layout clients

Continue BMUX-31's accepted one-model/two-renderers design. The server remains
the layout authority. First add a dedicated `GET /layout/stream` through the
existing authentication/capability dispatcher. It sends a full initial snapshot
and full snapshots after accepted layout commands, using a host-specific native
SSE channel. Read-only observers do not keep timers or poll. Connection setup
and initial snapshot capture happen in the same serialized event-loop turn.
Server stop/revocation uses existing native stream teardown.

`bmux.snapshot` validates/copies hierarchy input before any presentation changes:
host identity, revision, bounded dense collections, unique node/view IDs,
depth/total resource limits, UTF-8 titles, view references, tab selection and
workspace/surface/focus/zoom membership. It can materialize a selected surface
as actual shared-model nodes with an adapter's existing views. Projection builds
nodes without placeholder focus changes. Zoom keeps the full canonical tree.

`bmux.client` uses `terminal.client`'s native private-UDS requests. It pins the
initial host identity, accepts monotonically increasing revisions, validates
immutable references for retained view IDs and publishes only whole valid
snapshots. One mutation is in flight; conflicts refetch without replay. Network
or protocol uncertainty requires an explicit refresh before another mutation.
Client close cancels owned requests and observation, without touching PTYs.
An older valid command acknowledgement must not replace a newer stream snapshot.

Alternatives: polling adds idle work and stale intervals; using broad `/events`
would require unrelated event permissions; optimistic client trees add a second
authority and rollback policy. Dedicated native full-snapshot streaming is
bounded by the existing hierarchy caps and makes reconnect independent of
retained delta history. Performance of large full snapshots remains measurable
work; this is not a claim of an input-latency improvement.

Studio then attaches an actual Bmux surface to these validated nodes. A replica
node class inherits RootView presentation and shared geometry, but routes layout
edits to the server. Existing local nodes keep their original class/behavior.
Terminal views are reused by immutable view ID and runtime reference; removing
a view detaches its observer, never closes the server PTY. Agent references
must be represented honestly even when conversation rendering is unavailable.
Workspace/surface selectors and join/disconnect controls are visible in Bmux.
Mode switching must preserve the remote tree, including zoom and hidden views.
Updates received while a modal owns input must not steal focus.

The cTUI consumes the same validated snapshots and structural projection for
tiling or narrow-screen switching. Neither client can close BMUX-31 merely by
importing the module; actual visible consumers and command paths must be tested.
Persistence remains BMUX-33.

Verification: malformed/cyclic/sparse/oversized snapshot rejection without
partial publication; projection with stable IDs and no focus side effects;
actual native server clients, stream policy separation, independent observers,
conflict/refetch, uncertain completion, epoch changes and resource teardown.
Studio follow-up requires real SDL split/focus/zoom/move controls, retained
terminal identity and input, mode switching and server-driven updates.
