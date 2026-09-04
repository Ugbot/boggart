# boggart — comparison studies

How boggart's architecture stacks up against other agent systems, framed as
"could you rebuild X on top of boggart, and what are the gaps?" boggart is a
single-user terminal agent kernel: a small C core (embedded Lua 5.4 + libcurl +
SQLite/FTS5 + linenoise) with a fully-mutable Lua harness, an Anthropic Messages
API client, a durable local store (memory/sessions/kv), and a `swarm` mode that
adds cooperative multi-agent fan-out over a C pub/sub bus with a SQLite journal.

Product-surface comparisons (TUI chrome, studio, permissions, MCP UX) against
**Codex, Goose, and Claude Code** live in [`peers.md`](./peers.md). The ranked
backlog that falls out of all of these — the feature map, the gaps and the
opportunities — lives in [`feature-gaps.md`](./feature-gaps.md). This file
stays the rebuild-the-kernel studies.

Sections §1–§8 are the 2025–early-2026 studies; **§9–§12 (Qwen Code, DeepSeek
Harness, Devin, OpenCode)** were added on 2026-09-03 and are the current field.

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

Front-end snapshot (composer vs permission bar vs studio): [`peers.md` §1](./peers.md).

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
| Model providers | OpenAI + OpenAI-compatible + ChatGPT auth | ✅ anthropic / openai / responses wires + presets | *(was "Anthropic only"; the wire adapters have since landed — no longer a gap)* |
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
| LSP / semantic nav / repo-map | real language servers via MCP — **shipped**: LLM Station is auto-detected and mounted (LSP, TreeSitter ASTs, call graphs, BM25 index, refactoring; 116 tools live in this repo) | **Not a gap** — real LSP beats a bespoke embedding index, and this is the prediction actually cashed |
| Multi-provider | `api.lua` is overlay-mutable Lua (C only streams bytes); or point at any `http://…` Messages-API gateway | Soft — an adapter written once, or offloaded to the station |
| Web search, plan/todos, git workflow, `AGENTS.md` loader, multi-hunk patch | `define_tool` — the agent writes them when it needs them | Correctly *not* core |
| MCP, sub-agents (the things pi cut) | boggart ships both: C MCP client + swarm actor bus | boggart *ahead* of pi here |

So the honest question is not "what feature is absent" but **"what can neither
be written in Lua nor handed to an external station?"** That list is short.

### What is genuinely structural (survives the reframe)

1. **The sandbox — but it is already most of the way there, and of the
   stronger kind.** The instinct is to reach for an OS jail as Codex does, and
   to call the whole thing unsolved. That undersells what boggart already has.
   Its sandbox **is not a Lua sandbox — it is the C/Lua boundary** (`tools.lua`
   is explicit about this). A `define_tool` body is compiled against `tool_env()`
   as its `_ENV`, and `io`, the destructive half of `os`, `package`/`require`/
   `load`, `debug`, and raw `uv`/`http`/`swarm`/`mcp` are all *deliberately
   absent*. The only way to touch the world is a C-backed capability (`sys`,
   `db`) with its **policy co-located in C**: `sys.rmtree` refuses `/` and uses
   `lstat` so it cannot be walked out of the overlay, `proc.run` bounds output
   and enforces a timeout, `db` goes through the store, even `getenv` refuses
   secret-ish names. There is no second route, so limits and tracing are
   enforced once.

   This is the **capability-positive** model, and it is *stronger* than an OS
   deny-list: a tool can only do what it was handed, where seccomp enumerates
   what to forbid and leaks by omission. So the "harder sandbox" framing is
   backwards — for pure-Lua and C-capability composition, the boundary already
   contains the agent's own generated code.

   What remains is exactly **one residual hole**: `sys.exec` (and MCP stdio
   servers) spawn a real subprocess, and *that child* leaves the boundary into
   native land. OS enforcement — **Landlock + seccomp** on Linux, **Seatbelt**
   on macOS — therefore applies to **precisely one tier, the shell-out /
   subprocess tier, and nowhere else**; the in-VM tiers need nothing added. That
   is a far smaller, sharper piece of C work than a general jail, and the swarm's
   per-agent allowlist is already the *policy* layer waiting for it. Until it
   lands, only shelling out is "safe because the operator is trusted" — and that
   is the assumption untrusted inbound work (see §4) erodes.

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
What remains is essentially **one gap, and a narrow one**: jailing the single
subprocess tier so that "the agent adds whatever it needs" is a safety *property*
rather than a liability. Close that one hole and the rest genuinely isn't
missing — it is deferred by design, which is the entire point of the thing. pi
stays the safer, more portable daily driver today (providers, containerized
isolation, a mature TS package ecosystem); boggart is the more ambitious kernel,
and its capability boundary is a better *foundation* for that ambition than the
comparison first suggests.

