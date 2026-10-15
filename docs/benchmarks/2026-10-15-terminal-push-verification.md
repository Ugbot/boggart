# BMUX-71 native terminal push verification

2026-10-15, macOS arm64, `feature/bmux-termbench`.

Native PTY/read/exit/resize changes now schedule a deferred, coalesced terminal
watch. Lua publishes attachment frames only to their authorized SSE channels.
No per-pane/per-reader polling timer, new parser or Python/JS runtime was added.

## Behavior and lifetime evidence

- `tests/terminal_watch.lua`: feed never invokes Lua inline; 100 changes coalesce,
  and idle watches emit no periodic callbacks. Pending replacement, callback
  errors, self-close, abandoned owner/callback cycles, native process exit and
  retained parser/worker interpreter teardown are exercised.
- `tests/serve_streams.lua`: generic global/private channel isolation, initial
  replay, peer EOF without a later broadcast, explicit targeted close, malformed
  channel/event/selector rejection, a 4MiB frame and bounded slow-reader closure.
  The listener is created in a collected coroutine to test native callback state.
- `tests/terminal_push.lua`: output between snapshot and subscription is replayed;
  another terminal/global stream sees none of its frames. Connected streams
  retain read lifetime, passive streaming cannot renew the controller, and
  detach/capture-resync/revocation close viewers without killing PTYs.
- `tests/terminal_server.lua`: two real SSE replicas attach to a separate actual
  `boggart serve` daemon. A viewer disconnects/rejoins the same PID. Both converge
  to the exact current native cell grid after resize, Unicode input and exit 7.
  Detach closes one stream independently; close retires the other. Existing
  policy/authentication and shutdown checks remain active, including denial of
  stream subscription without its specific route grant.

No model API calls are made. The test replica is an independent integration
fixture, not the pending product attach client or a Studio rendering change.

Review found a real creating-coroutine lifetime bug. An isolated sanitizer run
of `tests/fixtures/terminal_watch_coroutine.lua` reproduced heap-use-after-free
with exit 134 after collecting the creating coroutine. Watch and server callbacks
now use `LUA_RIDX_MAINTHREAD`, while their registry references remain shared by
the interpreter. The same reproducer exits 0 under ASan, and coroutine-created
listener coverage passes. Red/green logs are retained in ignored
`build-asan/terminal-watch-coroutine-{red,green}.log`. The first transport fixture
also used Lua 5.5's reserved `global` keyword as a local; renaming that fixture
variable corrected its syntax error. No product deadline or assertion was weakened.

## Verification

Normal and sanitizer builds completed with exit 0. The broad post-lifetime-fix
selection was:

```sh
ctest --test-dir build -R '^(pty_transport|terminal_process|terminal_process_shutdown|terminal_registry|terminal_server|terminal_attachments|terminal_watch|serve_streams|terminal_push|control|control_unix|terminal_environment|agentcontrol|fleetworkers|fleet|studio_terminal_native|studio_bmux|studio_fleet_agents|studio_agent_control|studio_fleet_workers|studio_agent_hooks|studio_provider_events|studio_fleet_keyboard)$' --output-on-failure
# Repeat with --test-dir build-asan (address,undefined).
```

**23/23 normal passed, 30.65s; 23/23 ASan/UBSan passed, 32.08s.**
After the final generic SSE `message` envelope and selector validation, the
watch/transport/push/actual-daemon/control selection passed **5/5 normal (5.71s)
and 5/5 ASan/UBSan (6.25s)**, logged in `terminal-push-final.log`.
Build and broad-run logs are the respective ignored
`build*/terminal-push-{build,tests}.log` files.

Also passed:

```sh
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -Isrc -Ibuild \
  -Isrc/vendor/lua/src -Isrc/vendor/libuv/include \
  src/lterminal.c src/bpty.c src/lserve.c
python3 tools/check_ghostty_port.py
git diff --check
```

Attribution remains Ghostty `05dcf887ef51ea27821f20979493306ec3a19149`,
44 modules/34 ported files. Python is only the existing attribution verifier.

The native scheduling follows libuv's documented
[async coalescing](https://docs.libuv.org/en/v1.x/async.html) and
[handle lifetime/reference rules](https://docs.libuv.org/en/v1.x/handle.html).
Pending watches retain their loop until delivery; idle watches are unreferenced.
Native allocations remain alive through deferred close callbacks. Feeding itself
does not call Lua, and interpreter teardown disables watches before native loop
retirement. These callback/handle checks do not establish a whole-app idle CPU
or RSS budget; the existing daemon actor still has its own scheduler wakeups.

## Remaining gate

BMUX-32 remains in progress for a product native attach client and the measured
kill-client/rejoin test with byte-identical screen **and scrollback tail under
50ms**. This turn establishes push correctness, channel isolation and native
lifetime safety. BMUX-34/35 are still the attached Studio/cTUI views; no existing
local Studio PTY was silently migrated. See the
[wire contract](../bmux-terminal-attachments.md).
