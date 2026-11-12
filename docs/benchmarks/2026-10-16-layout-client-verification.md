# Layout observation and projection verification (BMUX-81)

`GET /layout/stream` now publishes initial and committed full snapshots on a
host-specific native SSE channel. `bmux.client` validates and observes them,
pins host/reference identity and serializes writes. `bmux.snapshot` copies the
bounded hierarchy and stages shared-model nodes without focus changes.

## Evidence

Normal and ASAN/UBSAN RelWithDebInfo builds passed on macOS arm64:
`build/layout-client-build.log`, `build-asan/layout-client-build.log`.

```
ctest --test-dir build -R '^(bmux_tree|bmux_layout|bmux_layout_server|bmux_snapshot|bmux_layout_client|control_unix|serve_streams|terminal_server|terminal_client|studio_bmux_tree|studio_terminal_attached|studio_manual_agents)$' --output-on-failure
ctest --test-dir build-asan -R '^(bmux_tree|bmux_layout|bmux_layout_server|bmux_snapshot|bmux_layout_client|control_unix|serve_streams|terminal_server|terminal_client|studio_bmux_tree|studio_terminal_attached|studio_manual_agents)$' --output-on-failure
```

- Normal **12/12 passed**, 8.89 seconds: `build/layout-client-verified.log`.
- Sanitizer **12/12 passed**, 14.00 seconds: `build-asan/layout-client-verified.log`.
- `git diff --check` passed.

The initial test failed on the absent module (`build/snapshot-before.log`).
`bmux_snapshot` now covers copied structures, malformed/cyclic/sparse/deep input,
bad Unicode/references/IDs/selection/ratios, collection bounds, canonical hidden
zoom neighbours, stable projection identity, reused view objects and empty-pane
staging without focus callbacks.

`bmux_layout_client` uses actual native private-UDS connections and an independent
daemon. It verifies separate stream policy, no idle polling timer, initial and
host-driven publication, malformed events preserving the prior snapshot,
explicit host pinning, revoke/disconnect, two clients competing on one revision,
exactly one commit followed by conflict/refetch without replay, pre-transport
command bounds, immutable retained references and monotonic publication.

For uncertainty, the real server commits a command and a fixture discards only
its acknowledgement. The client blocks another mutation; explicit refresh sees
the single committed result. Leased Unicode terminal input still reaches the
same native PID. Closing one client leaves the other observing and editing;
owned request counts return to zero, and server shutdown retires its child.

Existing native stream, terminal-server/client and Studio tree/attachment/manual
agent regressions remain passing. These are functional checks; durations do not
establish input latency. Large full-snapshot cost, actual Studio/cTUI hierarchy
consumers and restart persistence remain separate unfinished work.
