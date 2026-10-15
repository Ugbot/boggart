# Server layout implementation

- [ ] Add bounded workspace/surface ownership and canonical copied snapshots
  around `bmux.tree`, with independent selection per surface.
- [ ] Validate revisioned commands and references before mutations; cover
  rejection atomicity, zoom, identity, capacity and all structural operations.
- [ ] Install GET/POST routes through the existing control dispatcher and
  lifecycle; verify real UDS auth/policy, conflicts and unchanged native PIDs.
- [ ] Run normal/sanitizer model, control, terminal and Studio attachment checks;
  document contract/evidence, review, commit and push BMUX-80.
- [ ] Continue BMUX-31 with actual Studio/cTUI hierarchy consumers; keep the
  parent open until those consumers are verified.
