# Terminal Fleet and shared-agent verification

BMUX-93 / BMUX-90, 2026-10-16, macOS arm64. Normal and ASan/UBSan CLI/Studio
builds passed. All product-code changes preceded the final gates.

| Gate | Result | Local evidence |
| --- | --- | --- |
| Normal Bmux/Studio/Fleet/control/composer suites | 45/45, 28.75 s | `build/bmux-ctui-fleet-wide-final-verified.log` |
| Focused ASan/UBSan suites | 21/21, 30.13 s | `build-asan/bmux-ctui-fleet-wide-final-verified.log` |
| Final readiness-corrected workflows under sanitizers | 2/2, 6.52 s | `build-asan/bmux-fleet-final-recheck.log` |
| Two actual clients, focused normal run | 2/2, 4.11 s | `build/bmux-fleet-cross-client-first.log` |
| Wide attachment / existing adapter checks | 4/4, 8.02 s | `build/bmux-ctui-fleet-wide-after.log` |
| Shared-agent workflow in a real SDL window | Passed; Fleet capture inspected | `build/bmux-fleet-cross-client-real-sdl-verified.log` |

`tests/bmux_ctui_fleet.lua` starts a separate native daemon with a fresh home,
then launches the actual CLI in a native PTY. It tests the default Boggart
launcher, native agent references, structured prompts, whole-grapheme flag
deletion and caret painting, human-draft refusal, modal paste isolation,
approval/rejection, interrupt, both long-lived worker cancellations and parent
Focus, mouse-driven custom launch, foreign process-only controls, narrow Fleet
controls, reference close/reopen and detach/rejoin with the original PID/session.
The wrapper compares `stty -g` before/after every CLI run to verify exact terminal
mode restoration. The default profile runs an actual idle Boggart TUI. Semantic
turns use a second actual TUI with the existing deterministic model fixture;
session, IPC, permissions, native transport and terminal behavior remain real.

An additional native-client/controller probe captures a prompt before a
conversation change and a saved approval before request replacement. Both refuse
locally without consuming a command sequence. It then drops one successful
launch acknowledgement and activates the launcher's `u` key: the retry sends
identical bytes and the native terminal count stays unchanged.

`tests/studio_server_agents.lua` now also opens the actual terminal CLI while
Studio remains attached to its server agent. The terminal acquires the free
lease and sends a Fleet prompt; Studio receives the output. Studio then sends a
prompt while terminal Fleet remains open; closing that overlay reveals the same
output there. Both retain the same agent PID/session and original Studio
attachment/render context. Terminal detach leaves the Studio view alive.

Normal gate:

```sh
ctest --test-dir build --output-on-failure -R '^(bmux_.*|studio_.*|fleet|fleetworkers|manualfleet|agentcontrol|agentbridge|tui_input|tui_agents|grapheme_edit|control|terminal_client)$'
```

Sanitizer gate:

```sh
ctest --test-dir build-asan --output-on-failure -R '^(bmux_ctui_fleet|bmux_ctui|bmux_fleet_client|bmux_fleet_source|bmux_server_agents|studio_server_agents|studio_bmux_layout|studio_fleet_agents|studio_agent_control|studio_fleet_workers|studio_manual_agents|studio_fleet_keyboard|studio_terminal_remote|terminal_client|tui_input|tui_agents|agentbridge|grapheme_edit|fleet|fleetworkers|control)$'
```

The new test initially raced the client roster when navigating after the admin
observer saw a worker first; it now waits for visible publication. Initial
launcher activation also waits for its displayed Fleet state to be live, rather
than mistaking layout readiness for Fleet readiness. A repeated-run
failure revealed the model fixture's persistent manual-approval setting sharing
the test runner's state; a separate daemon/fresh home removes that contamination.
Both intended long-lived fixture workers are cancelled before later turns, so
the scheduler can finish. These corrections change test synchronization and
isolation, not product permission or execution semantics.

The real SDL window additionally exposed a product issue: Studio's wide terminal
plus a 256-row requested history tail exceeded the 32,768-cell attachment budget.
`build/bmux-ctui-fleet-wide-before.log` reproduces the failure with a 300×80
native agent. The test retains an explicit low-level 413 assertion; the shared
pane adapter retries that specific admission refusal once with zero history.
The same runtime then attaches read-only and can acquire a normal input lease.
Server frame limits, authentication and command-retry semantics are unchanged.

These gates do not establish durable daemon-restart recovery, richer foreign
semantic adapters, Windows ConPTY support, or performance superiority over cmux.
