# Bmux agent control and a common Fleet

Status: staged design, 2026-10-14. The BMUX workspace, native terminal controls,
New agent launcher and common internal/external Fleet roster are implemented.
Launched Boggart TUIs now have private native-channel session/status reporting
and same-session prompt/steer/interrupt/approval controls. Manual-shell hooks,
child-worker mirroring, rich foreign-provider adapters and persistence remain
follow-up work. See [native control](../../bmux-agent-channel.md) and the
[launcher implementation plan](../plans/2026-10-14-bmux-agent-launcher.md).

## Product shape

**Bmux is where agents run; Fleet is the common roster; Agent remains the
coordinator conversation.** Every agent belongs in Fleet, including Boggart TUIs,
internal Boggart workers, Codex, Claude and custom agents. Provider differences
affect their supported actions, not whether they appear in the roster.

Bmux gains a **New agent** action alongside New terminal. It opens a launcher
with Boggart TUI, installed external agent profiles and Custom command. The
launcher selects project/cwd, existing checkout or an owned worktree (later stage), and new
or resumable session. Boggart launches the actual executable with literal argv:
`boggart --tui`, or `boggart --tui --resume <session-id>`. It stays an interactive
terminal, with the usual keyboard, clipboard and resize behavior.

Each Fleet row shows agent/provider, task, project/branch, status and unread
attention. Clicking it focuses its Bmux pane or opens its supported details.
Internal workers keep their existing scheduler ownership and controls. External
agents receive equivalent roster placement through their adapters. There is
one registry, rather than an external-agent dashboard beside the existing Fleet.

## What to borrow

