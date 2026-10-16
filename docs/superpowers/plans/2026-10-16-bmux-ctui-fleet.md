# Terminal Bmux Fleet implementation plan

Continuation of the approved agent-control design and attached-client plan,
BMUX-93. Inline implementation; C/Lua, existing native transport and PTY owners.

**Goal:** Launch and control server agents from terminal Bmux with parity to the
joined Studio Fleet, preserving process/session ownership across views.

**Architecture:** `bmux.tuifleet` owns the shared Fleet client/source and modal
presentation. `bmux.tui` resolves agent references to native attachments and
routes modal events before terminal input. Existing grapheme composer edits
bounded prompts. `bmux.agentviews` shares runtime-reference lookup with Studio.

- [x] Share layout lookup for agent/native terminal references. Resolve active
  agent views in terminal Bmux; replace attachments only on runtime binding
  changes. Start Fleet observation after the layout pins its host.
- [x] Add Ctrl-B f Fleet and Ctrl-B a launcher. Preserve selected runtime across
  stream updates; draw clipped rows/actions with keyboard and pointer access,
  including narrow terminals. All modal events are consumed before PTY input.
- [x] Add Boggart/resume/Codex/Claude/custom literal-argv profiles, structured
  prompt, interrupt, exact approval, worker cancel, foreign Stop confirmation,
  existing-view Focus and explicit uncertain-command Retry. Capture prompt
  runtime/session/input revision; retain editor text on known refusal.
- [x] Verify actual CLI in a native PTY against the real daemon: launch and
  native output, emoji editing, prompt/draft isolation, stale approval, worker
  controls, foreign Stop, narrow layout, modal paste isolation, unchanged runtime
  after reference close/detach/rejoin, termios restoration. Run normal and
  sanitizer gates plus joined Studio regression; record evidence, commit/push.

The actual CLI launch test may provide the existing fixture TUI executable as a
custom profile to avoid a model API. No new provider/model mock replaces native
transport, session/channel, terminal ownership or input. Fault injection for
lost acknowledgements stays at the already-tested shared client boundary.
