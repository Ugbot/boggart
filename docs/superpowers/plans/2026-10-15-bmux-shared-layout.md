# Shared Bmux layout implementation plan

**Goal:** Share authoritative layout operations across Studio, cTUI and the
terminal host, preserving existing terminal processes through rearrangement.

**Tech:** C11+/Lua/SDL3; pure Lua tree policy with renderer-specific adapters.
Continue the accepted session-host design and standing commit/push instruction.

- [x] BMUX-78: Create `lua/bmux/tree.lua`, a class factory with adapters for
  empty/placeholder views, focus, close admission and presentation. Preserve
  RootView's node shape (`leaf/hsplit/vsplit`, views, active_view, a/b, divider,
  position/size). Add stable node IDs. Test split/collapse, last close, deferred
  close after focus/move, locked docks, directional traversal, tiny geometry,
  balance, zoomed edits, tab movement and pane-content swap with plain values.
  Run `ctest -R '^bmux_tree$'` in normal and sanitizer builds.
- [x] Replace structural RootView methods with that model; retain rendering,
  tab/dock presentation and platform focus in the adapter. Route pane move and
  divider drag through shared operations. Run `studio_bmux`, `studio_terminal_*`,
  `studio_agent_control`, `studio_manual_agents` and Fleet keyboard regressions.
  Document the model contract and verification, commit and push the increment.
- [ ] Add workspace/surface containers around that same tree with a shared
  server-owned descriptor representation. Connect both Studio and cTUI to the
  hierarchy, preserving focus/geometry and independent terminal identities.
- [ ] cTUI consumes the shared model for tiling and narrow-screen presentation;
  verify actual termctl frames and split/focus/zoom operations. Server owns the
  session's layout; clients only keep validated presentation snapshots.
- [ ] Record remaining ownership/protocol/restore gates explicitly and close
  BMUX-31 only after real Studio, cTUI and server consumers are verified.
