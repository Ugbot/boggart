# Studio server-layout verification (BMUX-82)

Studio now joins the actual server-owned workspace/surface hierarchy through
`bmux.client`. RootView-derived replica nodes retain shared geometry/rendering
and send structural commands to the server. The view pool reuses native terminal
views, render contexts and attachment sessions by immutable view identity.

## Final gates

Normal and ASAN/UBSAN RelWithDebInfo builds passed on macOS arm64:
`build/studio-layout-recovery-build.log` and
`build-asan/studio-layout-recovery-build.log`.

```
ctest --test-dir build -R '^(studio.*|bmux_.*|terminal_process_studio)$' --output-on-failure
ctest --test-dir build-asan -R '^(bmux_tree|bmux_layout|bmux_layout_server|bmux_snapshot|bmux_layout_client|studio_bmux|studio_bmux_tree|studio_bmux_layout|studio_terminal_attached|studio_terminal_native|studio_terminal_vim|studio_chooser|studio_manual_agents|studio_fleet_keyboard|studio_agent_control)$' --output-on-failure
```

- Normal **31/31 passed**, 26.58 seconds:
  `build/studio-layout-final-verified.log`.
- Sanitizer **15/15 passed**, 18.10 seconds:
  `build-asan/studio-layout-final-verified.log`.
- Additional production pane-swap/real Ctrl-Alt-arrow coverage was added to the
  integration test afterward and rechecked separately in both builds:
  `build/studio-layout-routing-verified.log` and
  `build-asan/studio-layout-routing-verified.log`.
- The final creation/disconnect recovery branch and complete expanded workflow
  passed focused rechecks: normal 2.63 seconds and sanitizer 3.74 seconds,
  `build/studio-layout-recovery-verified.log` and
  `build-asan/studio-layout-recovery-verified.log`.
- `git diff --check` passed.

## Actual Studio behavior

`tests/studio_bmux_layout.lua` starts an independent daemon and uses real SDL
events and visible toolbar/header/tab controls. It verifies:

- Initial/delayed Join layout, full canonical server splits and native PID match.
- Reused view objects, render contexts and attachment IDs after server-driven
  swaps, surface selection, mode switching and layout-stream reconnect.
- One-command background-tab closure without focusing it, keyboard directional
  focus, pane-content movement, zoom/cycle and accumulated divider drags.
- Header control acquisition and SDL UTF-8 input/Return reaching the same PTY;
  returned output includes `ECHO:AFTER_JOIN 🦊`.
- Workspace/surface creation and selection, server shell creation/splitting,
  reference-only closure with the actual process still alive, and first-use New
  terminal initializing an empty host without spawning a local shell.
- EDIT and modal focus isolation, pending joins resuming after a dialog closes,
  hidden local dirty documents retaining unsaved-change tracking, and disconnect
  restoring original local tree IDs, focused content and native terminal object.
- Local agent profile selection retaining native Fleet registration and the
  preserved local tree. No remote execution capabilities are fabricated.
- A real terminal creation followed by observation loss before reference
  placement. The UI reports its retained server ID for explicit reconnect/Attach
  recovery, instead of silently dropping a successful creation.

The complete script also passed in a real SDL window with
`SDL_VIDEODRIVER` unset, isolated HOME and `BOGGART_STUDIO_SCRIPT` pointing to the
test. Logs: `build/studio-layout-real-sdl.log` and
`build/studio-layout-routing-real-sdl.log`; final recovery workflow log:
`build/studio-layout-recovery-real-sdl.log`. Inspected screenshot:
`build/testhome/studio_bmux_layout_real/joined-layout.png`.

## Reproduced failures and fixes

- A hidden dirty local document dropped out of `core.docs`; the failing
  `build/studio-layout-doc-before.log` case now passes. Hidden mode/zoom/local
  ownership remains visible to unsaved-change checks.
- A join completed while a dialog was open before a Bmux toolbar existed and
  then failed to resume. `build/studio-layout-pending-before.log` reproduces it;
  presentation now resumes through the existing RootView frame lifecycle, with
  no new polling timer.
- Motion coalescing moved drag deltas past the release event. Local and joined
  regressions reproduced the loss; the separate SDL ordering fix preserves
  adjacent motion order. See [motion evidence](2026-10-16-studio-motion-order-verification.md).
- The existing narrow-toolbar fixture expected eight controls; it now expects
  nine including Join layout, and verifies every wrapped control stays in bounds.

These are functional checks, not input-latency or GPU-instancing benchmarks.
The POSIX private-UDS integration test skips Windows. cTUI hierarchy presentation,
remote agent conversation/execution adapters and durable restart persistence
remain unfinished work; the overall Bmux goal and BMUX-31 remain open.