Sources: [badlogic/pi-mono](https://github.com/badlogic/pi-mono)
(`packages/coding-agent/README.md`), pi.dev, and Mario Zechner's write-up
"What I learned building an opinionated and minimal coding agent" (2025-11-30).

---

## 4. Looking forward — one kernel, two domains (coding + business process)

The sections above ask "could you rebuild *X* on boggart?" This one asks the
inverse: **what is boggart for next?** The answer that fits its architecture is
not "a better coding agent" but **a domain-neutral agent kernel that serves both
hardcore coding and business-process work from the same core** — because the
primitives it already has are not coding primitives, they are *process*
primitives.

### Why the two are the same shape

Re-read the two domains through boggart's own machinery and they are one loop
with two tool-packs:

- **Coding** = a process whose tools are `read`/`write`/`edit`/`bash` and whose
  system-of-record is a **git repo**.
- **Business process** = a process whose tools are **MCP / API integrations**
  (mail, calendar, drive, a CRM, a database) and whose system-of-record is
  **SaaS + the SQLite store**.

Same turn loop (`api.lua`), same self-extension (`define_tool` + overlay +
`reload`), same durable journal — the only thing that changes is which
tool-pack (`skills/*`) is loaded and what counts as the record of truth. This is
the pi/boggart "flex over structure" bet taken to its conclusion: don't ship a
coding *product* or a BPM *product*, ship the **kernel** and let skills carry the
opinion.

### The machinery already leans toward BPM

A single-repo coding agent barely needs a durable bus; a business process *is*
one. Boggart's least-exercised subsystems are exactly a workflow engine's core:

| Business-process need | boggart primitive that already fits |
|---|---|
| Long-running, multi-step, resumable flow | swarm **journal** + resumable sessions (`processed_at` stamps = a saga log) |
| Triggers ("when an invoice arrives…") | **events** / `on_event` (autocommands) — inversion of control |
| Integrations with outside systems | **MCP client** (register `mcp__<server>__*` as ordinary tools) + `define_tool` to compose them |
| Business state / records | **memory** (FTS5) + `kv` + `sql` |
| Named roles / process definitions | **skills** = instructions + a permitted tool set |
| Human-in-the-loop approval | studio's existing **diff-approval gate**, generalized |
| Rendering a dashboard / approval board | **`draw_panel`** — the agent writes the surface per pack |

The MindStudio nod in the README (the workflow-builder shape) shows the intent is
already latent. The pieces are perhaps 70% there for BPM and ~40% there for a
*product-grade* coding agent — the reverse of what the name suggests.

### What business-process work additionally demands

Coding gets away with an ephemeral, trusted, synchronous model. BPM does not, and
the honest additions are:

1. **Persistence + triggers (the #1 add).** Coding runs to quiescence and exits;
   a business process must stay up and be *woken* — webhook, cron, mailbox poll,
   queue. The bus can *deliver* an inbound event; the **listener and scheduler
   do not exist yet.** This is C-level, but **libuv is already vendored**, so the
   event-loop substrate is in the binary — it needs an inbound transport and a
   supervisor, not a new foundation. (Same gap the OpenClaw study flagged as
   "always-on daemon + inbound Gateway"; BPM is the reason to close it.)
2. **A generalized approval gate.** The studio gates *file writes* today; BPM
   needs the same gate on effectful business actions ("approve: send this email /
   issue this refund"). Generalize "diff approval" to "any capability tagged
   *approval-required*" — and the capability boundary (§3) is exactly where the
   tag belongs.
3. **Idempotency + compensation (sagas).** A business process must not
   double-charge. `processed_at` is a start; real flows need idempotency keys and
   compensating actions layered on the journal.
4. **Capability *grades*.** Per-agent allowlists + the C boundary already exist;
   add **read-only** and **requires-approval** grades so a BPM agent gets
   `mcp__mail__*` for reading but `send` only behind a human.

### The security through-line

BPM changes the threat model: coding assumes a **trusted operator**, but a
business process ingests **emails, documents, and webhooks — attacker-controlled
input** — so prompt injection acquires real-world blast radius (money, records,
outbound messages). This is why the sandbox has been the spine of every section
here, and the three defenses compose cleanly:

- the **C capability boundary** (§3) — no ambient authority, one lawful channel;
- the **subprocess jail** — the single residual hole, Landlock/seccomp/Seatbelt
  around shell-out and MCP-stdio only;
- the **approval gate** — a human on the irreversible actions.

Together they are what make it *safe* to point one self-rewriting kernel at both
a git repo and a company's inbox. The **library panel's** provenance
(which tool, what scope, which git revision, call/fail counts) stops being a nice
touch and becomes a **compliance surface** — an auditable record of what an
autonomous process was permitted to do and did.

### The one caution

Build it as **one kernel + two tool-packs, not two products.** The failure mode
is UX dilution: a single front-end trying to serve a coder and a business analyst
at once. The success mode is a coding-pack and a BPM-pack over the same loop,
with `draw_panel` specializing the surface per pack — a diff for code, a
process/approval board for BPM. The kernel stays neutral; the packs carry the
opinion; the capability boundary keeps both honest.

**Bottom line.** "Hardcore coding *and* business-process work" is not a stretch
for boggart — it is the shape the kernel already has, with coding as the
effect-heavy/local/trusted end and BPM as the integration-heavy/long-running/
untrusted end of one spectrum. The work to reach the BPM end is additive and
mostly known: an inbound-event + scheduler layer on the vendored libuv loop, a
generalized approval gate, saga-grade journalling, and the one subprocess jail
that was already the sole outstanding item. None of it fights the architecture;
most of it is the architecture, turned on.

---

## 5. Trigger.dev — the durable-execution substrate §4 implies

**What it is.** [Trigger.dev](https://github.com/triggerdotdev/trigger.dev)
(TypeScript, Apache-2.0, cloud **or** self-hosted) is not an agent — it is an
**open-source durable background-job / workflow-orchestration platform**, now
positioned around "build and deploy fully-managed AI agents and workflows." You
write a **task** in your own codebase and deploy it; the platform runs it with
**no timeouts**, retries, queues, and observability.

```ts
export const helloWorld = task({
  id: "hello-world",
  run: async (payload: { message: string }) => { /* long-running work */ },
});
```

The engineering core is **durable execution via checkpoint/restore**. At every
`await`/wait point the **Run Engine** snapshots the task — on the managed side
via **CRIU** (freeze memory, CPU registers, file descriptors), stored
compressed — and can resume it later *on a different machine*, exactly where it
paused. Tasks are **frozen during waits** (you pay only for execution). Around
that sit the primitives a business process needs:

- **Triggers**: programmatic (`task.trigger()` / batch), **cron** (`schedules.
  task`), webhooks, events.
- **Retries**: declarative policy (`maxAttempts`, `factor`, min/max backoff,
  randomize); on failure only the failed subtask and everything after it re-runs.
- **Idempotency**: first-class `idempotencyKey` on tasks *and* on `wait.for` /
  `wait.until` (+ TTL), with **result caching** keyed by it.
- **Queues & concurrency**: shared queues with `concurrencyLimit`, per-task and
  per-tenant concurrency, concurrency keys for fan-out; `triggerAndWait`
  checkpoints and *releases its concurrency slot* while suspended.
- **Waitpoints / `waitForToken`**: a run pauses until a **token** is completed
  (or times out) — the durable **human-in-the-loop** primitive (approve / reject
  / suggest), or a wait on a webhook / external service.
- **Ops**: dashboard trace view, realtime updates with LLM streaming, warm
  starts (Run Engine 2.0); self-host via Docker Compose / Kubernetes Helm with
  Postgres + Redis + object storage and horizontal worker scaling.

**Verdict.** This is the section-4 substrate, built out and industrial-grade.
Everything §4 listed as "what business-process work additionally demands" —
persistence + triggers, a durable approval gate, saga-grade idempotency,
concurrency control — Trigger.dev already *is*. So the useful comparison is not
"rebuild it on boggart" but **"boggart is the brain, Trigger.dev is the durable
body"**: they converge on the same AI-workflow target from opposite ends —
Trigger.dev adding MCP, agent skills and HITL tokens *up* from infrastructure,
boggart reaching *down* from the agent kernel toward durability.

### Where boggart already has the shape (and where it stops)

| Durable-execution need | boggart today | Trigger.dev | Gap |
|---|---|---|---|
| Resume after crash/restart | journalled swarm bus + resumable sessions; `--resume` redelivers unprocessed messages | CRIU snapshot resumes mid-`await` on any machine | **Granularity.** boggart's is *message-replay* durability (coarse, transcript-level); Trigger.dev's is *execution-snapshot* (fine, mid-function) |
| Scheduled / webhook / event triggers | `events`/`on_event`, in-process only | cron + webhook + event + programmatic | boggart has no scheduler and no inbound transport (the §4 #1 add) |
| Retries | the model retries `Tool error:` in-loop (LLM-driven) | declarative run-level retry policy with backoff | boggart has no durable retry engine for a whole run |
| Idempotency + result cache | `processed_at` stops redelivery dupes | idempotency keys + cached results | boggart has no keys/caching |
| Queues, concurrency limits, backpressure | cooperative scheduler + `curl_multi` fan-out, single process | queues, `concurrencyLimit`, per-tenant, concurrency keys | boggart has fan-out but no limits/queues/multi-tenant |
| Durable human approval | studio diff-approval gate — **synchronous, in-session** | `waitForToken` — pause for days, survive restarts, resume on approval | boggart can't suspend a process to disk awaiting a human |
| Deploy / scale | single local exe, single-user, single-machine | cloud or self-host, horizontal workers, Postgres+Redis | different universe (by design) |

### The opinionated read (don't chase CRIU)

The tempting conclusion — "add checkpoint/restore to boggart" — is the wrong
lift. CRIU-style process snapshotting fits Trigger.dev because a task is
arbitrary Node code; boggart's runtime is an **embedded Lua VM in one process**,
and the durability model that actually fits an agent loop is **replay, not
snapshot**: you never freeze the LLM, you replay the transcript — which boggart
*already does* through resumable sessions. So the right things to lift from
Trigger.dev's design are the three that compose with replay, and they are
exactly §4's list:

1. **Durable waitpoints.** A run can suspend *to the journal* and resume on a
   token or a timeout — this is what turns the studio's synchronous approval gate
   into a business-grade one ("pause three days until someone approves, surviving
   restarts"). The swarm journal is the right home for it.
2. **Idempotency keys + a result cache** on tool calls, so a replayed run doesn't
   re-send an email or re-charge a card.
3. **A trigger/scheduler source** (cron + webhook) feeding the bus, plus a
   declarative retry policy layered *above* the model's in-loop retries.

### Recommended architecture (if you did it)

Two honest shapes, not one:

- **Host boggart on Trigger.dev.** Wrap a `boggart --headless` run inside a
  `task()`; Trigger.dev supplies schedule/webhook/retry/queue/waitpoint
  durability, boggart supplies the agent turn. This makes §4's entire gap list
  *someone else's solved problem* — the pragmatic path if the goal is BPM now.
- **Lift the three primitives into the core.** If boggart wants to own the BPM
  story natively (no Node platform dependency, staying a single self-contained
  exe), implement durable waitpoints + idempotency + a trigger source on the
  vendored libuv loop and the SQLite journal. More work, but it keeps the "one
  self-contained binary, no runtime deps" property that is boggart's whole
  distribution story — and Trigger.dev is the reference design to copy from.

**Bottom line.** Trigger.dev is the clearest picture available of what boggart's
§4 ambition looks like fully realized, and it settles the build-vs-borrow
question by making the trade explicit: borrow it (host on Trigger.dev) and BPM
works today at the cost of the Node platform under you; build it (replay +
waitpoints + idempotency on libuv/SQLite) and boggart stays a single binary at
the cost of writing the durable substrate yourself. Either way the target is the
same, and boggart's journalled bus is already a recognizable first draft of it.

Sources: [triggerdotdev/trigger.dev](https://github.com/triggerdotdev/trigger.dev),
Trigger.dev docs "How it works", the v3 "durable serverless / no timeouts"
announcement and the v4 GA notes (Run Engine 2.0, waitpoints, self-hosting on
Postgres+Redis), and the CRIU checkpoint/restore write-ups referenced from them.

---

## 6. Lua steps as workflow nodes — the native composition layer

§4 argued boggart should serve business processes; §5 showed the durable
substrate that implies and said to lift *replay + waitpoints + idempotency*
rather than chase CRIU. This section names the missing middle: **the composition
layer — how steps are sequenced into a durable flow — and asserts its unit.** A
boggart workflow should be a journalled graph whose deterministic nodes are
**Lua steps**: capability-bounded Lua functions, interleaved with agent turns and
durable waits. We can support this, and we should — because boggart is the one
system whose *step language is already the sandboxed one*.

### Two node types, one graph

An agentic workflow has two fundamentally different kinds of work, and boggart
already has a primitive for each:

- **Agent turn** — open-ended judgment: read this, decide that, use tools. A
  session + a skill-pack. Expensive, nondeterministic, exactly what an LLM is
  for.
- **Lua step** — deterministic mechanism: parse the invoice, route if total >
  $10k, normalize the record, call one API. A Lua body compiled against the §3
  capability env. Cheap, testable, auditable, no nondeterminism.

The discipline is the same rule the tool prompt already states — *promote stable
mechanics, keep judgment in yourself* — lifted from tool-authoring to
workflow-authoring. Not every node in a business process needs an LLM; most of a
real flow is routing and transformation, and paying for a model turn to decide
`total > 10000` is waste. Lua steps are where that logic belongs, and agent
turns are the judgment nodes between them. A third node type, the **waitpoint**
(§5), durably suspends the graph to the journal until a token, timeout, or
webhook — human approval and external events.

### The structural payoff: one boundary does both jobs

Why Lua steps rather than "a workflow feature" in the abstract: in boggart the
**capability boundary and the effect-replay boundary are the same boundary.**

- A Lua step touches the world *only* through C-backed capabilities (§3) — there
  is no second route. That is what makes it safe.
- Because there is only that one route, the journal can interpose at exactly that
  point: record every effect's result keyed by an idempotency key, and on replay
  return the cached value instead of re-executing. That is what makes it durable.

The single lawful channel (the "monadic" C boundary from earlier) is therefore
*also* the single place to record and replay side effects. Pure-Lua steps replay
for free (deterministic given inputs); effectful steps — `sys.exec`, an MCP call,
sending mail — replay against their cached result so a resumed run never
double-fires. This is precisely Trigger.dev's "cache each subtask by idempotency
key," except boggart gets the interposition point for free from a boundary it
already has for security. No other agent's step language is capability-contained,
so no other agent can offer safe, replayable, user-or-agent-authored steps as one
thing.

### The self-modification thesis, applied to workflows

`define_tool` already lets the agent author a Lua body at runtime against that
capability env. A Lua step is the same object with a different caller (the
workflow engine schedules it; the model doesn't invoke it inside a turn). So an
agent can **extend its own workflow mid-run** — write a new deterministic routing
or transform step and splice it in — the §3 self-extension story reaching the
composition layer. And like tools, workflow definitions and their steps live as
overlay-mutable Lua the human can read, listed in the **library panel** with
provenance (scope, git revision, call/fail counts) — so an autonomous,
self-editing workflow stays legible and auditable, which is the whole reason the
capability boundary is *not* a security boundary against the agent but *is* one
around effects.

### What maps to what

| Workflow concept | boggart mechanism (have / add) |
|---|---|
| Deterministic step | **Lua step** = `define_tool` body vs §3 capability env — *have* the unit, *add* engine-scheduled invocation |
| Judgment step | agent turn (session + skill-pack) — *have* |
| Durable wait / human approval | **waitpoint** suspending to the journal — *add* (§5) |
| Sequence / branch / fan-out / join | a Lua step returns the next edge; fan-out spawns over the swarm bus — *have* the bus, *add* the control vocabulary |
| Crash recovery | journalled bus + resumable sessions + `--resume` — *have* (replay-durability, §5) |
| Don't-double-fire | idempotency key + result cache **at the capability boundary** — *add*, cheaply, because the boundary is already the one route |
| Trigger (cron / webhook / event) | `events`/`on_event` in-process — *add* the inbound + scheduler source (§4 #1) |
| Legibility / audit | library panel provenance over steps and workflows — *have* |

### The determinism caveat

Replay-durability only holds if a step is deterministic given its inputs plus its
cached effect results. Pure Lua is fine. The traps are ambient nondeterminism a
step must *not* reach for outside a recorded capability: wall-clock time, random,
environment — which is why `tool_env` already ships `os.time`/`date` but the
effectful reads go through C. To make steps replayable, those too become
capability calls whose results are journalled (record the clock once, replay it),
the same move Trigger.dev makes for its cached subtasks. The capability boundary
is what makes this enforceable rather than a convention: a step *cannot* smuggle
in an unrecorded effect, because the only effects it has are the ones handed to
it.

**Bottom line.** "Lua steps in an agentic workflow" is not a new subsystem bolted
on — it is the existing capability-bounded Lua body (§3) promoted from *tool the
model calls* to *node the engine schedules and journals*, interleaved with agent
turns and waitpoints on the bus boggart already has. It is the composition layer
§4 and §5 were circling, and it is the one part of the durable-workflow story
that boggart is *better* positioned to build than Trigger.dev or n8n — because in
boggart the step language, the sandbox, and the effect-replay log are the same
boundary, and the agent can already write to it.

---

## 7. CodeRabbit — AI PR-review platform

**What it is.** [CodeRabbit](https://coderabbit.ai) is an AI code-review
*platform*, not a harness: the most-installed AI app on GitHub/GitLab (2M+ repos,
13M+ PRs reviewed), a hosted App that auto-reviews every pull request — line
comments, summaries, walkthroughs — enriched by **40+ linter/SAST integrations**,
**code-graph analysis** for repo-wide context, per-org **Learnings** that persist
across PRs, an IDE surface, and a multi-tenant SaaS (fully self-hosted only at
Enterprise ≥ 500 seats).

**Verdict.** Split the question, because the answer differs by half. The review
*brain* is table stakes any good agent clears, and is arguably boggart's
strength; the review *product/platform* is a separate, company-scale build,
mostly orthogonal to boggart's kernel — the same "maps onto the kernel, not the
shell" verdict as OpenClaw (§1). CodeRabbit's moat is ~80% platform, ~20%
intelligence.

### The brain — boggart can meet or beat it
boggart already has the agent loop, `git` diff (the C capability, see
`workspace.md`), MCP to reach GitHub, and the real edge — **swarm**: specialised
reviewers (correctness / security / perf / style) as actors with **adversarial
verification** before a finding is posted, which is a better review *architecture*
than a single pass and is native, not bolted on. Plus self-modification: the
reviewer can `define_tool` repo-specific checks at runtime and persist them with
provenance. On review *quality*, boggart is not behind.

### The platform — the gaps, ranked
1. **Always-on + VCS integration — the blocker.** CodeRabbit auto-reviews on PR
   open/push; boggart runs to quiescence and exits. Needs the §4 daemon + webhook
   inbound, or — far cheaper — a **CI Action wrapper** that runs `boggart review`
   per PR. (The platform *around this very session* already proves the pattern:
   `subscribe_pr_activity` + GitHub MCP + PR-triggered runs.)
2. **Static-analysis aggregation** — 40+ linters/SAST normalised and deduped into
   one review. boggart can *run* them via `bash`; the aggregation layer is
   missing. Achievable.
3. **Repo-wide code graph / context** — CodeRabbit indexes the repo; boggart has
   `code_index`/`code_search` plus **LLM Station**'s call graphs and BM25 index
   over MCP, so the review agent can reach real structure, not just bounded reads.
4. **Persistent org-level learnings** — boggart's memory is per-user/local; needs
   shared/team-scoped memory.
5. **PR-review product surface** — summaries, walkthroughs, committable
   suggestions, `.coderabbit.yaml`-style path rules, incremental review on push,
   thread resolution, severity/labels. Each buildable; none exist.
6. **SaaS + compliance + scale + multi-VCS** — skip for the wedge; it is the part
   that is not boggart.

### The wedge
Don't clone the SaaS; be the **local-first / self-hosted / CI-integrated
swarm reviewer**. CodeRabbit's fully self-hosted option is Enterprise ≥ 500 seats,
so every privacy-conscious small/mid team that cannot ship code to a SaaS is
unserved. boggart's differentiators there: multi-agent adversarial review (higher
signal, fewer false positives — the thing everyone hates about AI reviewers),
local-first BYOK (code stays on your infra, no per-seat markup), self-extending
repo-specific checks, and PR-walkthrough **diagrams** via boggart-studio's
sketch engine.

**Bottom line.** Cloning CodeRabbit-the-SaaS is off-mission — it is a platform
company, not a kernel feature. A local-first, CI-integrated, swarm-based reviewer
with better signal and real privacy is genuinely competitive, and structurally
beyond what CodeRabbit serves under 500 seats. The MVP is small: a `review` mode
emitting structured findings (swarm + adversarial verify), a GitHub Action to
post them, a guidelines config, and linter aggregation — mostly on pieces boggart
has, plus the §4 inbound work. Code-graph/learnings depth is where you keep
investing for review-quality parity at scale.

Sources: [coderabbit.ai](https://coderabbit.ai), CodeRabbit docs, and 2025
coverage of its scale, integrations, Learnings and self-hosting tiers.

---

## 8. t3code — an agent control surface (borrow, don't clone)

**What it is.** [t3code](https://github.com/pingdotgg/t3code) (Theo / ping) is a
**WebSocket control surface** — event-sourced (Command → Decider → events →
Projector → per-agent Provider Adapters) — that remote-drives *other* agents
(Claude Code, Codex, Cursor, Grok, OpenCode) from web/desktop/mobile over
local/relay/Tailscale, with **turn-level git checkpoints** (a hidden ref per turn
so the app can diff and restore). It is the *shell*; boggart is the *engine* it
would drive. Nearly orthogonal, which makes the borrow question sharp.

### What to borrow
1. **Turn-level git checkpoints via a hidden ref** — their best single idea, and
   boggart now has it: the `git` C capability (`workspace.md`) checkpoints to
   `refs/boggart/` and generalises to a git-free snapshot backend for non-coders.
2. **The inverse of building a surface** — make boggart *controllable* by a
   surface like t3code (match a headless/RPC contract, or ship an adapter) to
   inherit its mobile/web/desktop clients for free. Highest leverage.
3. **Journal-as-source-of-truth, views-as-projections** — the *principle*, not
   the CQRS ceremony; it validates §5/§6's replay-durability and gives multi-client
   consistency.
4. **Supervised / Full-access posture** — a coarse permission toggle layered over
   boggart's finer capability boundary (§3) + per-agent allowlists.

### What not to borrow
Becoming a control surface for other agents (t3code's identity), the four-platform
client suite (be *controllable* instead), and the full CQRS layering (overkill for
a single-user kernel).

**Bottom line.** Complementary, not competitive. Borrow git-ref checkpointing
(done), adopt journal-as-truth, and treat t3code as the **client surface to plug
into, not to reimplement** — its remote/daemon protocol doubles as the §4 BPM
substrate, the recurring unlock.

Sources: [pingdotgg/t3code](https://github.com/pingdotgg/t3code), its docs, and
2025 coverage.

---

## 9. Qwen Code — Alibaba's terminal agent, and the closest product rival

**What it is.** [Qwen Code](https://github.com/QwenLM/qwen-code) (Alibaba,
TypeScript, Apache-2.0, ~27k★) began in July 2025 as a fork of Google's Gemini
CLI tuned for the Qwen3-Coder models, and spent 2026 becoming a *product*: five
stable releases in August alone, a desktop app, IDE plugins for VS Code, Zed and
JetBrains, GitHub Actions, and a headless mode. Its 2026 shipping log reads
almost like boggart's own roadmap, executed by a large team:

- **LSP** (Feb 3) and **Agent Skills GA** (Feb 9), plus `/export` of a session
  to Markdown / JSONL / HTML.
- **Channels** (Apr 9) — Telegram, WeChat, DingTalk (with interactive cards),
  GitHub and GitLab as *inbound* surfaces for the agent.
- **`/plan`**, **`/review`**, **memory**, **web search**, **real-time steering**
  (interrupt and redirect mid-stream).
- **Sub-agents** (May 21) with **worktree isolation** (May 28) and, in August,
  **per-task permission scoping**: reusable templates in `.qwen/fork-profiles/`,
  read-only access for read-only work, and deliberate *instruction isolation*
  so concurrent siblings cannot leak context into each other.
- **`/learn`** (Jul 16) — turn a finished session into a reusable Skill.
- **Background agents** (Jul 30) that stay resident after a task completes.
- **Goal autonomous mode** with **goal budgets** (Aug 27) — long-horizon runs
  bounded by an explicit token allowance.
- **Desktop app** (Aug 6) with a **session-workflow flowchart** that shows plan
  steps running/waiting/done and requires approval before execution, in-terminal
  image display, and a cheaper model assignable to compaction.

**Verdict.** Of everything in this document, Qwen Code is the system that most
directly contests boggart's *claims*. Codex is the closest peer in shape, pi is
the ancestor — but Qwen is the one that shipped, in one year, a product version
of self-extension (`/learn`), of multi-agent (sub-agents + worktrees +
per-task permissions), of the inbound channel layer §1 and §4 keep flagging, and
of the goal-budget discipline that `--until` gestures at. boggart is not behind
it architecturally. boggart is behind it on *ship count*.

### Scorecard

| Capability | Qwen Code | boggart | Notes |
|---|---|---|---|
| Streaming tool loop, core file tools | ✅ | ✅ | peer |
| Self-written capability | ✅ `/learn` → a Skill (markdown prompt bundle) | ✅ `define_tool` → executable, capability-scoped Lua, live this turn | **boggart deeper**: theirs is a prompt, ours is code with provenance |
| Sub-agents | ✅ + worktrees + per-task permission templates | ✅ swarm actors, C bus, journal; allowlists per skill | boggart's substrate is stronger, their *scoping* is finer |
| Sibling instruction isolation | ✅ explicit | ◐ | small Lua fix |
| Background / resident agents | ✅ | ◐ in-session fleet only | needs §4's daemon |
| **Inbound channels** | ✅ Telegram / WeChat / DingTalk / GitHub / GitLab | ❌ | the §1+§4 gap, shipped by a peer |
| Goal mode + token budget | ✅ | ◐ `/until`, `/react`, watchdog | additive Lua |
| LSP | ✅ forked into the core | ✅ via **LLM Station** over MCP (auto-detected, `mcp__llm-station__*`) | boggart buys the same capability without growing the core |
| Web search | ✅ | ❌ | trivial Lua add |
| Session export | ✅ md/jsonl/html | ❌ | trivial |
| Images | ✅ rendered in-terminal | ❌ | C/front-end work |
| Cheap-model compaction | ✅ | ❌ | trivial, real cost win |
| Real-time steering | ✅ inject mid-stream | ◐ Ctrl-C / pause / kill | small |
| Workflow visualisation | ✅ fixed flowchart view | ✅ **`draw_panel`, agent-authored** | different kind of thing; boggart's is stranger and better |
| Desktop | ✅ | ✅ studio | peer |
| Runtime self-modification of the harness | ❌ | ✅ | boggart alone |
| Single binary, no runtime | ❌ Node | ✅ ~1.8 MB | boggart alone |

### What to take

1. **`/learn`, done properly.** Their loop — *finish a task, distil it into a
   reusable unit* — is the missing half of `define_tool`. boggart can already
   author the unit mid-run; what it lacks is the deliberate end-of-session
   promotion step. And boggart's version is strictly better material: executable
   Lua with a scope, a git revision and call/fail counts, not a prompt file.
2. **Fork-profiles.** Per-sub-agent permission *templates* are the right shape
   for the swarm's allowlists, and the natural consumer of the policy engine
   from [`feature-gaps.md` §3.1](./feature-gaps.md).
3. **Goal budgets.** A long-horizon run should carry an explicit token
   allowance, not just a turn cap.
4. **Channels as the proof.** Whatever hesitation remained about §4's inbound
   layer, a mainstream terminal coding agent shipping WeChat and DingTalk
   adapters settles it: chat-as-a-surface is now a normal feature, not an
   OpenClaw eccentricity.

**Bottom line.** Qwen Code is the answer to "what if a well-resourced team built
the product version of boggart's ideas?" — and the answer is that they get the
features and boggart keeps the substrate. Their skills are prompts; ours are
sandboxed code. Their flowchart is a view; ours is written by the agent. Their
harness is Node; ours is one file. Close the parity list above (nearly all Lua)
and there is no capability Qwen Code has that boggart does not, plus several it
structurally cannot.

Sources: [QwenLM/qwen-code](https://github.com/QwenLM/qwen-code), the Qwen Code
docs feature-update log and its 2026 weekly updates (2026-02-09 skills GA,
2026-05-21 sub-agents, 2026-08-06 desktop + session workflow, 2026-08-13
sub-agent permissions, 2026-08-27 goal budgets).

---

## 10. DeepSeek Harness (`dsh`) — the thesis rival

**What it is.** [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`, TypeScript/Node, MIT, published 2026-08-13 alongside DeepSeek-V4-Pro, a
developer preview at `0.1.0-rc`) is an agent harness whose slogan is
**"Everything is a Plugin"** — and it means it more literally than the phrase
usually implies. Built on **Cordis** (a service/event container from a paper on
"spatiotemporal composability"), a running `dsh` is a **plugin tree composed at
boot from ordered layers**, with the explicit design claim that **"there is no
privileged core to patch."** Models, tools, skills, sessions, sandboxes,
storage, scheduling, the UI — *and the agent loop itself* — are plugins.

Its structural vocabulary:

- **Bundles** package code and configuration; **profiles** are *named
  compositions* that stack bundles, pin their out-of-tree plugins, and carry the
  user's own `cordis.patch.yml`. Shipped profiles: `web`, `headless`, `sdk`,
  `sdk-minimal`, `acp`.
- **`dsh-base`** is the shared first layer under all of them: model adapters,
  tools, persistence, **sandbox and approval policy**, settings, credentials,
  telemetry.
- **Capability seams** — swappable interfaces with a service definition, a
  provider and consumers, so changing one provider changes product behaviour
  wholesale.
- **Extension points** rather than patches: register providers on `ctx.llm`, add
  tools via `ctx.tools`, hook the `agent/*` lifecycle events, extend session
  state through `SessionEventMap`.
- **The session-log principle: "model-visible means logged."** Anything that
  reaches a model request must be reconstructible from the session log — which
  is what makes fork, resume and replay consistent rather than hopeful.

**Verdict.** This is the closest thing to a rival *thesis* boggart has. Both
reject the fixed-core harness; they disagree about **when** the flexibility
happens. `dsh` composes at **boot**, from configuration, in TypeScript, written
ahead of time by a human. boggart mutates at **runtime**, from inside the loop,
in Lua, written by the agent mid-session. That difference decides everything
else:

| Axis | dsh | boggart |
|---|---|---|
| Unit of flexibility | a plugin in the tree | a Lua module in the overlay, or a `define_tool` body |
| When | boot-time composition (restart to change) | live (`reload`, next turn) |
| Who writes it | a human developer, ahead of time | the agent, during the task |
| Privileged core | **none** by design | a small C core — *deliberately* |
| Containment of extension code | none: a plugin is full Node | the C/Lua capability boundary (§3) |
| Footprint | Node + a plugin tree | one ~1.8 MB binary |
| Surfaces | web-first, plus headless/sdk/acp | terminal + studio |

The interesting result is that **"no privileged core" and "contained
self-extension" are mutually exclusive**, and each system took one. `dsh` can
replace its agent loop; it can never promise that a plugin's effects were
recorded or that a plugin cannot read your keys, because a plugin is arbitrary
Node. boggart keeps a privileged C core precisely *so* that generated code has
exactly one lawful channel to the world — which is what makes runtime
self-modification safe enough to allow at all.

### What to take (three things, all cheap)

1. **The session-log invariant.** *"Model-visible means logged"* is the crispest
   statement of the discipline §5 and §6 circle. boggart should adopt it as a
   stated invariant — and then do what `dsh` cannot: **enforce** it. Because
   every effect in boggart crosses the C capability boundary, the journal can
   interpose at that one point rather than trusting authors to log. Their rule,
   our boundary, and replay stops being a convention.
2. **Profiles as named compositions.** boggart has a golden default and a
   mutable overlay and *nothing in between*, so a working configuration cannot
   be named, versioned or handed over. `dsh`'s bundle/profile split is the shape
   of the "pack" that [`feature-gaps.md` §3.5](./feature-gaps.md) proposes.
3. **Declared seams and lifecycle events.** `ctx.tools`, `ctx.llm`, `agent/*`
   and `SessionEventMap` are *documented* extension points. boggart's answer to
   "where do I hook this?" is "edit any file" — maximal freedom with minimal
   guidance, and a hostile surface for an agent that has to guess. Publishing a
   small set of named seams (tool registry, wire adapter, agent lifecycle,
   session state) costs nothing and makes both the human's and the model's
   extension attempts land in the right place.

Their `acp` profile is also the cheapest possible argument for
[`feature-gaps.md` §3.2](./feature-gaps.md): a serious harness treats ACP as a
first-class output target, not an integration afterthought.

**Bottom line.** `dsh` proves the market for a composable harness and validates
boggart's core bet from the opposite direction — then hands over three ideas
(the log invariant, profiles, declared seams) that boggart can implement better
than they can, because boggart's extension code is contained and theirs is not.
The one thing not to copy is the plugin-tree-all-the-way-down maximalism: "no
privileged core" is a fine slogan for a Node framework and a direct contradiction
of the property boggart's safety rests on.

Sources: [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
README and `docs/architecture.md`; the DeepSeek Harness developer-preview
announcement (2026-08-13, MIT, `0.1.0-rc`).

---

## 11. Cognition / Devin — the autonomy ceiling

**What it is.** [Devin](https://devin.ai) is not a harness, it is a hosted
autonomous-engineer *platform*, and in 2026 it consolidated: Windsurf was
retired and rebranded to **Devin Desktop** (2026-06-02), whose default surface
is an **Agent Command Center** rather than an editor canvas, with the IDE behind
it; **Devin Local** replaced Cascade as a from-scratch Rust agent (~30% better
token efficiency) that spawns **sub-agents**. Work is billed in **ACUs**
(Agentic Compute Units — VM time + inference + bandwidth, ~$2.25 each), which
means every capability is priced and estimated up front.

The 2026 capability set, in the terms this document cares about:

- **Fleet orchestration.** Sub-Devin sessions form **nested trees** in the
  sidebar; the expectation is dozens of agents in parallel across cloud and
  local environments on one project, with a human reviewing results as they land.
- **Triggers and automations.** Cron and RRULE schedules, run-once, GitHub and
  GitLab pushes, Jira issues, Linear items, Slack messages, raw webhooks.
- **Structured output schemas** per session, so a run's result is consumable by
  a program rather than a reader — plus a Tasks tab, streamed terminal output,
  and test recordings as replayable cards.
- **Machine snapshots**: start a session from a saved machine state.
- **Knowledge**: Devin Wiki v2 and DeepWiki, with ACU costs shown before
  generation; enterprise knowledge items capped at 300.
- **MCP** as an ecosystem: 48+ connectors, a marketplace, and *personal* MCP
  servers with individual OAuth alongside org-scoped ones.
- **Security profiles** governing **network access** per session and automation,
  read-only scan profiles, enterprise-scoped secrets, PATs and a v3 API.

**Verdict.** Same verdict as OpenClaw (§1) and CodeRabbit (§7), for the same
reason: this maps onto boggart's *shell*, not its kernel. Roughly 90% of Devin
is platform — hosted VMs, billing, org knowledge, review products, connector
marketplace — and none of it is a kernel property. But Devin is the most useful
system in this document for one specific purpose: it is **the clearest picture
of what "the agent runs your work, not your turn" actually requires**, and every
requirement it exposes is one §4 predicted.

### What Devin demonstrates that boggart should absorb

1. **Structured output is what makes a fleet composable.** boggart's swarm is
   architecturally ahead of Devin's session trees — a real C bus, a journal,
   resumability — and yet a boggart sub-agent hands back *prose*. Devin returns
   against a schema. Until a coordinator can branch on a value instead of
   re-reading English, fan-out stays a demo. Pure Lua, small, high leverage.
2. **Cost accounting as a first-class primitive.** ACUs are a normalised unit
   shown *before* an action runs. boggart has telemetry and a watchdog; what it
   lacks is a per-node budget on the FLEET tree, which is what turns that view
   from a monitor into a control surface.
3. **Triggers, again.** Devin's automation trigger list (push, issue, message,
   webhook, cron/RRULE) is the concrete specification for §4's inbound layer.
   Nothing about it is exotic; it is a listener, a matcher, and a scheduler.
4. **Network policy as a capability grade.** "Security profiles govern network
   access across sessions and automations" is exactly the *grade* §4.4 proposed
   (read-only, approval-required) applied to the one axis boggart's capability
   boundary does not yet distinguish. Worth adding when the policy engine lands.
5. **Machine snapshots vs git checkpoints.** Devin snapshots the machine because
   its unit is a VM. boggart checkpoints to `refs/boggart/` because its unit is
   a repo. Same instinct, and boggart's is cheaper and more portable — but the
   non-repo case (a business process with no git) is where the snapshot backend
   `workspace.md` sketches earns its place.

### What not to chase

Hosted VMs and ACU billing; the wiki/knowledge SaaS; the connector marketplace;
the enterprise console. That is a company, not a feature list. The honest wedge
against Devin is the same one as against CodeRabbit: **local-first, no code
leaving the building, no per-seat markup, and a fleet you can actually read the
source of.**

**Bottom line.** Devin marks the ceiling of the autonomy axis and prices every
rung of it. boggart's kernel is not outclassed — the swarm, the journal and the
capability boundary are real answers to problems Devin solves with a VM and a
credit card. What Devin has that boggart lacks is the *plumbing of unattended
work*: triggers, budgets, structured results, network grades. All four are on
[`feature-gaps.md`](./feature-gaps.md)'s Arc 3, and all four are things a single
binary can do without becoming a platform.

Sources: [Devin docs](https://docs.devin.ai) 2026 release notes and pricing;
Cognition's Windsurf 2.0 / Devin Desktop announcement (2026-06-02) and the Devin
Local write-ups.

---

## 12. OpenCode — the control plane, and the permission model to copy

**What it is.** [OpenCode](https://opencode.ai) (TypeScript, MIT, ~150–200k★,
~6.5M monthly active users, GitHub Copilot auth partnership since January 2026)
is the OSS field's most-used agent, and its distinguishing engineering choice is
architectural: **OpenCode is a server**. A local process publishes an **OpenAPI
3.1** spec at `/doc` and an **SSE** event stream at `/event`; the **TUI, desktop,
web and IDE clients are all just clients of it**, an SDK is generated from the
spec, and `/tui` endpoints let a remote client drive the terminal UI (which is
how its IDE plugins work). Around that sit LSP, MCP, plugins, custom tools,
formatters, `AGENTS.md` rules, custom commands, plan/build agent modes, undo/redo
and shareable session links.

Its second distinguishing piece is the **permission model**, which is the
cleanest in the field:

- Every rule resolves to **`allow` / `ask` / `deny`**, with `"*"` as a catch-all
  and per-tool overrides.
- Object syntax gives **glob pattern rules matched against tool inputs**, with
  **last match wins** — broad rule first, specific exceptions after.
- The permission set is *named and complete*: `read`, `edit`, `glob`, `grep`,
  `bash`, `task` (sub-agent launch), `skill`, `lsp`, `question`, `webfetch`,
  `websearch`, **`external_directory`** (anything outside the workspace) and
  **`doom_loop`** (the same tool call three times running).
- Defaults encode judgement: `.env` reads are **denied** by default,
  `external_directory` and `doom_loop` **ask**.
- **Agent-level overrides** take precedence over global rules, declared in JSON
  or in agent-file frontmatter; an `--auto` flag approves anything not explicitly
  denied, and **`deny` still wins**.
- The ask flow is *once / always / reject*, with "always" scoped to the session.

**Verdict.** Nearly orthogonal to boggart as a product — it is a Node monolith
with a huge user base and no self-modification story — but it is the single most
*copyable* system in this document, because both of its good ideas are pure
design, not code you would port.

### What to take

1. **The permission schema, near-verbatim.** `perm.lua`'s four modes are a UX
   layer over a policy engine boggart does not have. OpenCode's is data: three
   verdicts, glob rules over tool inputs, last-match-wins, agent-level narrowing.
   `doom_loop` and `external_directory` are both real safety wins boggart lacks
   entirely, and `.env`-deny-by-default is the kind of default that costs nothing
   and prevents a genuinely bad day. See
   [`feature-gaps.md` §3.1](./feature-gaps.md) for the proposed shape.
2. **Server-as-the-product.** boggart already asserts one engine behind two front
   ends and *enforces* it with `ninja core-parity` — which is a stronger version
   of OpenCode's claim, held together by a build check rather than a wire
   protocol. Making the engine addressable (HTTP + SSE + a published schema)
   turns that internal invariant into an external one: studio and the TUI become
   clients, remote and mobile control follow for free, and §8's "be controllable,
   don't build clients" finally has an endpoint to be controlled through. It is
   also the same libuv listener §4's triggers need.
3. **Session share links** as the cheap collaboration primitive — a read-only
   rendering of a session, no account system required.

### Where boggart is ahead

Runtime self-modification (OpenCode has custom tools, written ahead of time in
TypeScript); the swarm as a first-class actor system with a durable journal
(OpenCode has `task`); the capability boundary containing generated code; the
single self-contained binary; agent-authored UI. OpenCode is ahead on providers
(narrowly, now that the wires have landed), on client surface area, and — most
importantly — on **policy**, which is the one place it is ahead on *substance*.

**Bottom line.** Take the permission model and the server shape; ignore the rest.
Those two are the highest-leverage borrowings identified in this entire document
relative to their cost — one is a Lua rewrite of a file that already exists, the
other is a listener that four separate roadmap items are already waiting on.

Sources: [opencode.ai/docs](https://opencode.ai/docs) — the server/client
architecture page (OpenAPI 3.1, SSE, generated SDK, `/tui` endpoints) and the
permissions reference; 2026 coverage of its scale and the Copilot auth
partnership.

---

## Appendix — Why Lua, not a Lisp or a Scheme

A self-modifying agent that rewrites its own code at runtime *screams* Lisp:
homoiconicity, macros, live redefinition, the image. So the fair question is
whether boggart picked the wrong runtime on day one. The answer is no — but the
reason is specific, and it only becomes clear once you separate **the runtime**
(the VM the agent's code lives and mutates in) from **the surface syntax** (what
that code looks like). The Lisp instinct is right about the *surface* and wrong
about the *runtime*, and boggart needs the runtime to be right.

### What "runtime flexibility" has to mean *here*

boggart does not need maximal malleability; it needs a particular five-way
intersection, and every one of these is load-bearing elsewhere in this document:

1. **A language-level, per-unit capability sandbox** — because self-modification
   is only safe if a generated unit of code can be handed an exact set of
   capabilities and *nothing else* (§3). This is the single most important
   property, and the one the effect-replay log reuses (§5, §6).
2. **Embeddable in a small C core**, so the whole thing ships as one
   self-contained ~1.8MB binary — the distribution story (§5's build-vs-borrow
   hinges on keeping it).
3. **Text source, not an image** — the agent's own code is diffable, greppable,
   version-controlled overlay files, not an opaque heap dump.
4. **Replay durability, not snapshot durability** — so continuation-capture and
   image-persistence, the flashiest Lisp runtime tricks, are things boggart
   routes *around* by design (§5, §6).
5. **Model fluency** — the agent writes this code; subtle metaprogramming is
   where LLMs are weakest.

Rank the Lisp/Scheme family against that intersection and it sorts cleanly:

| Runtime | Embeds in a small C core | Per-unit in-language sandbox | Resource limits (time/mem) | Source is text, not image | Metaprogramming | Model fluency |
|---|---|---|---|---|---|---|
| **Lua** | ✅ *its reason to exist* | ✅ `load(chunk,name,"t",env)` sets `_ENV` | ◐ debug-hook (boggart uses it) | ✅ overlay `.lua` | ◐ metatables + code-as-string | ✅ high |
| **Guile (Scheme)** | ✅ GNU's C extension lang | ✅ `(ice-9 sandbox)` safe bindings | ✅ time + allocation limits | ✅ | ✅ full macros | ◐ |
| **Racket** | ❌ heavy runtime | ✅ `make-evaluator` restricted namespace | ✅ memory/eval/fs/net guards | ✅ | ✅ full macros | ◐ |
| **R7RS Scheme** | ◐ impl-dependent | ◐ `eval` + environment specifiers (bindings only) | ❌ not in the spec | ✅ | ✅ | ◐ |
| **Common Lisp** | ❌ ECL heavy; SBCL not embed-friendly | ❌ no standard restricted eval; reader `#.` is live-eval | ❌ | ❌ the **image** is the idiom | ✅ *maximal* | ◐ low (macros/CLOS/conditions) |

### Reading the table

- **Common Lisp is the most powerful language and the worst *fit*.** It has the
  crown-jewel property Lua lacks — `defun`/`defmethod`/`defclass` redefine
  through symbol cells and generic functions so every caller sees the new code
  live, with no stale-closure discipline — plus maximal macros and the
  condition/restart system. But it fails the two properties boggart's safety and
  distribution rest on: there is **no standard way to sandbox untrusted code
  in-process** (the reader alone does read-eval via `#.`, packages aren't a
  security boundary), and its signature flexibility is the **image**, which is
  the exact opposite of "source is diffable text." CL hands you more power at
  precisely the two axes where boggart needs *containment*, not power.
- **Scheme sandboxes better than CL, by design.** R7RS `eval` takes an
  environment specifier, so you can restrict *which bindings* exist — closer in
  spirit to Lua's `_ENV` than anything in CL. But standard Scheme stops at
  bindings: no resource limits, and "Scheme" is a spec with many runtimes rather
  than one embeddable VM.
- **Racket is the strongest "if not Lua."** `racket/sandbox` gives you *both*
  full macros *and* a real security sandbox with memory, time, filesystem and
  network limits — the combination CL cannot offer. If footprint were free,
  Racket would be a serious answer. But it is a heavyweight runtime, not a
  library you embed in a tiny C core, so it fails property 2 outright and takes
  the single-binary story with it.
- **Guile is the honest closest rival.** It is GNU's *embed-in-C extension
  language* — Lua's own niche — and `(ice-9 sandbox)` provides safe-binding sets
  with time and allocation limits: a genuine language-level sandbox with resource
  bounds. On paper it hits four of the five. Lua wins on the margins that
  compound: a smaller/faster VM with no GC-library dependency, and a sandbox
  that is *just a table you hand the chunk as its `_ENV`* — more legible and more
  minimal than Guile's module machinery — plus materially higher model fluency.

### The move that dissolves the question: Fennel

The Lisp instinct is really about *surface* — s-expressions, macros,
code-as-data. That is separable from the runtime, and on the Lua VM it is
already available: **[Fennel](https://fennel-lang.org) is a Lisp that compiles to
Lua**, runs on the same VM, compiles into the *same* `_ENV` capability sandbox,
and ships in the same single binary. So "should it have been a Lisp?" has a
disarming answer — you can have the Lisp surface, with a full macro system, at
zero architectural cost, *without* giving up the per-unit sandbox, the C
embedding, the text source, or the model-fluency of the underlying Lua. Choosing
the Lua runtime never foreclosed the Lisp ergonomics; it kept them optional.

### Verdict

The "we should have chosen a Lisp" instinct conflates the runtime with the
syntax. The right *runtime* for a **safely** self-modifying, embeddable,
text-sourced agent is a small VM with per-unit environment sandboxing — which is
Lua, with Guile the only real family alternative and Lua ahead of it on size,
legibility, and model fluency. Common Lisp would have handed boggart *more*
metaprogramming and *less* of the one property the whole design rests on
(containable self-modification); Racket has both but cannot embed small; plain
Scheme is a specification, not a runtime. And the Lisp that boggart's instinct is
actually reaching for — homoiconic, macro-capable — is available as **Fennel on
the Lua VM** whenever it is wanted. Lua was not the compromise choice. It was the
choice whose strengths are boggart's requirements, and it left the Lisp door
open besides.

Sources: Lua 5.4/5.5 reference (`load`, `_ENV`, the `debug` library);
R7RS (`eval` + environment specifiers); Racket `racket/sandbox`
(`make-evaluator`, memory/eval limits, security guards); Guile `(ice-9 sandbox)`
(safe bindings, time/allocation limits); Fennel language reference.
