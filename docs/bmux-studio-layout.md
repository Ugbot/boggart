# Join a server layout in Studio

Studio's Bmux mode can join the server's workspace/surface hierarchy, receive
live layout updates and send pane controls through the same server commands.
Terminal views and attachments retain their identities through rearrangement,
surface selection and Studio mode changes. This uses the existing private Unix
socket transport on POSIX hosts.

## Start and join

Start a server with an owned private socket directory, for example:

```sh
session_dir=$(mktemp -d /tmp/bmux.XXXXXX)
printf '%s\n' "$session_dir/control.sock"
./boggart serve --socket "$session_dir/control.sock"
```

In Studio, select **BMUX → Join layout** and enter that socket path. The Bmux
menu also exposes Join server layout. The toolbar shows the selected server
workspace, surface and connection state.

- **Workspaces** creates/selects server workspaces; **Surfaces** creates/selects
  a surface within the workspace. These selections are shared server state.
- **+ New terminal**, **Split right** and **Split down** create server-owned
  shells and add their views. On an empty server, New terminal first creates a
  workspace. Joined terminals initially observe read-only; use **Take control**
  in a terminal header to acquire input/resize rights.
- Tabs, close buttons, directional/cycle focus, zoom, balance and divider
  dragging send layout commands. Closing a named background tab is one command
  and preserves the foreground selection. Drag deltas coalesce while a command
  is in flight; failed/conflicting commands discard queued intent.
- **Refresh / reconnect** recovers layout observation. Existing terminal
  attachments and input leases remain independent of the layout stream.
- **Disconnect layout** restores the local Bmux tree, terminal objects and
  focused content that were present before joining.

Local terminal Close ends its owned process. Joined layout Close removes a view;
the server terminal remains available under **Attach**. Disconnecting Studio
also leaves server processes alive. Ending a shell from inside its terminal is
still a normal process action after taking control.
If placement of a newly created shell cannot be confirmed, Studio reports its
server terminal ID. Reconnect and inspect the layout/Attach list; creation is
not replayed automatically.

The **+ Local agent** chooser retains the existing native agent launcher and
Fleet registration. Selecting a profile returns to the preserved local Bmux
layout and launches there; cancelling the chooser leaves the joined layout in
place. Server agent references display an unavailable-view notice until their
conversation/execution adapter is implemented. No remote agent capabilities
are inferred from layout references.

## Ownership and presentation

`core.bmuxlayout` owns the joined client, staged projection, retained local tree
and view pool. `core.bmuxlayoutnodes` derives a replica class from RootView's
presentation/shared geometry and sends edits to the server. Local nodes keep
their original class. Snapshot node IDs are host-namespaced; numeric `remote_id`
values address server commands. The client changes the displayed tree only
after validated server publication.

Mode switching preserves the replica class and full zoom tree in the Bmux
stash. Updates to an inactive Bmux layout do not replace EDIT/AGENT/FLEET content.
Open dialogs retain focus; deferred joins/updates resume on an existing UI frame
without a polling timer. Hidden local/mode/zoom trees keep document references
in unsaved-change tracking. Failed projection keeps the previous display and
can be retried with Refresh.

See [native client](bmux-layout-client.md), [host protocol](bmux-layout-host.md)
and [verification](benchmarks/2026-10-16-studio-layout-verification.md).
Actual cTUI hierarchy presentation remains BMUX-31/BMUX-35 work; durable restart
restore remains BMUX-33.
