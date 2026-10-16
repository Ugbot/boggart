# Native Bmux terminal client verification

BMUX-83/84 add complete native canvas clusters and `boggart bmux --socket`.
The actual CLI is exercised inside a native PTY, against an independent control
host. The Studio integration runs another actual CLI and checks both renderers
against the same daemon and original terminal PIDs.

## Reproduced failures and corrections

- The first canvas passed numeric attributes to a table-valued Lua binding.
  `build/bmux-ctui-first-test.log` reproduces it; attributes now use the binding's
  existing shape without another terminal style API.
- Lone Escape waited for another input byte, leaving help open indefinitely.
  `build/bmux-ctui-second-test.log` reproduces it. Incomplete Escape sequences
  now arm one 30 ms libuv timer, not a periodic input poll. Bracketed-paste end
  markers crossing reads are retained and tested as well.
- The cross-client fixture caught a dropped zoom immediately following focus
  while its acknowledgement was pending. `build/bmux-ctui-final-tests.log`
  reproduces it. Bounded pending input now waits for command completion and
  resolves against the latest confirmed tree. The SDL test sends focus+zoom in
  one write; errors/disconnection clear pending input rather than replaying it.
- Native Vim repeatedly started in its More pager after a new view was updated
  with zero layout size. The captured process was alive in alternate screen;
  `build/bmux-ctui-vim-diagnostic.log` contains the actual screen and state.
  TerminalView now retains PTY geometry until it has positive presentation
  area. An explicit unarranged-view assertion and actual Vim edit/save cover it.

## Behavior covered

`tests/bmux_ctui.lua` checks actual emitted combining/ZWJ/flag clusters, read-only
attachment, control conflict and explicit takeover, server-native text/keys and
fragmented paste, reader-only resizing, SIGWINCH-driven narrow/expanded display,
focus/zoom, terminal creation, reference-only closure, observation reconnect and
clean detach. A shell wrapper compares `stty -g` before and after the real CLI;
its exit fails if raw terminal mode is not restored exactly.

`tests/studio_bmux_layout.lua` now also checks actual cTUI focus+zoom updating
Studio and Studio's pane swap updating the terminal display. Both clients keep
the same server PTYs. The complete workflow passed in a real SDL window with
`SDL_VIDEODRIVER` unset: `build/bmux-ctui-real-sdl.log`. Its inspected screenshot
is `build/testhome/studio_bmux_ctui_real/joined-layout.png`.

`src/termctl_test.c::clusters` checks actual ANSI output and exact snapshots,
full native cluster capacity, UAX/native-profile differences, changed suffix
repainting, no-op diffs, replacement of either wide half, clipping, clear and
invalid/control rejection. Normal and sanitizer standalone worker checks also
passed; integrated gates are the authoritative combined verification.

## Final gates

- Normal **33/33 passed**, 37.30 seconds:
  `build/bmux-ctui-geometry-verified.log`.
- ASAN/UBSAN **16/16 passed**, 25.13 seconds:
  `build-asan/bmux-ctui-geometry-verified.log`.
- Final help-overlay paste isolation and input-prefix reset checks use
  `build/bmux-ctui-modal-verified.log` and the matching sanitizer log. They cover
  the complete CLI and shared Studio workflow after that final input guard:
  **3/3 passed** in each build (5.59 seconds normal, 8.21 seconds sanitizer).
- `git diff --check` passed.

These are functional and memory-safety checks on macOS arm64, not comparative
latency/GPU benchmarks. General external-terminal/font parity, remote agent-pane
adapters and durable server restart restore remain separate work.
