# Conversation-bound prompt revisions

BMUX-94, 2026-10-16, macOS arm64. The TUI owner previously advanced
`input_revision` only when the human draft changed. Replacing its coordinator
session with another empty draft left a stale observed revision valid for the
new conversation.

`tests/agentbridge.lua` first reproduced the failure at "conversation replacement
invalidates observed prompt revision" against the prior implementation:
`build/bmux-session-revision-before.log`. The fix tracks the observed session
object and its ID alongside the draft, advancing the revision once when any
changes. Observation runs before command application. Process generation and
informational model changes keep their previous semantics.

The regression covers different-ID and same-ID session-object replacement,
an ID change on the same object, idle prompts and active-turn steering, current
revision acceptance, unchanged runtime generation, stable repeated observation,
and model metadata changes without input expiry.

| Gate | Result | Local evidence |
| --- | --- | --- |
| Normal owner/server/native/Studio controls | 9/9, 6.10 s | `build/bmux-session-revision-verified.log` |
| ASan/UBSan same controls | 9/9, 9.86 s | `build-asan/bmux-session-revision-verified.log` |

Both builds passed. Selected suites: agentbridge, agentcontrol, fleetworkers,
bmux_server_agents, bmux_fleet_client, bmux_ctui_fleet, studio_agent_control,
studio_server_agents and studio_fleet_workers. These retain the real-daemon,
native PTY and cross-client controls introduced in BMUX-93. No product changes
followed the gates; `git diff --check` passed.
