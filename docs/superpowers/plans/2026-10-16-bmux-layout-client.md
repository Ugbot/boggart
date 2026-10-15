# Shared layout client implementation

**Goal:** Studio and cTUI consume server-owned layouts through one validated
native client, preserving terminal execution and attachment identities.

**Architecture:** `lua/bmux/snapshot.lua` validates and projects snapshots;
`lua/bmux/client.lua` owns observation and revisioned requests;
`lua/bmux/server.lua` publishes on a dedicated native channel.

- [ ] Add strict bounded snapshot copies and projection into `bmux.tree`
  adapter nodes. Exercise malformed membership, cycles, sparse collections,
  reference identity, zoom and side-effect-free staging in `tests/bmux_snapshot.lua`.
- [ ] Add server layout streaming and client single-flight commands, monotonic
  publication, conflict refresh, explicit uncertainty recovery and teardown.
  Verify actual UDS observers and existing host/terminal policy tests in
  `tests/bmux_layout_client.lua`, normal and sanitizer builds; commit/push.
- [ ] Create `studio/data/core/bmuxlayout.lua` for a joined layout session and
  a RootView-derived replica node class. Route structural methods to server
  commands, stage snapshots and reuse views by immutable view ID/reference.
  Preserve local mode trees on join/disconnect, and update inactive Bmux stash
  without replacing an EDIT/AGENT/FLEET tree. Avoid modal focus theft.
- [ ] Expose Join layout, workspace/surface selection and disconnect controls;
  route Bmux terminal creation/splits through server when joined. Verify real
  SDL panes, tab/focus/move/resize/zoom, mode-switch/rejoin and same-PID input.
- [ ] Add the actual cTUI consumer and keep BMUX-31 open until both client
  adapters and cross-client updates are verified.
