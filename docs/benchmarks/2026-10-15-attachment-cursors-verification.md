# BMUX-70 attachment cursors verification

2026-10-15, macOS arm64, `feature/bmux-termbench`.

`tests/terminal_attachments.lua` uses real native PTYs with deterministic
monotonic time. It compares complete native visible cells and scrollback rows,
including Unicode, style and OSC 8 link data, against attachment snapshots.
Output added after initial capture cannot change its retry bytes. Two independent
readers receive equivalent changes despite a native damage acknowledgement;
retry frames are byte-identical and old cursors require explicit resync.
Geometry/alternate transitions deliver full images. Reattach retains the same
PID and current exact native screen.

The test verifies no legacy input/resize bypass after first attachment, explicit
takeover, expiry/token replacement, detach without PTY close, and actual input
deduplication: repeated `once` plus `twice` is received as exactly two commands
by the real shell. Repeated resize leaves the native process revision unchanged.
Reader count, individual frames and aggregate retained bytes are bounded; failed
initial capture neither publishes an attachment nor changes input admission.
Native revision copying is exercised while a Lua finalizer closes its terminal
during result-table allocation.

`tests/terminal_server.lua` adds actual authenticated UDS requests and a separate
real `boggart serve` daemon. A policy-limited view client can attach/update but
cannot acquire control or send input. Two daemon clients share exact initial
cells; explicit takeover rejects the old controller, then the new owner resizes
and sends Unicode to the same PID. The independent reader catches up across
resize and native exit. Existing auth, shutdown/reaping and malformed-request
checks remain active. No remote model requests are made.

## Results

Both builds completed with exit 0. Affected selection:

```sh
ctest --test-dir build -R '^(terminal_attachments|terminal_registry|terminal_server|control|control_unix|terminal_process|terminal_process_shutdown|terminal_environment|fleet|agentcontrol|fleetworkers|studio_agent_hooks|studio_provider_events|studio_fleet_keyboard)$' --output-on-failure
# Repeat with --test-dir build-asan (address,undefined).
```

**14/14 normal passed, 22.08s. 14/14 ASan/UBSan passed, 26.67s.**
Logs: ignored build directories' `attachment-cursors-build.log` and
`attachment-cursors-tests.log`. Three fixture corrections preceded these final
passes: enough generated history to exceed the requested tail; exact registered
control capability IDs rather than unsupported partial globs; and the existing
positional `terminal.new(cols,rows,history)` constructor in the finalizer case.
The policy denial was reproduced with its actual 403 response and exact-match
policy implementation before changing the fixture. Enforcement was not relaxed.

The changed native file also passed:

```sh
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -Isrc -Ibuild \
  -Isrc/vendor/lua/src -Isrc/vendor/libuv/include src/lterminal.c
python3 tools/check_ghostty_port.py
git diff --check
```

Attribution remains pinned to Ghostty
`05dcf887ef51ea27821f20979493306ec3a19149`, 44 modules/34 ported files. The
existing attribution verifier is the only Python used; product changes are C/Lua.

## Scope

Review checked cursor publication only after bounded encoding succeeds,
independent baselines, frozen retries, capability separation, controller
revocation and sequence admission before native side effects. Frames use
non-consuming native row generations rather than shared dirty flags.

These results establish request/response correctness and native lifetime safety.
They do **not** prove cut-through push/SSE delivery or BMUX-32's kill-client,
byte-identical reattach **under 50ms** gate. BMUX-32 remains in progress for push,
native client integration and that measurement; BMUX-34/35 remain the thin UI
clients. See the [wire contract](../bmux-terminal-attachments.md).
