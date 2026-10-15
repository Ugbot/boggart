# Server layout host verification (BMUX-80)

The running control server now owns workspace/surface containers and actual
shared `bmux.tree` nodes. Authenticated, policy-gated control routes expose
copied canonical snapshots and revisioned commands. Terminal and Fleet runtime
ownership remains independent of layout references.

## Final verification

macOS arm64, normal and ASAN/UBSAN RelWithDebInfo builds completed successfully:
`build/layout-host-reviewed-build.log` and
`build-asan/layout-host-reviewed-build.log`.

```
ctest --test-dir build -R '^(bmux_tree|bmux_layout|bmux_layout_server|control_unix|terminal_server|terminal_client|studio_bmux_tree|studio_terminal_attached|studio_manual_agents)$' --output-on-failure
ctest --test-dir build-asan -R '^(bmux_tree|bmux_layout|bmux_layout_server|control_unix|terminal_server|terminal_client|studio_bmux_tree|studio_terminal_attached|studio_manual_agents)$' --output-on-failure
```

- Normal: **9/9 passed**, 10.46 seconds,
  `build/layout-host-reviewed-verified.log`.
- ASAN/UBSAN: **9/9 passed**, 13.85 seconds,
  `build-asan/layout-host-reviewed-verified.log`.
- `git diff --check` passed.

An additional body-bound check pads an otherwise valid workspace command past
8192 bytes, so another validation failure cannot mask a missing size gate.
The expanded `bmux_layout_server` test passed again in both builds:
`build/layout-body-bound-verified.log` and
`build-asan/layout-body-bound-verified.log`.

The initial model test failed because `bmux.layout` did not exist
(`build/layout-before.log`). `tests/bmux_layout.lua` now verifies every command,
workspace/surface selection, independent surface focus, stable view/pane IDs,
terminal/Fleet descriptors, full hidden zoom trees, empty-pane zoom, copied
input/output and JSON snapshots. It checks malformed fields/references,
host/revision conflicts and invalid ratios without changing owner state or ID
allocation, plus isolated view/pane/depth/tab capacity cases. Trusted invalid
limits fail explicitly, and revision exhaustion leaves owner state unchanged.

`tests/bmux_layout_server.lua` uses real native UDS clients and a separate
daemon. It proves:

- Read-only layout capability cannot mutate layout or create terminals.
- Layout-write capability can reference existing Fleet agents and terminals,
  but cannot send terminal input or close processes.
- Authentication, unknown references, stale terminal generations, closed grids,
  malformed/oversized bodies and unsupported queries are rejected.
- Competing clients cannot overwrite newer revisions or a different server
  identity. An independent client sees the canonical zoom tree after disconnect.
- Moving/closing views and removing the workspace retain the same native PIDs.
  Layout divider changes do not resize the terminal grid. After all layout
  references disappear, leased Unicode input still reaches the same running PTY
  and its output returns through the native attachment stream.
- Server shutdown still retires its owned children.

## Failed preliminary observations

The first new UDS fixture opened a client before socket permissions became
private; it now waits for the owned socket's private mode. Its decoded empty
array check also uses collection length rather than the encoder sentinel.

Earlier concurrent normal/sanitizer gates hit large host scheduling delays,
including a pure model test that printed its pass message before shutdown timed
out, and curl receiving no bytes for over 23 seconds. A read-only process check
confirmed substantial unrelated VM/JVM/benchmark CPU use. Those runs are not
counted as passes. No application lease, test deadline or acceptance threshold
was relaxed. The sequential final gates above both passed.

These functional durations are not input-latency or rendering benchmarks.
Actual Studio/cTUI hierarchy attachment, layout change streaming and durable
restart restore remain outside this increment; BMUX-31 and BMUX-33 remain open.
