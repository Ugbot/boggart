# boggart — comparison studies

How boggart's architecture stacks up against other agent systems, framed as
"could you rebuild X on top of boggart, and what are the gaps?" boggart is a
single-user terminal agent kernel: a small C core (embedded Lua 5.4 + libcurl +
SQLite/FTS5 + linenoise) with a fully-mutable Lua harness, an Anthropic Messages
API client, a durable local store (memory/sessions/kv), and a `swarm` mode that
adds cooperative multi-agent fan-out over a C pub/sub bus with a SQLite journal.

---

## 1. OpenClaw — personal AI assistant framework

**What it is.** [OpenClaw](https://github.com/openclaw/openclaw) is an
open-source, local-first *personal AI assistant* (TypeScript/Node, pnpm
monorepo). Its center is a local **Gateway** control plane that routes between:
messaging **channel connectors** (WhatsApp, Telegram, Slack, Discord, Signal,
iMessage, Google Chat), hosted+local **model providers**, a **tools/skills/
plugins** system (TypeScript plugin SDK, distributed via a **ClawHub**
marketplace), **companion apps/nodes** (voice, Canvas, camera, screen,
device-local actions), a persistent **memory** system, and control interfaces
(web UI, CLI, TUI). [Lobster](https://github.com/openclaw/lobster) is a
workflow shell that turns skills/tools into composable, resumable pipelines.
Security: tool-execution sandboxing and pairing approval for unknown DM senders.

**Verdict.** The *brain* ports well — boggart already has close (sometimes
better) analogues of OpenClaw's runtime core. But you'd be rebuilding ~60–70% of
what makes OpenClaw a *product*, which lives at the edges: inbound channels,
multi-provider models, a plugin SDK/marketplace, multimodal/companion apps, a
web UI, sandboxing, and an always-on daemon. boggart maps onto OpenClaw's
*kernel*, not its *shell*.

### Maps well (boggart already has the shape)

| OpenClaw piece | boggart analogue | Fit |
|---|---|---|
| Agent runtime / tool-use loop | `api.lua` turn loop (streaming, tool_use, compaction) | Strong |
| Tools + skills | tool registry + `define_tool`; `skills/*` bundles (instructions + tool allowlist) | Strong — nearly the same concept |
| Persistent memory | SQLite memory with FTS5 | Strong (arguably better) |
| Sessions / resumability (Lobster's determinism goal) | resumable sessions + durable journalled swarm bus + `--resume` | Strong — a real substrate for deterministic/resumable workflows |
| Gateway as message router | C swarm bus (mailboxes + pub/sub + journal) + scheduler | Good *shape*: channel event → publish to topic → agent subscribes |
| CLI / TUI, local-first, single operator | REPL/headless, single-user, local | Direct match |
| Extensibility | overlay filesystem + hot-reload + `define_tool` | boggart is *more* mutable here |

### Gaps (most of OpenClaw's surface area)

- **Inbound Gateway + channel connectors — the biggest blocker.** OpenClaw's
  reason to exist is "meet you in your messaging apps." boggart has one
  front-end (the terminal) and *outbound-only* HTTP: no listener, websockets,
  duplex connections, per-channel adapters, or message normalization. The bus is
  a good place to *deliver* channel events, but the adapters and inbound
  transport don't exist. Needs a real event/server layer (epoll/kqueue/libuv in
  C, or Node connector processes feeding a local socket).
- **Always-on daemon + supervision.** OpenClaw's Gateway is a persistent
  service (installers, Docker, Fly/Render). boggart's scheduler runs to
  quiescence and exits; no background service, restart, or idle inbound loop.
- **Multi-provider models.** boggart is hardwired to the Anthropic Messages API
  (SSE shape, `tool_use` blocks, `x-api-key`/OAuth). `api.lua` would become one
  adapter behind a provider interface (OpenAI, local llama.cpp, …).
- **Security / threat model — critical.** boggart deliberately has no sandbox:
  `bash`/tools run with full process privileges, and all input today is the
  trusted local operator. Once untrusted channel messages drive the agent,
  prompt-injection → arbitrary code execution. Per-agent tool allowlists are a
  start; real isolation (jailed exec, capability gating, sender auth/pairing) is
  missing.
- **Plugin SDK + marketplace (ClawHub).** boggart's extensibility is "drop a Lua
  file / `define_tool`" — no package format, versioning, dependency resolution,
  signing/trust, or plugin isolation.
- **Multimodal + companion apps + web UI.** Voice, Canvas, camera, screen,
  device-local actions, and the web Control UI are whole subsystems boggart
  lacks (it's text-only and doesn't even wire the Anthropic vision path yet).
  Realistically these live in companion processes, not a C/Lua core.
- **Ecosystem/language mismatch.** OpenClaw is Node/pnpm with a TS plugin
  ecosystem; rebuilding on boggart (C + Lua) hosts the runtime but discards and
  reimplements every Node connector/plugin/companion app.
- **Concurrency shape.** `curl_multi` handles outbound API fan-out, but a
  Gateway juggling many persistent inbound duplex connections (streaming voice,
  chat websockets) needs a different eventing model than boggart's
  cooperative-around-outbound-HTTP scheduler.

### Recommended architecture (if you did it)

Keep boggart's embedding philosophy and use it as the local **compute/brain
daemon**; run **channel adapters as separate processes that publish inbound
events onto boggart's bus**. This plays to boggart's strengths (agent loop,
skills, memory, journalled/resumable bus) and quarantines its weakest areas
(untrusted I/O, multimodal, the Node ecosystem). The happy surprise: boggart's
journalled bus + resumable agent-threads is exactly the determinism/resumability
substrate Lobster is reaching for.

Sources: [openclaw/openclaw](https://github.com/openclaw/openclaw),
[openclaw/lobster](https://github.com/openclaw/lobster),
[OpenClaw AI overview](https://www.oneclaw.net/blog/openclaw-ai-github).

---

## 2. OpenAI Codex — terminal coding agent

**What it is.** [OpenAI Codex](https://github.com/openai/codex) is a
"lightweight coding agent that runs in your terminal" — a **Rust** core
(`codex-rs`, TUI) with a thin npm/CLI wrapper (`@openai/codex`), plus a
TypeScript **SDK**, VS Code/IDE integrations, and a desktop app. Auth is ChatGPT
sign-in (Plus/Pro/Business/Edu/Enterprise) or an OpenAI API key; it defaults to
an OpenAI model in the GPT‑5 Codex family. Project/user guidance comes from
`AGENTS.md`. It supports **MCP** (consuming MCP servers, and running as one via
`codex mcp`), configuration via `~/.codex/config.toml` with **profiles** and
OpenAI-compatible **model_providers**, a headless `codex exec` mode, session
**resume** from rollout files, and image input.

Its defining engineering investment is **OS-level sandboxing + an approvals
state machine**: sandbox modes `read-only` / `workspace-write` /
`danger-full-access`, enforced by **macOS Seatbelt (`sandbox-exec`)** and
**Linux Landlock + seccomp**; approval policies `untrusted` / `on-failure` /
`on-request` / `never`; presets like **Auto** (workspace-write, network off,
approve-on-request) and **Full Access**; and escalation prompts when a sandboxed
command needs to break out. File edits go through a structured `apply_patch`
tool; the model also gets `shell`, an `update_plan` tool, optional web search,
and `view_image`.

**Verdict.** Codex is boggart's **closest peer** — same domain (terminal coding
agent), same core shape (streaming tool-use loop, read/write/edit/shell,
sessions + resume, headless mode, project-instructions file). Rebuilding Codex's
*core* on boggart is quite feasible because boggart already **is** that core, and
boggart even **exceeds** Codex on two axes it doesn't have (runtime
self-modification, and native multi-agent). The reachable-but-missing pieces are
a well-defined additive list — with one heavy C lift (sandboxing) that is also
the single most important gap.

### Scorecard

| Capability | Codex | boggart | Notes |
|---|---|---|---|
| Terminal coding agent, streaming tool loop | ✅ | ✅ | same shape (`api.lua`) |
| File read / write / edit | ✅ (`apply_patch`, multi-file hunks) | ✅ (`edit` = unique-match replace) | Codex's patch format is richer/multi-hunk |
| Shell execution | ✅ | ✅ (`bash`) | see sandbox row |
| **OS sandboxing + approvals** | ✅ Seatbelt / Landlock+seccomp, modes + approval policy + escalation | ❌ none (per-agent tool allowlists only) | **the critical gap** |
| Sessions + resume | ✅ rollout JSONL | ✅ SQLite sessions + journalled bus + `--resume` | boggart's is arguably richer |
| Headless / CI | ✅ `codex exec` | ✅ `--headless` / oneshot | parity |
| Project instructions file | ✅ `AGENTS.md` | ❌ (system prompt only) | easy Lua add |
| MCP (consume + serve) | ✅ | ◐ consume ✅ (C client, stdio + Streamable HTTP), serve ❌ | boggart connects MCP servers; their tools register as ordinary tools, scoped per-agent by skill allowlists |
| Model providers | OpenAI + OpenAI-compatible + ChatGPT auth | Anthropic only | mirror-image lock-in |
| Config | `config.toml` + profiles | env/flags + Lua overlay | boggart more mutable, less declarative |
| Image / multimodal input | ✅ | ❌ (Anthropic supports it; not wired) | additive |
| Plan tool / web search | ✅ `update_plan`, web search | ❌ (could be a `define_tool`) | additive |
| **Runtime self-modification** | ❌ tools are fixed | ✅ overlay + `define_tool` + `reload` | boggart's signature |
| **Native multi-agent** | ❌ single agent | ✅ swarm: actors + pub/sub + journal | boggart ahead |
| Durable cross-session memory | partial (history) | ✅ SQLite + FTS5 | boggart ahead |
| IDE ext / SDK / desktop / cloud | ✅ | ❌ terminal only | ecosystem gap |
| Language / footprint | Rust + Bazel, larger binary | C + Lua, ~1.8 MB single exe | different philosophy |
| Maturity / backing | funded OpenAI product, wide use | from-scratch experiment | — |

### Gaps to reach Codex parity (and how hard on boggart)

1. **Sandboxing + approvals — critical, and the one heavy lift.** boggart is
   *sandbox-free by design* (unrestricted `bash`, full-privilege tools) — the
   opposite philosophy to Codex's sandbox-first. To responsibly run
   model-suggested commands it needs Codex-style OS sandboxing (Seatbelt on
   macOS; Landlock+seccomp on Linux) plus an approval state machine. This is
   real **C** work (the rest of boggart's gaps are Lua-level). The swarm's
   per-agent tool allowlist is a conceptual start but not enforcement.
2. **`apply_patch`-style multi-file edits.** boggart's `edit` is a single unique
   string replacement; Codex's structured patch applies multiple hunks across
   files atomically. Additive (a new tool + format), Lua-level.
3. **MCP.** Consuming MCP servers now exists (a C client — `src/lmcp.c` — over
   stdio + Streamable HTTP, with server tools registered as ordinary
   `mcp__<server>__<tool>` tools, scoped per agent via skill allowlists).
   Exposing boggart *as* an MCP server is still to do.
4. **Provider abstraction + image input.** `api.lua` would grow adapters
   (OpenAI Responses/chat, local) behind an interface, and wire the (already
   supported by the model) vision path. Lua-level.
5. **Project-instructions file, a plan tool, web search.** All small Lua adds
   (an `AGENTS.md`/`BOGGART.md` loader; `update_plan` and `web_search` as
   `define_tool`s).
6. **Ecosystem**: IDE extension, embeddable SDK, config.toml/profiles, desktop
   app. Out of scope for the C/Lua core; would be companion work.

**Bottom line.** Nothing here is architecturally blocked by boggart's design —
the core already matches Codex, and boggart wins on mutability and multi-agent.
Closing the gap to a *serious* Codex-class coding agent is mostly additive Lua,
gated on one genuinely hard, genuinely important C subsystem: sandboxing +
approvals. Until that exists, boggart is the better *experiment/kernel* and
Codex is the safer *daily driver*.

Sources: [openai/codex](https://github.com/openai/codex) (repo README),
Codex security/sandboxing & configuration docs (linked from the repo;
the public docs reorganized to learn.chatgpt.com/docs during this research, so
the sandbox/approval specifics above reflect Codex's established public model).

---

## 3. pi — the minimal harness boggart forks from

**What it is.** [pi](https://github.com/badlogic/pi-mono) (pi.dev, Mario
Zechner / Earendil Inc.) is a **TypeScript** terminal coding agent built as an
experiment in minimalism-you-extend: four core tools (`read`/`write`/`edit`/
`bash`, plus `grep`/`find`/`ls`), tree-structured JSONL sessions with in-place
branching, automatic + manual compaction, Agent-Skills-standard skills, and a TS
**extension** SDK (custom tools, commands, UI, event handlers), shareable as
**Pi Packages**. It ships *powerful defaults*: 30+ model providers, four runtime
modes (interactive, print/JSON, RPC, SDK). Its defining move is what it
*refuses*: **no MCP, no sub-agents, no plan mode, no permission popups, no
built-in todos, no background bash** — each punted to an extension, a container,
or tmux. The ethos: "adapt pi to your workflows, not the other way around."

**Verdict.** pi is boggart's **direct ancestor** — boggart's `tools.lua` header
literally says "pi-minimal defaults," and the four-core-tools/tight-context/
no-product-opinion shape is pi's. But the two diverge at the deepest point: **pi
is a minimal core you extend from the outside** (in TypeScript, ahead of time),
and it *cuts* MCP/sub-agents to stay small; **boggart is a mutable kernel that
rewrites itself from the inside** (in Lua, at runtime), and it *re-adds* exactly
what pi cut. Same starting aesthetic, opposite theory of where extension lives.

### The usual feature-gap list mostly doesn't apply

Auditing boggart against pi (or the wider field) as a feature checklist gives a
long "missing" column — repo-map/LSP, web search, plan/todos, git workflow, a
project-instructions file, multi-provider, multi-hunk patch. Under boggart's
thesis **almost all of it dissolves**, because those capabilities are meant to
be *grown* (Lua) or *plugged in* (MCP / an external LLM station), not baked into
the core:

| "Gap" | How it's actually provided | Verdict |
|---|---|---|
| LSP / semantic nav / repo-map | real language servers via MCP (e.g. an external llm-station) | **Not a gap** — real LSP beats a bespoke embedding index |
| Multi-provider | `api.lua` is overlay-mutable Lua (C only streams bytes); or point at any `http://…` Messages-API gateway | Soft — an adapter written once, or offloaded to the station |
| Web search, plan/todos, git workflow, `AGENTS.md` loader, multi-hunk patch | `define_tool` — the agent writes them when it needs them | Correctly *not* core |
| MCP, sub-agents (the things pi cut) | boggart ships both: C MCP client + swarm actor bus | boggart *ahead* of pi here |

So the honest question is not "what feature is absent" but **"what can neither
be written in Lua nor handed to an external station?"** That list is short.

### What is genuinely structural (survives the reframe)

1. **The sandbox — and it is a *harder* sandbox than Codex's.** This is the
   whole audit. Every other agent sandboxes a *fixed, vetted* toolset; boggart
   must contain **code the agent writes about itself, at runtime**
   (`define_tool` bodies today get `sys.exec`/`io`/`os` → full shell) **plus MCP
   stdio subprocesses**. "The Lua adds whatever it needs" and "solid sandboxing"
   pull in opposite directions — a tool must *do* real work yet stay contained —
   and resolving that tension is the core's central unsolved problem. It is
   C-level, not Lua.

   The template already exists: `draw_panel` compiles into a restricted env
   (drawing + theme + arithmetic; no io, network or credentials). Generalize it
   into two tiers:
   - **Pure-compute tier** (the `draw_panel` model): capability env, no
     syscalls — already proven, free.
   - **Effectful tier** (`bash`, `define_tool` bodies, MCP subprocesses): an OS
     jail around the exec — **Landlock + seccomp** on Linux, **Seatbelt** on
     macOS — parameterized by a per-agent/per-tool capability grant (filesystem
     scope, network on/off) with an approval gate on escalation. The swarm's
     per-agent tool allowlist is the *policy* layer; this is the *enforcement*
     layer it currently lacks.

   Until this exists, self-modification is "safe because the operator is
   trusted" — precisely the assumption that swarm, MCP, and agent-authored tools
   erode.

2. **Two pieces that stay C / front-end work no matter how mutable the Lua is:**
   - **Image / multimodal ingestion.** `api.lua` can be taught to *send* image
     blocks (Lua), but the studio must *accept* them (C file handling) and the
     terminal fundamentally cannot show them.
   - **The OS-enforcement layer above.** Landlock/seccomp/Seatbelt bindings are
     C; the agent cannot Lua its way to a syscall filter for its own host.

3. **LICENSE file.** A hard ship-blocker (the README flags it), unrelated to
   philosophy.

### The bet, and its cost

"Flex over structure" is a real bet, not a free win. It trades **discoverability
and auditability**: a Cursor/Codex/pi user reads a fixed manifest of what the
agent can do; a boggart user inspects a toolset the agent has been rewriting.
boggart's mitigation is the **library panel** — every generated tool with its
scope, defining git revision, and call/fail counts, plus full-text memory
search. That provenance surface is what keeps runtime self-extension *legible*
instead of spooky, and it should be treated as load-bearing, not decorative.

**Bottom line.** Against pi, boggart is not "pi with more features" or "pi with
fewer" — it is pi's aesthetic inverted into a self-modifying kernel. The
feature-gap column that the comparison invites mostly collapses into Lua or MCP.
What remains is essentially **one gap**: a sandbox strong enough that "the agent
adds whatever it needs" is a safety *property* rather than a liability. Land the
two-tier jail and the rest genuinely isn't missing — it is deferred by design,
which is the entire point of the thing. pi stays the safer, more portable daily
driver today (providers, containerized isolation, a mature TS package
ecosystem); boggart is the more ambitious kernel.

Sources: [badlogic/pi-mono](https://github.com/badlogic/pi-mono)
(`packages/coding-agent/README.md`), pi.dev, and Mario Zechner's write-up
"What I learned building an opinionated and minimal coding agent" (2025-11-30).
