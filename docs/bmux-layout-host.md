# Server-owned Bmux layout

The running control server owns a bounded workspace > surface > pane hierarchy
using `bmux.tree`. It starts empty. Creating a workspace adds one `Main` surface
with an empty pane. Empty panes are represented without a synthetic view on
the wire. Removing a workspace may leave the host empty; a workspace must retain
at least one surface.

The server/API increment is BMUX-80. Studio's
[Join layout](bmux-studio-layout.md) now attaches to this hierarchy. The cTUI
[consumer](bmux-ctui.md) also attaches to the shared hierarchy; restart persistence
remains BMUX-33.

## Control protocol

Both routes use the existing native HTTP/UDS authentication and control
capability policy. An owned private UDS works with `terminal.client`'s generic
`request` method; TCP uses the server's existing bearer-token policy.

| Route | Capability | Result |
| --- | --- | --- |
| `GET /layout` | `control:GET:/layout` | Copied full snapshot |
| `GET /layout/stream` | `control:GET:/layout/stream` | Initial snapshot and committed snapshots over native SSE |
| `POST /layout/commands` | `control:POST:/layout/commands` | Apply command and return the new full snapshot |

No query parameters are supported. A command is a JSON object up to 8192 bytes:

```json
{
  "host_id": "identity-from-GET-layout",
  "revision": 3,
  "op": "pane_split",
  "workspace_id": "workspace-2",
  "surface_id": "surface-1",
  "pane_id": 1,
  "direction": "right",
  "view": {"kind": "terminal", "terminal_id": "term-existing", "generation": 1}
}
```

`host_id` is random per server start; IDs and revisions may otherwise be reused
after restart. Every command requires the exact current host and revision.
Accepted commands increment revision once, including no-ops. A stale command
returns 409 without changes. After a conflict, fetch and inspect a fresh
snapshot. After an uncertain response, inspect the snapshot before deciding
whether another mutation is appropriate; mutations are not transparently
retried. The dedicated stream sends complete snapshots, rather than deltas;
reconnect starts from the current hierarchy without retained-history replay.
Its permission is separate from ordinary layout reads and broad `/events`.
Observers have no idle polling timer. Native server stop/revocation closes the
streams, and native connection/backpressure limits still apply.

## Commands

All commands include `host_id`, `revision` and `op`. Optional fields below use
`?`. Surface-scoped commands require both `workspace_id` and `surface_id`.

| Operation | Other fields | Effect |
| --- | --- | --- |
| `workspace_create` | `title` | Create workspace, default surface and empty pane; select workspace |
| `workspace_select` | `workspace_id` | Select existing workspace |
| `workspace_rename` | `workspace_id`, `title` | Change title |
| `workspace_remove` | `workspace_id` | Drop layout references; select first remaining workspace if needed |
| `surface_create` | `workspace_id`, `title` | Create empty surface and select it within that workspace |
| `surface_select` | workspace/surface IDs | Select within workspace |
| `surface_rename` | workspace/surface IDs, `title` | Change title |
| `surface_remove` | workspace/surface IDs | Drop surface references; select first remaining surface if needed |
| `view_add` | scope, `pane_id`, `view` | Add/select a tab |
| `view_close` | scope, `pane_id`, `view_id?` | Close named or active tab; collapse empty pane into sibling, retaining one final empty pane |
| `view_move` | scope, `pane_id`, `view_id`, `target_pane_id`, `index?` | Move/reorder a tab and follow it |
| `pane_split` | scope, `pane_id`, `direction`, `view?` | Split with an empty pane or referenced view |
| `pane_focus` | scope, `pane_id`, `view_id?` | Select pane and optionally one of its tabs |
| `pane_swap` | scope, `pane_id`, `target_pane_id` | Exchange contents and follow the moved selection |
| `pane_zoom` | scope, `pane_id` | Toggle zoom, or zoom a different pane |
| `split_resize` | scope, `split_id`, `ratio` | Set split ratio in `[0.01, 0.99]` |
| `balance` | scope | Reset all split ratios to `0.5` |

Named closure preserves background-tab selection and does not focus the tab
before removing it. Directions are `left`, `right`, `up` and `down`. An explicit tab index is
one-based, at most destination tab count plus one. Structural edits and focusing
a hidden pane restore the full tree before applying the operation. Each surface
retains its own selection; editing an inactive surface does not select its
workspace. Workspace/surface selection is explicit as described above.

## View references and snapshots

A view descriptor is either `{kind="terminal", terminal_id=..., generation=...}`
or `{kind="agent", agent_id=...}`, with optional `title`. Terminal references
must match an existing runtime generation and an open grid. Agent IDs must
already exist in the host's common Fleet registry; IDs may be strings or positive
integers. Execution remains with the registered runtime adapter. Unknown view
kinds and extra fields are rejected. Titles are nonempty valid UTF-8 up to 256
bytes without ASCII controls; emoji and combining sequences are accepted.

The server generates view IDs. Snapshot view records copy the descriptor plus
its ID; caller objects and returned snapshots cannot change owner state.
Snapshots have `v=1`, `host_id`, `revision`, `selected_workspace_id` and ordered
`workspaces`. A workspace has ID, title, `selected_surface_id` and surfaces. A
surface has ID, title, `focused_pane_id`, `zoomed_pane_id` and `tree`.

The tree always includes hidden zoom neighbours. Splits contain `id`, `type`,
`divider`, `a` and `b`; leaves contain `id`, `type="leaf"`, ordered `views` and
`active_view_id`. Empty collections encode as `[]`, absent selections as `null`.
Leaf IDs survive splitting; a collapse promotes the surviving sibling ID.
Re-resolve IDs after edits rather than keeping node objects. Pixel/cell bounds
belong to presentation and are excluded from server state.

Layout references grant no input lease, agent action or process-stop authority.
Moving, closing or removing them never spawns, resizes or kills a terminal.
Terminal dimensions still require the terminal controller's resize operation.
References may become unavailable if their independent runtime is later closed
or evicted; clients must present that state rather than recreate the process.

## Bounds and errors

Limits: 16 workspaces, 64 total surfaces, 256 total panes, 512 views, 32 tabs per
pane and depth 24 (root depth 1). Trusted construction can lower these limits.
All validation precedes mutation, including selection/zoom and ID allocation.

Errors retain the control surface's `{error="message"}` shape: 400 malformed or
unknown fields, 401 authentication, 403 policy refusal, 404 unknown references,
409 stale host/revision/runtime or removing a workspace's last surface, 413
layout capacity, 503 unavailable host or exhausted identity. Layout read and
write grants are separate; an accepted write returns the resulting full snapshot.

See [shared tree](bmux-layout.md), [design](superpowers/specs/2026-10-15-bmux-layout-host-design.md)
and [verification](benchmarks/2026-10-15-layout-host-verification.md).
