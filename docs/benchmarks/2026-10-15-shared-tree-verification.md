# Shared pane-tree verification (BMUX-78)

Studio now uses the actual `bmux.tree` node class for structural operations;
the production adapter supplies focus, close admission, dock measurements and
leaf body presentation. There is no mirrored structural tree. RootView loses
its duplicate split/close/find/move/zoom/resize implementation. Dock composite
sizes use split orientation; pane collapse skips docks when choosing focus.

## Evidence

macOS arm64, RelWithDebInfo normal and ASAN/UBSAN builds completed successfully:
`build/shared-tree-collapse-build.log` and
`build-asan/shared-tree-collapse-build.log`.

```
ctest --test-dir build -R '^(studio.*|bmux_tree|terminal_process_studio)$' --output-on-failure
ctest --test-dir build-asan -R '^(bmux_tree|studio_bmux_tree|studio_bmux|studio_terminal_native|studio_terminal_attached|studio_agent_control|studio_manual_agents|studio_fleet_keyboard|studio_fleet_agents|studio_chooser)$' --output-on-failure
```

- Normal: **26/26 passed**, 29.46 seconds,
  `build/shared-tree-final-verified.log`.
- ASAN/UBSAN: **10/10 passed**, 19.20 seconds,
  `build-asan/shared-tree-collapse-verified.log`.

`tests/bmux_tree.lua` runs with plain descriptors, covering stable leaf IDs,
split/collapse/empty closure, asynchronous moved/background close, tab movement,
pane swaps, directional focus, resize/balance, zoomed structural edits, locked
dock subdivision, orientation-aware dock bounds and nonnegative tiny geometry.
A deterministic 240-operation trace checks selection, unique IDs and no lost or
duplicated views through canonical saved zoom trees.

`tests/studio_bmux_tree.lua` checks function identity between production Studio
and descriptor classes, native terminal source identity, absence of temporary
placeholder focus during zoom/dock edits, deferred close after movement,
background close, shared tab/direction/swap/resize commands and tiny leaf bodies.
Existing mode-switch, shell, attached-terminal and Fleet tests exercise the
consumer integration rather than only importing the module.

The first broad normal run exposed an undersized test root fixture and the
chooser defect fixed separately in BMUX-79. A sanitizer run also exposed the
manual-agent fixture reading a newly created PID file before its contents were
written. That fixture now waits for a parsed PID before simulating wrapper loss;
the full final sanitizer gate above passes with this correction.

Real SDL window attachment verification uses isolated HOME and
`BOGGART_STUDIO_SCRIPT=tests/studio_terminal_attached.lua`, with
`SDL_VIDEODRIVER` unset. It exercises semantic input, exact native pixels/history,
control takeover, reconnect and same-PID reattachment. Log:
`build/shared-tree-final-real-sdl.log`. Rendered artifact:
`build/testhome/shared-tree-real/attached-pane.png`.

These are functional checks; their durations do not establish input latency or
hardware instancing. Workspace/surface containers, server-owned layout state,
the real cTUI adapter and persistence remain separate unfinished work.
