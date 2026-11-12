# Native agent readiness verification (BMUX-86)

Native channels now notify deferred Lua observers when complete frames or
transport closure arrive. Studio's Boggart Fleet adapter refreshes its exact
owner on those notifications. This is a prerequisite for server-owned agents;
BMUX-87 remains the following ownership/API increment.

## Evidence

Normal and ASAN/UBSAN RelWithDebInfo builds passed on macOS arm64:
`build/bmux-agent-readiness-studio-build.log` and its `build-asan` counterpart.

The focused native/worker/protocol/real-TUI/Fleet/Bmux set passed **14/14** in
each build, 15.48 seconds normal and 23.32 seconds sanitizer:
`build/bmux-agent-readiness-studio-tests.log` and
`build-asan/bmux-agent-readiness-studio-tests.log`.

The final replacement-inside-a-failing-callback regression passed separately in
both builds: `build/bmux-agent-readiness-final-watch.log` and the matching
sanitizer log. A complete real SDL run of `tests/studio_agent_control.lua` passed
with `SDL_VIDEODRIVER` unset: `build/bmux-agent-readiness-real-sdl.log`.

The additional native process/transport/control/Studio shutdown cases passed
**7/7** in both builds, 2.99 seconds normal and 6.43 seconds sanitizer:
`build/bmux-agent-readiness-shutdown-tests.log` and its `build-asan` counterpart.
`git diff --check` passed.

## Contracts actually checked

- `tests/c/agent_channel.c`: native hook only for complete inbound frames and
  closure/error; no notification on frame consumption or idle; existing binary
  framing, queue limits, partial payloads and EOF drain remain covered.
- `tests/agent_channel_watch.lua`: real native child channels, deferred delivery,
  replacement/cancellation, idle, callback failure without transport loss,
  successor protection, EOF, callback self-close and owner cycles. Creating a
  watch in a coroutine remains valid after that coroutine is collected.
- The shutdown fixture writes a filesystem marker if a pending callback runs
  during interpreter teardown; the marker must remain absent. The worker fixture
  similarly fails if an extra callback message appears after the task returns.
  Workers now explicitly retire native channels as well as terminal handles.
- `tests/studio_agent_control.lua`: the real TUI handshake succeeds with periodic
  Fleet scans disabled. The existing same-session prompt, human-draft/stale
  revision guards, steering, interrupt, approval/request identity, Fleet clicks
  and channel-loss capabilities still pass.
- Existing worker, Fleet keyboard/manual/foreign-provider and shared Studio/cTUI
  workflows pass alongside the notification change.

Observer errors are bounded diagnostics; failed agent protocol state still
removes semantic capabilities through `agentcontrol`. The readiness API adds no
transport, execution owner, provider promise or periodic polling timer. Process
scans retain their existing lifecycle role. Comparative latency, durable restart
and server agent ownership are not claimed by these functional/memory checks.
