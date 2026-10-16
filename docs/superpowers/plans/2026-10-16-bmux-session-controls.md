# Bmux session controls implementation plan

Execute inline on the existing feature branch, following the approved session
restore design and the delivered native checkpoint transfer boundary.

**Goal:** Make persistence status and checkpoint import/export usable through
Studio and terminal Bmux, with identical storage/execution semantics.

**Architecture:** `bmux.sessionfiles` bounds regular-file reads and exclusively
creates private exports. `bmux.sessionactions` owns asynchronous transfer/status
state over `bmux.sessionclient`. Studio and cTUI supply their existing dialogs,
keyboard/mouse selection and rendering. No background polling or new runtime.

**Constraints:** C/Lua and existing SDL3/native terminal; checkpoint limit 4 MiB;
no overwriting export destinations or saved names; import remains inactive across
restarts; no implicit mutation retry; session disconnect closes pending client
work. Existing local/remote PTYs and controller leases remain untouched.

- [x] Add regular-file, 4 MiB read and exclusive 0600 export helpers. Test large,
  malformed, FIFO/symlink and existing-file cases with real filesystem calls.
- [x] Add host-pinned typed persistence status observation. Add shared actions
  for status, export, import and saved-data inspection, preserving uncertain
  transfer state and exposing bounded errors to both presentations.
- [x] Add `core.bmuxsessions` and a Sessions toolbar/menu command. Reuse command
  view/chooser and path suggestions. Close its shared action owner on disconnect.
- [x] Add `bmux.tuisessions`, opened with Ctrl-B e and documented in help/footer.
  Reuse grapheme input; capture all modal input, including paste and mouse, and
  display operation/error/status information at narrow sizes.
- [x] Verify actual cTUI and SDL controls export/import files, inspect data and
  retain the current execution owners. Start imported data in a real daemon;
  verify fresh host, inactive resources and no marker execution.
- [x] Run normal and sanitizer relevant suites, inspect real SDL rendering,
  record evidence, review, commit and push. BMUX-97/33 remain open until explicit
  corrupt-session recovery and final acceptance are delivered.
