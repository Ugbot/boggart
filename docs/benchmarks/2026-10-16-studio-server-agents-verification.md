# Joined Studio server-agent verification

BMUX-92, macOS arm64, 2026-10-16. Normal and ASan/UBSan CLI/Studio builds passed.
No code changes followed the recorded gates.

| Gate | Result | Local evidence |
| --- | --- | --- |
| Normal Bmux/Studio/Fleet/control suites | 38/38, 28.17 s | `build/bmux-studio-agents-verified.log` |
| Focused ASan/UBSan suites | 15/15, 21.36 s | `build-asan/bmux-studio-agents-verified.log` |
| Real SDL window, native daemon workflow | Passed | `build/bmux-studio-agents-real-sdl.log` |
| Real SDL Fleet approval capture | Inspected | `build/testhome/studio_server_agents_real/server-agent-fleet.png` |

`tests/studio_server_agents.lua` drives actual SDL events, joined toolbar/chooser,
Fleet controls and native terminal attachments against a separate native daemon.
It substitutes only the selected Boggart profile's model driver with
`tests/fixtures/agent_control_tui.lua`, avoiding a model API dependency while
retaining the real TUI/session, IPC, permission, process and terminal paths.

Coverage includes launch, structured prompt/output, human-draft contention,
approval rejection/acceptance and stale-button rejection, interrupt, nested and
short-lived workers, worker cancellation/focus, reference close/reopen, foreign
process Stop, preserved local roster/owner, detach/rejoin with unchanged server
PID/session, and clean daemon shutdown. A deliberately dropped successful launch
acknowledgement exercises the visible Retry choice: identical request bytes and
unchanged terminal count prove the original launch is recovered without another
runtime. Mode changes retain the original attachment and render context.

`tests/bmux_fleet_source.lua` covers stable presentation objects, generation
replacement, stale controls, source unmounting, original local/execution owners,
and same-process self-join without recursively republishing remote aliases.

Normal gate: `ctest --test-dir build --output-on-failure -R
'^(bmux_.*|studio_.*|fleetworkers|manualfleet|agentcontrol|control)$'`.
Sanitizer gate selects Fleet source/client/server, cTUI, joined Studio layout
and agents, existing Fleet/worker/manual/keyboard/terminal controls, and control.
These gates verify the Studio adapter; terminal-mode Fleet UI remains pending.
