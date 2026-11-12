# Native Boggart TUI control

BMUX-64 connects a launched Boggart TUI to its existing Fleet row without
creating a second conversation engine. C owns a private inherited Unix
socketpair, bounded framing and libuv lifetime. Lua owns the versioned messages,
session metadata and commands. PTY bytes remain human terminal interaction.

- Add native 64KiB frames, 1MiB/128-frame queues and a 256KiB callback budget;
  reject oversized/truncated input and retire raw handles before loop teardown.
- Preserve only the selected child control descriptor through PTY exec; adoption
  restores CLOEXEC and removes its bootstrap environment variable.
- Bind one Fleet ID/runtime generation, report the actual TUI session/model and
  idle/running/approval/question state, and expose only supported capabilities.
- Deliver literal prompts to the existing coordinator; check draft revision,
  empty human draft and dialog ownership atomically after keyboard input drains.
  Bound the steering inbox and reject replayed command sequences.
- Interrupt through the existing cancellation path. Approvals match the current
  live request identity and affect only that request; no synthesized Enter keys.
- Add Fleet Send prompt/Interrupt/Approve/Reject controls, request summaries and
  command acknowledgements. Foreign TUIs remain registered with process-level
  focus/stop until their provider adapters supply semantics.
- Verify transport failure/limits, normal TUI launch metadata, deterministic
  local-model turns through the actual TUI and permission gate, keyboard draft
  contention, same-session steering/cancellation, stale approvals and real UI
  clicks. Run normal, sanitizer and actual SDL window checks before saving.

This channel belongs to a Studio-launched process. It supplies no persistent
daemon, arbitrary already-running process attachment, or rich foreign-provider
API. Those remain separate parts of the BMUX roadmap.