T3 Code supplies the useful separation of app sessions, provider runtime/thread/
turn references, adapter capabilities and structured requests. Its current
integrations use Codex app-server, the Claude Agent SDK and generic ACP. Bmux
should borrow those boundaries while keeping its C/Lua implementation. T3's
JavaScript SDK integration is not a requirement for our Claude adapter.
[Provider interface](https://github.com/pingdotgg/t3code/blob/9a5dc75648de725c737069379600570e391ec8b5/packages/provider-core/src/server/ProviderAdapter.ts),
[provider constraints](https://github.com/pingdotgg/t3code/blob/9a5dc75648de725c737069379600570e391ec8b5/docs/internals/providers.md).

cmux supplies terminal/workspace identities, installed agent hooks, routed
attention and queued agent messaging. Hook capability differs by provider;
its documented Codex hook messaging cannot wake an idle session. Generic
first-class harness attachment is an upstream proposal, so we should not assume
arbitrary native TUIs can attach to structured provider sessions.
[Agent hooks](https://github.com/manaflow-ai/cmux/blob/62f5cb2bb5639e7b62879ebed18432fd3fa342ec/docs/agent-hooks.md),
[agent messages](https://github.com/manaflow-ai/cmux/blob/62f5cb2bb5639e7b62879ebed18432fd3fa342ec/docs/agent-messages.md),
[harness RFC](https://github.com/manaflow-ai/cmux/blob/62f5cb2bb5639e7b62879ebed18432fd3fa342ec/docs/rfcs/first-class-harnesses.md).

## Registration and ownership

The common record separates `agent_id`, `session_id`, `runtime_generation`,
`pane_id`, `workspace_id`, provider-native references, parent agent, worktree,
capabilities and registration source. Process liveness is separate from agent
activity; a custom agent without hooks can be alive with activity unknown.
Pane labels, cwd and PID are metadata;
they are not identities. Status distinguishes starting, running, idle, waiting
for approval, waiting for an answer, unknown, unreachable, failed and exited.

Launch through Bmux registers automatically before spawning. Agents launched
manually inside a shell register through installed wrappers/hooks or an explicit
registration command using inherited Bmux context. Custom profiles can register
any agent executable with basic capabilities. A program with no integration is
still an observable terminal; arbitrary ANSI output cannot establish agent
identity, completion or approval authority.

One live session has one execution owner. A Boggart TUI owns its existing
coordinator; Studio observes and controls that coordinator through a bridge,
rather than starting another Boggart engine for its Fleet row. Managed provider
protocol sessions likewise have one adapter owner. Multiple views attach to its
record. Conversation resume, process restart and live attachment are distinct.

## Control contract

| Integration | Initial controls | Rich controls when supported |
|---|---|---|
| Internal Boggart worker | Existing supervisor and task/thread identity | Existing messages, pause, cancellation, approvals |
| Boggart TUI | Launch, focus, terminal input, exit tracking | Structured prompt/steer, interrupt, approvals, tools, resume |
| External TUI with hooks | Register, focus, status, attention, resume metadata | Provider-supported queued messages and live decisions |
| Managed Codex/ACP session | Adapter-backed session and event stream | Advertised prompt, steer, interrupt, respond, resume/fork |
| Custom agent without hooks | Register, focus, terminal I/O, process status | Integration can add capabilities later |

Structured prompts and approval responses travel through the adapter, while
the PTY remains interactive. Actions target agent/session plus runtime generation;
approvals additionally target the exact live request. Command IDs deduplicate
retries, and accepted intent is separate from completed execution. Preserve the
provider's request/option IDs and expose unsupported actions as unavailable.

Terminal input and semantic agent messages remain separate commands. Automation
cannot type into a human draft or approval dialog without an explicit override.
Where a provider supplies input state, the owner checks generation and input
revision atomically with delivery. Unknown input state permits observation but
does not justify unattended injection. Silence in a terminal is not an idle or
completed agent signal.

Fleet offers Focus, Send task, Interrupt, Respond/Approve, Resume and Stop according
to capabilities. Stop and interrupt are different actions. Task assignment can
link a tracker ticket and an owned worktree; file review uses actual Git diffs.
Filesystem rollback must coordinate with provider conversation rollback before
it can be offered as one operation.

## Implementation boundaries and order

C owns process/PTY lifecycle, per-child environment and control-channel bootstrap,
bounded transport/queues and ownership enforcement. Lua owns the common Fleet
model, profiles, provider adapters, routing, status policy and SDL3 views. Reuse
the existing bus, supervisor, store and terminal; use Venus containers only where
native storage actually needs them. No new Python or JavaScript application
runtime is proposed.

1. **Launch and register Boggart TUIs.** Ship New agent, stable identity, basic
   Fleet presence/focus and exact process exit. Launch external profiles into the
   same roster, with honest basic capabilities.
2. **Bridge the existing Boggart TUI session.** Add child control/events for
   prompt, turn state, tools, approval/question requests and interrupt. Connect
   the existing scheduler workers through an internal adapter to the same model.
3. **Add external hooks and structured adapters.** Start with installed CLI
   hooks, Codex app-server and generic ACP; implement Claude through supported
   CLI/hooks or a documented transport compatible with C/Lua. Test each provider's
   real capabilities rather than copying a universal control promise.
4. **Add worktree review and durable recovery.** Accepted commands, event cursors,
   request invalidation and idempotent side effects build on the existing store.
   Move runtime ownership into `boggart serve` for detach/reconnect using the
   same registry contract. Initial Studio-owned sessions do not survive Studio
   exit; do not advertise persistence until this stage is verified.

Acceptance should cover Fleet registration for non-Boggart agents, direct TUI
typing, same-session structured control, stale-generation/request rejection,
human drafts, provider crashes, mode switches and restart/resume distinction.

Current gaps confirmed locally: `SwarmView` reads `bog.sched`; control routes have
global prompt/cancel and live SSE but no common external-agent registry; PTY
spawn inherits environment and closes extraneous descriptors, so child identity/
IPC needs an explicit C extension. The TUI already supports `--resume`.
See [control](../../../lua/control.lua), [supervisor](../../../lua/supervisor.lua),
[TUI](../../../lua/tui.lua), [PTY](../../../src/bpty.c) and the
[pinned source research](../../research/2026-10-14-bmux-agent-control-sources.md).
