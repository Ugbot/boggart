# BMUX-30 server terminal verification

2026-10-15, macOS arm64, branch `feature/bmux-termbench`.

The dedicated `boggart serve` process now holds a Lua registry of existing native
PTY/grid objects. HTTP clients only address opaque IDs. All I/O remains on the
native libuv loop, with no worker thread, per-terminal timer or new runtime.

## Acceptance evidence

`tests/terminal_registry.lua` uses actual native PTYs to verify:

- Literal executable/argv, cwd and environment; Unicode input/output.
- Copied lifecycle metadata without enumerating environment values or argv.
- Ownership through garbage collection, exit 7 and retained final cell output.
- Exact generation guards; bounded input, listing/screen pages and grid budgets.
- Live records are not evicted; completed history alone is evictable.
- Resize rejection preserves geometry; completed grids remain resizable.
- Explicit/idempotent close, inspectable launch failures and shutdown/reaping.

`tests/terminal_server.lua` exercises real HTTP-over-UDS requests with the
existing policy/authentication dispatch. Scoped clients cannot create terminals;
missing bearer credentials are refused before routing. Malformed JSON, wrong
types, unknown fields, invalid pages/dimensions and stale generations are
rejected without starting a process or killing a live one.

The same test starts a **separate actual `boggart serve --socket` process** with
a private fresh home. Client A creates a shell and disconnects. Independent
requests then observe the **same PID and generation**, resize it from 40x6 to
72x12, deliver `FROM_SECOND_CLIENT 🦊`, read that output and `stty size`'s
`12 72`, and observe the actual native exit code 7. Closing the grid leaves
inspectable lifecycle metadata. A second child ignores HUP; SIGTERM of the idle
daemon runs shutdown, removes the owned socket and reaps that child. This
establishes live server ownership across client disconnects, not automatic
Studio attachment, ordered replay or recovery after server death.

No model prompt/API call is made. The first server test failed in its fixture
while trying to JSON-decode the native transport's existing plain-text 401
response. The helper now accepts non-JSON error responses while still requiring
JSON on success; the policy/authentication checks pass without production auth
changes. No deadlines were loosened to obtain a passing result.

An explicit `/bin/pwd` assertion was then added to verify the child's actual cwd
rather than relying on metadata; the registry test passed again in normal
(0.13s) and sanitizer (0.25s) builds without production changes.

## Verification commands

```sh
CCACHE_DIR=/private/tmp/boggart-bmux-ccache CCACHE_TEMPDIR=/private/tmp cmake --build build -j8
CCACHE_DIR=/private/tmp/boggart-bmux-ccache CCACHE_TEMPDIR=/private/tmp cmake --build build-asan -j8
ctest --test-dir build -R '^(terminal_registry|terminal_server|control|control_unix|terminal_process|terminal_process_shutdown|terminal_environment|terminal_process_studio|studio_agent_hooks|studio_provider_events|studio_fleet_keyboard|fleet|agentcontrol|fleetworkers)$' --output-on-failure
# Repeat with --test-dir build-asan.
```

Both builds exited 0. Affected selection: **14/14 normal, 71.93s**;
**14/14 ASan/UBSan, 20.29s**. The sanitizer cache uses
`BOGGART_SANITIZER=address,undefined`. Native ownership/reconnect is tested through
real sockets/processes; SDL dummy-mode regressions verify the existing Studio
paths still work. No new rendering behavior or performance improvement is
claimed. This host has variable load; a later sample was load 61.65/67.69/57.46.

Logs are retained in the ignored build directories as
`server-terminals-build.log` and `server-terminals-tests.log`. `git diff --check`
also passed. Review checked admission before spawn/resize, native completion
versus requested close, independent reader behavior, cleanup and existing
control authority. New HTTP routing is isolated in `lua/terminal/routes.lua`;
the registry never returns native userdata over the wire.

## Remaining dependencies

BMUX-32 must define ordered attach snapshot/replay, stream cursors and client
input/resize ownership. BMUX-31/33 own shared layout and durable restore;
BMUX-34/35 move Studio/cTUI views onto attached server terminals. Server-side
Fleet/provider contexts and native terminal CLI verbs also remain open.
Shutdown signals take effect at the daemon's next job boundary; this does not
add forced cancellation of an in-flight model job. Windows ConPTY is BMUX-22.

See [API and bounds](../bmux-server-terminals.md) and the
[persistent-host architecture](../tmux.md).
