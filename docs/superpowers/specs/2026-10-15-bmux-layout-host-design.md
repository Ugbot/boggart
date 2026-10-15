# Server layout owner (BMUX-80)

Continue the accepted shared-layout design: the running control server owns
workspace > surface > shared pane tree. Clients fetch copied snapshots and send
validated commands, rather than uploading replacement trees or becoming a
second owner. A surface remembers its selected pane/view and zoom. Terminal
processes and Fleet execution adapters remain independent owners.

Use `GET /layout` and `POST /layout/commands` through the existing authenticated,
policy-gated control dispatcher. Every command includes `host_id` and `revision`.
The random host identity prevents an old command matching a new server's reused
revision. Stale commands return 409 without effects; clients refetch and decide
whether to retry. No transparent retry of an uncertain mutation. Each accepted
command increments revision once, including a harmless no-op. Reject malformed
or failed commands before changing selection, zoom, counters or the tree.

Commands create/select/rename/remove workspaces and surfaces, add/split/focus/
close/move/swap views, resize a split ratio, balance and toggle zoom. A newly
created workspace contains one empty surface and pane. At most 16 workspaces,
64 total surfaces, 256 total panes, 512 views, 32 tabs per pane and tree depth 24
bound memory and snapshot size. Removals release layout references only. Closing
a terminal process remains an explicit terminal operation with its own policy.

Views are immutable descriptors with generated IDs and validated terminal or
Fleet agent references plus optional title. Reference validation does not grant
process/input authority. Snapshots include the full canonical split tree even
while zoomed, selected IDs and the zoomed pane ID. Pixel/cell bounds belong to
client presentation and are excluded from authoritative session layout.

Alternatives: client-owned copies lose concurrent edits; whole-tree replacement
requires validating arbitrary graphs and makes stable identities fragile.
Revisioned named commands reuse the actual shared model, keep effects narrow
and make conflicts explicit. A separate command module keeps boundary validation
out of the structural model. The server hierarchy is useful independently via
the control API; Studio attachment and cTUI tiling/switcher are subsequent real
consumers, still required before BMUX-31 can close. Restart persistence remains
BMUX-33.

Verification: descriptor commands and rejection atomicity, copied JSON snapshots
and hidden zoom neighbours; actual UDS HTTP policy/auth tests and competing
clients; a real server PTY retaining PID/input/output after layout edits and
client disconnect; normal and sanitizer builds plus existing shared-tree,
terminal-server and Studio attachment regressions.
