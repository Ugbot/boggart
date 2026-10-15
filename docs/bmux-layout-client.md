# Native shared layout client

`lua/bmux/client.lua` observes the server-owned hierarchy through the existing
native private-UDS transport. It does not own PTYs or create a second mutable
layout authority. `lua/bmux/snapshot.lua` validates the full hierarchy before
publication and projects a selected surface into shared-model adapter nodes.
Actual Studio/cTUI hierarchy consumers remain BMUX-31 work.

```lua
local client=require('bmux.client').new{
  socket='/private/path/control.sock',
  on_change=function(client)
    -- Observe client.status/error and the borrowed read-only client:view().
  end,
}
client:start(function(why)
  if why then return end
  client:command('workspace_create',{title='Build 🦊'},function(error,snapshot)
    -- The acknowledged server snapshot, or an explicit error; no automatic replay.
  end)
end)
```

Use the same owned private socket/directory and optional bearer-token rules as
`terminal.client`. The observer needs `control:GET:/layout/stream`; refresh needs
`control:GET:/layout`; mutations need `control:POST:/layout/commands`. Layout
permissions confer no terminal input/control or process-stop authority.

`start(callback)` opens one native SSE observation with a full initial snapshot.
It can restart a disconnected observation, retaining the pinned host identity.
`command(op,fields,callback)` adds the pinned host/current revision, admits one
mutation at a time and rejects reserved fields or an oversized encoded body.
A conflict refetches without replaying. Network/server/protocol uncertainty
blocks another mutation until `refresh(callback)` succeeds. Refresh does not
reopen a disconnected observation; call `start` for that. A different host
identity requires explicitly creating/joining a new client.

`view()` and callback snapshots are borrowed read-only. `on_change(client)` also
runs for status changes, so renderers should compare host/revision before
rebuilding their projection. Valid older command acknowledgements cannot replace
a newer streamed snapshot. Same-revision content changes, mutated retained view
references and unexpected host identities are rejected. Invalid stream input
disconnects observation and preserves the last coherent snapshot. `close()`
cancels owned observation and requests without touching terminal processes.

The validator enforces the host's workspace/surface/pane/view/tab/depth limits,
dense collections, globally unique node/view IDs, valid UTF-8 labels and exact
selection/zoom membership. It copies only supported data; wire objects cannot
mutate the published hierarchy. Titles may change with a revision; runtime
references for retained view IDs may not.

`Snapshot.project(host_id, surface, Class, make_view)` takes a validated surface
and builds actual shared-model nodes without invoking focus. `make_view(desc)`
can reuse existing presentation objects by immutable view ID/reference. Empty
panes use the class adapter's placeholder factory, if supplied, without focus.
Node IDs are namespaced by host; `remote_id` retains the numeric server ID for
commands. Zoom projects the selected leaf with the canonical tree saved in
`zoomed`. The function returns root, selected presentation value and a map of
canonical nodes by server ID. Projection is staging; the renderer commits it
only after successful construction and handles cleanup of newly created views
if its own factory fails.

See [server protocol](bmux-layout-host.md),
[design](superpowers/specs/2026-10-15-bmux-layout-client-design.md) and
[verification](benchmarks/2026-10-16-layout-client-verification.md).
