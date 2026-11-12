# Server layout implementation

**Goal:** Keep workspace/surface/pane state in the running control server while
terminal processes outlive all layout references.

**Architecture:** `lua/bmux/layout.lua` owns hierarchy and snapshots;
`layoutcommands.lua` validates and prepares structural mutations;
`server.lua` resolves host references and projects through the existing
`lua/control.lua` dispatcher.
No client or process ownership is added to the model.

**Tech:** C11+/Lua, existing native UDS/PTY runtime. Tests are
`tests/bmux_layout.lua` and `tests/bmux_layout_server.lua`, registered in CMake.

- [x] Add bounded workspace/surface ownership and canonical copied snapshots
  around `bmux.tree`, with independent selection per surface.
- [x] Validate revisioned commands and references before mutations; cover
  rejection atomicity, zoom, identity, capacity and all structural operations.
- [x] Install GET/POST routes through the existing control dispatcher and
  lifecycle; verify real UDS auth/policy, conflicts and unchanged native PIDs.
- [x] Run normal/sanitizer model, control, terminal and Studio attachment checks;
  document contract/evidence, review, commit and push BMUX-80.
- [ ] Continue BMUX-31 with actual Studio/cTUI hierarchy consumers; keep the
  parent open until those consumers are verified.
