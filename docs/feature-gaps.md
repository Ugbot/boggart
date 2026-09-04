# boggart — feature gaps and opportunities

**Snapshot: 2026-09-03.** A feature map of boggart against the four systems
worth measuring against right now — **Qwen Code** (Alibaba), **DeepSeek
Harness** (`dsh`), **Devin / Cognition**, and **OpenCode** — with **pi** kept in
frame as the ancestor. It answers one question: *what would boggart need in
order to do everything these do, and what can it do that they cannot?*

Companion documents: [`comparisons.md`](./comparisons.md) holds the
rebuild-the-kernel studies (OpenClaw, Codex, pi, Trigger.dev, CodeRabbit,
t3code) and now the four studies behind this map (§9–§12);
[`peers.md`](./peers.md) holds the product-surface snapshot (Codex, Goose,
Claude Code). This file is the **backlog**.

### The counting rule

boggart's thesis is that most "missing features" are not missing, they are
*deferred*: written in Lua by the agent when needed (`define_tool`), or plugged
in over MCP. [`comparisons.md` §3](./comparisons.md) makes that argument and it
still holds, so a checklist audit would be dishonest. Something is counted as a
**gap** here only if one of these is true:

1. It **cannot be written in Lua** (it needs C, a syscall, a front end, or a
   protocol endpoint boggart does not expose).
2. It is a **policy or invariant**, not a capability — something that must be
   true of *every* tool call, which a tool the agent writes for itself cannot
   establish.
3. **Shipping it beats growing it**: the whole field has converged on one shape,
   users expect it on day one, and having the agent reinvent it per session is
   waste (web search, session export, a permission schema).

Everything else is listed as *parity filler* and deliberately ranked below the
structural work.

---

## 0. What the field converged on (Feb–Aug 2026)

The single most important finding of this review is not any one feature. It is
that **two of boggart's signature claims stopped being unique this year.**

- **Self-extension shipped elsewhere.** Qwen Code's `/learn` (2026-07-16) turns
  a finished session into a reusable Skill; DeepSeek Harness went further and
  made *the agent loop itself* a plugin, with "no privileged core to patch."
- **Multi-agent shipped everywhere.** Sub-agents are now table stakes: Qwen Code
  (May, with per-task permission scoping in August), Devin's nested sub-Devin
  session trees, OpenCode's `task`, even Devin Local's Rust rewrite added them.
  pi's refusal to ship sub-agents is now the outlier, not boggart's swarm.

What the field converged on, in rough order of how often it appeared:

| Convergence | Who shipped it | boggart |
|---|---|---|
| **Permission *policy engines*** — glob rules, deny > ask > allow, per-agent overrides | OpenCode, Qwen (fork-profiles), Codex, Claude Code, dsh | mode enum only |
| **Sub-agents with scoped permissions + worktree isolation** | Qwen, Devin, OpenCode, Grok Build | swarm ✅, scoping ◐, worktrees ◐ |
| **Background / scheduled / triggered agents** | Qwen (background, channels), Devin (automations: cron/RRULE, webhook, Jira, Linear, Slack) | ❌ |
| **A client/server control plane** (HTTP + SSE + OpenAPI + generated SDK) | OpenCode, dsh (web-first) | ❌ |
| **ACP** (Agent Client Protocol) as the editor-interop standard | 25+ agents, JetBrains/Zed/Neovim, dsh ships an `acp` profile | ❌ |
| **Skills as a first-class artifact, plus a loop that writes them** | Qwen `/learn`, Claude Code, OpenCode | ✅ skills, ◐ the loop |
| **Explicit cost/token budgets per goal or session** | Qwen goal budgets, Devin ACUs | ◐ turn budgets |
| **Structured output from a session** | Devin (output schemas), dsh (session-log invariant) | ❌ |
| **Chat-platform channels as an inbound surface** | Qwen (Telegram/WeChat/DingTalk/GitHub/GitLab), Devin (Slack) | ❌ |
| **Session export / fork / replay discipline** | Qwen (`/export` md·jsonl·html), dsh ("model-visible means logged"), OpenCode (share) | ◐ |

**Read this as good news, not bad.** Everything in that table is a *feature*.
What still has no analogue anywhere in the field is boggart's *substrate*: a
capability boundary that contains the agent's own generated code, a single
1.8 MB self-contained binary with no Node under it, a C pub/sub bus with a
SQLite journal, and an agent that can write the window it draws its answer in.
The gaps below are almost all buyable; the substrate is not.

---

## 1. The frame

| System | What it is | Stack / licence | Why it is in the frame |
|---|---|---|---|
| **boggart** | mutable C+Lua agent kernel, two front ends, swarm | C + Lua 5.5, single ~1.8 MB exe | the subject |
| **Qwen Code** | Alibaba's terminal agent (Gemini-CLI fork tuned to Qwen3-Coder), now a full product with desktop app + channels | TypeScript, Apache-2.0, ~27k★ | **the closest product rival on boggart's own axes**: self-written skills, sub-agents, worktrees, goal budgets |
| **DeepSeek Harness** (`dsh`) | "everything is a plugin" agent harness on Cordis; no privileged core | TypeScript/Node, MIT, dev preview `0.1.0-rc`, ~203k★ | **the direct thesis rival**: composability by configuration vs boggart's mutation at runtime |
| **Devin / Cognition** | hosted autonomous-engineer *platform*; Windsurf became Devin Desktop (2026-06-02); Devin Local is a Rust agent with sub-agents | proprietary SaaS, ACU billing ($2.25/ACU) | **the autonomy ceiling**: fleets, triggers, org knowledge, cost accounting |
| **OpenCode** | provider-agnostic OSS agent built as a *server* with many clients | TypeScript, MIT, ~150–200k★, 6.5M MAU | **the best-designed permission model and control plane in the field** |
| **pi** | the minimal harness boggart forks from | TypeScript, MIT | the ancestor; see [`comparisons.md` §3](./comparisons.md) |

---

## 2. Feature map

Legend: ✅ have · ◐ partial · ❌ absent · — not applicable.

### A. Core loop and editing

| Capability | boggart | Qwen Code | dsh | OpenCode | pi | Devin |
|---|---|---|---|---|---|---|
| Streaming tool loop, read/write/edit/bash | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Multi-hunk atomic patch | ❌ single unique-match `edit` | ✅ | ✅ | ✅ `patch` | ✅ | ✅ |
| Context compaction | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Compaction on a *cheaper* model | ❌ | ✅ | ◐ | ◐ | ❌ | ✅ |
| Repo index / code search | ✅ `code_index` / `code_search`, **+ LLM Station** (BM25, AST, call graphs) | ✅ | ◐ | ✅ | ◐ | ✅ Wiki/DeepWiki |
| **LSP** | ✅ **via LLM Station** (`mcp__llm-station__*`, auto-detected) | ✅ (2026-02-03) | ◐ plugin | ✅ | ❌ | ✅ |
| **Web search / fetch** | ❌ | ✅ | ✅ | ✅ | ◐ | ✅ + MCP search |
| Image input / display | ❌ | ✅ in-terminal | ✅ | ◐ | ◐ | ✅ |
| Voice input | ✅ opt-in (whisper) | ❌ | ❌ | ❌ | ❌ | ◐ |
| Session export | ❌ | ✅ md/jsonl/html | ✅ | ✅ + share links | ✅ JSONL | ✅ API |
| Mid-turn steering | ◐ Ctrl-C / pause / kill | ✅ inject mid-stream | ✅ | ✅ | ✅ | ✅ |
| Checkpoints / undo | ✅ `refs/boggart/` git refs | ✅ worktrees | ◐ | ✅ undo/redo | ✅ branching sessions | ✅ machine snapshots |
| Provider matrix | ✅ anthropic / openai / responses wires + presets | ✅ any OpenAI-compatible | ✅ adapters on `ctx.llm` | ✅ best-in-class | ✅ 30+ | — |

> `comparisons.md` §2 used to list boggart as "Anthropic only". That row was
> **stale** — the three wire adapters and prompt caching have since landed — and
> has been corrected in place. Provider lock-in is no longer a gap.

### B. Safety and policy — *boggart's weakest column*

| Capability | boggart | Qwen Code | dsh | OpenCode | Devin |
|---|---|---|---|---|---|
| Permission model | ◐ 4-mode enum + per-tool table | ✅ per-subagent profiles (`.qwen/fork-profiles/`) | ✅ approval-policy plugin in `dsh-base` | ✅ **glob policy engine**, last-match-wins, agent overrides | ✅ security profiles |
| Deny-capable hook | ❌ `events` observe only | ✅ | ✅ `agent/*` lifecycle events | ✅ | ✅ |
| Pattern rules (allow `git *`, deny destructive commands) | ❌ | ◐ | ✅ | ✅ | ✅ |
| External-directory guard | ❌ | ◐ worktrees | ✅ | ✅ first-class | ✅ VM |
| Secret-file guard (`.env` denied by default) | ◐ `getenv` refuses secret-ish names | ◐ | ✅ | ✅ | ✅ |
| **Doom-loop guard** (same call 3×) | ❌ | ❌ | ❌ | ✅ | ◐ |
| In-VM capability boundary for agent-written code | ✅ **unique** | ❌ | ❌ (plugins are full Node) | ❌ | — |
| **OS sandbox for the subprocess tier** | ❌ standing item | ◐ | ✅ sandbox plugin | ◐ | ✅ VM per session |
| Network policy per session | ❌ | ◐ | ✅ | ◐ | ✅ |

### C. Multi-agent and autonomy

| Capability | boggart | Qwen Code | dsh | OpenCode | Devin |
|---|---|---|---|---|---|
| Sub-agents | ✅ actors + C bus + journal | ✅ | ◐ plugin | ✅ `task` | ✅ nested session trees |
| Per-sub-agent permission scope | ◐ skill allowlists | ✅ reusable templates | ✅ | ✅ agent-level rules | ✅ |
| Instruction isolation between siblings | ◐ | ✅ explicit | ◐ | ◐ | ✅ |
| Worktree isolation as the default | ◐ tool + skill, opt-in | ✅ | ◐ | ◐ | ✅ VMs |
| **Structured output from a run** | ❌ text | ◐ | ✅ session log | ◐ | ✅ output schemas |
| Background / resident agents | ◐ in-session fleet | ✅ | ✅ | ◐ | ✅ |
| **Triggers**: cron, webhook, push, issue, chat | ❌ | ✅ channels | ✅ scheduling plugin | ❌ | ✅ automations (cron/RRULE, GitHub/GitLab, Jira, Linear, Slack, webhooks) |
| **Cost / token budget per goal** | ◐ turn budgets, watchdog, telemetry | ✅ goal budgets | ✅ | ◐ | ✅ ACUs, priced per action |
| Durable waitpoint (suspend days, survive restart) | ❌ | ❌ | ◐ | ❌ | ◐ |
| Live fleet UI | ✅ FLEET / swarm pane | ✅ workflow flowchart | ✅ web | ◐ | ✅ Agent Command Center |

### D. Extension and distribution

| Capability | boggart | Qwen Code | dsh | OpenCode | pi |
|---|---|---|---|---|---|
| **Runtime self-modification** (mid-session, hot-reload) | ✅ **unique** | ◐ `/learn` writes a Skill | ◐ plugins, composed at boot | ❌ | ❌ |
| Skills | ✅ Lua + `SKILL.md` import | ✅ GA | ✅ | ✅ | ✅ |
| Agent-authored *tools* with provenance | ✅ **unique** (library panel: scope, git rev, call/fail counts) | ❌ | ❌ | ◐ custom tools | ❌ |
| Package format (manifest, version, deps) | ❌ | ✅ | ✅ bundles | ✅ plugins | ✅ Pi Packages |
| **Named composition / profile** | ❌ golden + overlay | ◐ | ✅ profiles stack bundles | ◐ | ◐ |
| Registry / marketplace | ❌ *(correctly)* | ✅ | ✅ hub | ✅ | ✅ |
| MCP consume / serve | ✅ / ❌ | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ | ❌ by design |

### E. Surfaces and interop

| Capability | boggart | Qwen Code | dsh | OpenCode | Devin |
|---|---|---|---|---|---|
| TUI | ✅ | ✅ | ◐ | ✅ | ✅ CLI |
| Desktop | ✅ studio | ✅ (2026-08-06) | ✅ web-first | ✅ | ✅ Devin Desktop |
| Web / mobile | ❌ | ✅ | ✅ | ✅ | ✅ |
| IDE extension | ❌ | ✅ VS Code, Zed, JetBrains | ◐ | ✅ | ✅ |
| **Control server** (HTTP + SSE + OpenAPI + SDK) | ❌ | ◐ | ✅ | ✅ **the design to copy** | ✅ API v3 + PATs |
| **ACP** (editor interop standard) | ❌ | ◐ | ✅ `acp` profile | ◐ | — |
| CI / GitHub Action | ◐ headless | ✅ | ✅ headless profile | ✅ | ✅ |
| Chat channels (Slack/Telegram/DingTalk/…) | ❌ | ✅ | ◐ | ❌ | ✅ Slack |
| **Agent-authored UI panels** | ✅ **unique** (`draw_panel`) | ❌ fixed flowchart view | ❌ | ❌ | ❌ |

---

## 3. The gaps, ranked

Ranked by (impact × cheapness). "Lands in" says where the work is, which is the
honest proxy for cost: Lua is a session, C is a project.

| # | Gap | Who has it | Lands in | Size |
|---|---|---|---|---|
| ~~1~~ | ~~Permission policy engine~~ — **shipped** (glob rules, deny > ask > allow, agent narrowing; `lua/perm.lua`) | OpenCode, Codex, CC, dsh, Qwen | Lua | done |
| ~~2~~ | ~~Deny-capable hooks~~ — **shipped** (`events.ask`, `tool:before` veto) | Claude Code, dsh, OpenCode | Lua | done |
| ~~3~~ | ~~Loop / external-dir / secret guards~~ — **shipped** (doom-loop, outside-workspace, credential files) | OpenCode | Lua | done |
| ~~4~~ | ~~Per-sub-agent permission profiles~~ — **shipped** (`spawn{perms=…}`, narrow-only) | Qwen (fork-profiles) | Lua | done |
| ~~5~~ | ~~Structured returns + budgets~~ — **shipped** (`spawn{schema=…, budget=…}`, enforced by the exit contract) | Devin, Qwen | Lua | done |
| 6 | **Parity filler pack**: `web_search`/`web_fetch`, `/export`, cheap-model compaction, mid-turn steering, worktree-by-default fan-out | everyone | Lua | S each |
| ~~7~~ | ~~Control server~~ — **shipped** (`src/lserve.c` + `lua/control.lua`, HTTP + SSE, `boggart serve`) | OpenCode, dsh, Devin | C + Lua | done |
| 8 | **ACP endpoint** — JSON-RPC over stdio; inherits JetBrains/Zed/Neovim/25+ clients | dsh, 25+ agents | Lua over C stdio | M |
| 9 | **MCP serve** — expose boggart's tools to other agents | Qwen, dsh, OpenCode | C (`lmcp.c` has the machinery) | M |
| ~~10~~ | ~~Triggers + daemon~~ — **shipped** (`lua/triggers.lua`: interval/clock/event + webhooks through the C listener) | Qwen channels, Devin automations | C + Lua | done |
| 11 | **Subprocess jail** — Landlock/seccomp/Seatbelt around `sys.exec` and MCP stdio | Codex, dsh, Devin | C | L |
| 12 | **Durable waitpoints + idempotency keys** (suspend to journal, resume on token) | Trigger.dev; Devin ◐ | Lua on the journal | M |
| 13 | **Profiles / packs** — a named, shareable composition of skills + tools + policy + model | dsh bundles, pi Packages | Lua + a manifest | M |
| 14 | **Multi-hunk atomic patch** | Codex, Qwen, OpenCode | Lua | S |
| ~~15~~ | ~~LSP~~ — **not a gap: LLM Station supplies it** (§3.6) | Qwen, OpenCode, Devin | — | — |
| 16 | **Images** (send + studio display) | Qwen, Devin | Lua (send) + C (studio) | M |
| 17 | **Chat channels** (Slack/Telegram/DingTalk) — now cheap: they are webhook adapters onto the shipped listener | Qwen, Devin | Lua | M |

> **Shipped 2026-09-04.** Seven of the seventeen closed in one pass; see
> [`control-surfaces.md`](./control-surfaces.md) for the design and, more
> importantly, for the C/Lua line each one lands on. The short version: the
> policy engine, the veto hook, the guards, per-agent profiles, structured
> returns, budgets and the trigger table are **Lua**, because they are things
> people must be able to change; the listener, the HTTP framing, the bind rule
> and the token check are **C**, because Lua has no sockets and because an
> enforcement point the agent can rewrite is not one.

### 3.1 Permissions are the one place boggart is behind *everyone* (#1–#4)

`perm.lua` is four modes and a per-tool table. Every peer now ships a *policy
engine*, and OpenCode's is the cleanest specification in the field — worth
copying almost verbatim because it is pure data:

```lua
permission = {
  ["*"]  = "ask",
  bash   = { ["*"] = "ask", ["git *"] = "allow", ["sudo *"] = "deny" },
  edit   = { ["src/**"] = "allow", ["~/.ssh/**"] = "deny" },
  read   = { ["**/.env"] = "deny" },
  external_directory = { ["~/projects/**"] = "allow" },
  doom_loop = "ask",           -- same call three times running
}
```

Rules: **last match wins**, `deny` is never overridable by an auto/yolo flag,
and an *agent* may narrow but not widen the inherited set. Three properties fall
out that boggart cannot get from a mode enum: the policy is **inspectable before
a run**, it is **diffable and shareable** (it belongs in a pack, §3.5), and it
gives the swarm a real per-agent capability grade instead of a skill allowlist
that only names tools.

The **veto hook** (#2) is the other half. `events`/`on_event` observes today;
Claude Code's `PreToolUse` exit-2 contract proves how much product sits on a
hook that can *say no*. In boggart the natural spelling is a handler whose
return value denies with a reason, evaluated inside `run_tool` after the policy
and before dispatch — one seam, one place to trace.

Together #1–#4 are a few hundred lines of Lua and they change what boggart *is*
allowed to do unattended. Nothing else on this list has that ratio.

### 3.2 The interop unlock: a control server and ACP (#7–#9)

[`comparisons.md` §8](./comparisons.md) already reached this conclusion from
t3code — *be controllable rather than build clients* — and 2026 turned it from a
good idea into a standard. ACP is Apache-2.0 JSON-RPC over stdio, adopted by
JetBrains, Google, GitHub and 25+ agents, with a public registry; DeepSeek ships
an entire `acp` profile. **One JSON-RPC endpoint buys boggart every ACP editor
that exists**, which is a better return than any IDE extension boggart could
write, and it is Lua over the stdio plumbing that already exists.

The control server is the same move one level up. OpenCode's architecture is the
reference: a server publishes an OpenAPI 3.1 spec and an SSE event stream, and
the TUI, desktop, web and IDE clients are *all* just clients — there are even
`/tui` endpoints so a client can drive the terminal UI remotely. boggart already
insists on one engine behind two front ends and enforces it with `core-parity`;
the server is that principle made addressable, and it is the same inbound
listener that #10 needs. Build the listener once and it pays for ACP, the
control server, webhooks and channels.

`serve` for MCP (#9) is the cheapest of the three — `src/lmcp.c` already speaks
both protocol generations as a client, and boggart's tool registry is exactly
the thing an MCP server exposes.

### 3.3 Triggers are no longer optional (#10)

Both `comparisons.md` §1 and §4 flagged "always-on daemon + inbound" as the
recurring blocker. In 2026 the peers shipped it: Qwen Code has a **Channels
platform** (Telegram, WeChat, DingTalk with interactive cards, GitHub, GitLab)
and background agents that stay resident after a task; Devin has **automations**
with cron/RRULE, run-once schedules, and triggers on GitHub/GitLab pushes, Jira
issues, Linear items, Slack messages and raw webhooks.

This is the gap where boggart has fallen *behind the field*, not merely behind
one peer, and it is the gate on the whole business-process direction
(`comparisons.md` §4–§6). libuv is already vendored; the missing pieces are an
inbound transport, a supervisor, and a scheduler that does not exit at
quiescence. Note the security coupling — an inbound channel means
attacker-controlled text reaching a tool loop, so #10 must not land before #1
and should not land before #11.

### 3.4 Making fan-out programmable (#5)

boggart's swarm is architecturally ahead of Qwen's sub-agents and comparable to
Devin's session trees — but a boggart sub-agent **returns prose**. Devin returns
against a **structured output schema**, which is what makes a fleet composable:
the coordinator branches on a value instead of re-reading English. Pair it with
Qwen's **goal budgets** and Devin's **per-node cost accounting** (they price
every action in ACUs and show the estimate *before* a run) and the FLEET view
becomes a control surface rather than a monitor. All three are Lua, and boggart
already has the telemetry to feed them.

### 3.5 Packs: the distribution unit boggart doesn't have (#13)

DeepSeek Harness's most portable idea is not the plugin tree, it is the
**profile**: a *named composition* that stacks bundles, pins the out-of-tree
plugins it needs, and carries the user's own config patch. boggart has the two
ends — a golden baked-in default and a mutable overlay — and nothing in between,
so a working setup cannot be named, versioned, diffed or handed to anyone.

The fix is not a marketplace (see §5). It is a manifest: a **pack** =
`{ skills, generated tools, permission policy, model/wire, MCP servers, panels }`,
installable, stackable, and *reset-able* against the golden. The library panel
already tracks every generated tool with its scope, defining git revision and
call/fail counts — which means boggart is the only system in this review that
can emit a pack **with provenance**, as the by-product of a session that worked.
That is a genuinely novel artifact, and it is how self-extension escapes the
machine it happened on.

### 3.6 LLM Station — the "plug it in" half of the thesis, already in production

The counting rule above says a capability is not a gap if it can be **plugged in
over MCP** rather than built into the core. That argument is usually a promise.
Here it is shipped: **LLM Station** is a local code-intelligence daemon that
boggart auto-detects (`lua/llmstation.lua`) and mounts over its C MCP client,
registering its tools as ordinary `mcp__llm-station__*` entries — **116 tools in
a live session of this repo**. It brings the whole semantic tier boggart
deliberately never wrote itself:

- **LSP** — real language servers, not a bespoke approximation.
- **TreeSitter ASTs, call graphs, function indexes** — structural navigation.
- **BM25 full-text search over a persistent workspace index** (`.llm-station/`:
  marble BM25 segments, `funcindex`, `project.db`, checkpoints).
- **Refactoring operations** — deterministic, not model-guessed.

Three consequences for this review:

1. **The LSP/repo-map "gap" is closed, and closed the right way.** `comparisons.md`
   §3 predicted exactly this ("real LSP beats a bespoke embedding index"). Qwen
   Code bought LSP by forking someone else's client into its core; boggart got it
   by mounting a daemon and writing ~110 lines of detection. The core stayed
   small — which was the entire bet.
2. **It is best-effort by design.** No station installed means the module lies
   dormant and boggart is unchanged; the single binary keeps working offline with
   nothing to install. That is the correct shape for an optional heavy dependency
   and worth preserving as more capability arrives this way.
3. **It is the model for every remaining "buy vs build" call on this list.** Ask
   of each gap whether a station-shaped daemon behind MCP could serve it before
   putting it in the core. Deterministic, index-heavy, language-specific work
   (semantic search, refactoring, static analysis aggregation from §7 of the
   comparisons) belongs there. Policy, the capability boundary, the journal, and
   the agent loop cannot — they must be in the kernel, which is why the ranked
   gaps above are what they are.

The one caveat is scoping: 116 tools is far more than any single agent should
see at once, and the per-agent skill allowlists (`mcp__llm-station__*` or named
subsets) are what keep a station of that size from flooding an agent's context.
That mechanism already exists and this is the case that proves it earns its keep.

---

## 4. Opportunities — what only boggart can ship

Gaps are catch-up. These are the moves the peers structurally cannot copy.

**1. The capability boundary is also the effect-replay boundary.**
`comparisons.md` §6 argues this; the 2026 field makes it sharper. dsh's session
principle is *"model-visible means logged"* — anything reaching a model request
must be reconstructible from the session log — and that gives it clean fork,
resume and replay. But a dsh plugin is **full Node**: it can do anything, so the
harness can never guarantee an effect was recorded. In boggart a step touches
the world *only* through a C capability, so the log can interpose at the one
lawful channel and **enforce** the invariant instead of documenting it. Adopt
dsh's rule as a boggart invariant and boggart gets something dsh cannot have:
**replay that is sound because the sandbox says so.** This is the single
strongest idea in the whole review.

**2. Tool packs with provenance.** Qwen's `/learn` writes a Skill from a
session — a markdown prompt bundle. boggart writes *executable,
capability-scoped Lua* and already records who defined it, at which git
revision, under what scope, and how often it has failed since. Publishing that
as a pack (§3.5) makes boggart's self-extension **transferable and auditable**,
which is the objection everyone raises about self-modifying agents and the one
boggart is already 80% equipped to answer.

**3. The agent writes the dashboard.** Qwen shipped a session-workflow flowchart
this August; it is a fixed view someone at Alibaba designed. boggart's
`draw_panel` lets the *agent* write the surface for the process it is currently
running — a diff for code, an approval board for a business process, a custom
chart for whatever it just computed. As agent work moves from "answer a
question" to "run a process", the fixed dashboard is exactly what stops fitting.
No peer has this and none of their architectures wants it.

**4. One binary, no Node.** Qwen Code, dsh, OpenCode, Cline, Continue, Kilo —
the OSS field is a Node monoculture. boggart is a self-contained ~1.8 MB
executable that runs offline against a local model server over any of three
wires. For air-gapped, regulated, embedded, or simply cost-sensitive users that
is not a preference, it is the only option in the list. It is also the property
that every "just add a plugin ecosystem" suggestion quietly costs, which is why
packs must be Lua and not a runtime.

**5. Adversarial swarm review with capability grades.** `comparisons.md` §7 made
the CodeRabbit case; Alibaba's own **open-code-review** (deterministic pipelines
+ an LLM agent, battle-tested internally, then open-sourced) confirms the
market. boggart's differentiator stands: multi-agent adversarial verification
before a finding is posted, plus repo-specific checks the reviewer writes for
itself, run locally with no code leaving the building. Add #1's per-agent policy
and the reviewers are provably read-only — a claim no SaaS reviewer can make
about your repo.

**6. Lua steps as durable workflow nodes.** The composition layer from
`comparisons.md` §6, now with the field's own vocabulary attached: Devin proved
the demand for triggers and schedules, Trigger.dev proved the durability
primitives, dsh proved the log discipline. boggart is the only one whose *step
language is the sandboxed one*.

---

## 5. What not to build

- **A marketplace or plugin registry.** Packs (§3.5) yes; a hub, no. dsh, Qwen
  and OpenCode have distribution, teams and star counts boggart is not competing
  for, and a registry is a moderation and trust problem, not a feature.
- **Hosted VMs, ACU-style billing, an org wiki, a web SaaS.** That is 90% of
  Devin and none of it is a kernel property.
- **An IDE fork or a client suite.** Ship ACP (§3.2) and inherit JetBrains, Zed
  and Neovim instead. The same logic kills mobile and web clients: be
  controllable.
- **CRIU-style checkpoint/restore.** Settled in `comparisons.md` §5 — replay,
  not snapshot.
- **A bespoke LSP implementation.** Real language servers over MCP, as §3 of the
  comparisons already argued; **LLM Station already supplies this** (§3.6), and
  Qwen bought the same thing by forking someone else's client into its core.
- **Rewriting the extension story in another language.** The Node field is
  crowded and the single-binary property is the differentiator (§4.4).

---

## 6. Suggested order

Three arcs, each independently shippable, plus parity filler as ballast.

**Arc 1 — Policy** *(gaps 1–4, 11; mostly Lua, one C project)*
Policy engine → deny-capable hooks → loop/external/secret guards → per-agent
profiles → subprocess jail. This arc is the precondition for every other arc,
because Arc 3 is what makes untrusted input reach the tool loop.

**Arc 2 — Interop** *(gaps 7–9, plus `/export`)*
Inbound listener on libuv → control server (OpenAPI + SSE) → ACP endpoint →
MCP serve. One listener, four payoffs; the studio and the TUI become clients of
the thing that `core-parity` already claims they are.

**Arc 3 — Autonomy** *(gaps 5, 10, 12, 13)*
Triggers and a resident scheduler → structured returns and budgets → durable
waitpoints and idempotency → packs. This is `comparisons.md` §4–§6 executed,
and it is what turns boggart from a coding agent into the domain-neutral kernel
those sections argue for.

**Filler, any time** *(gap 6, 14–16)*: `web_search`/`web_fetch`, session export,
cheap-model compaction, mid-turn steering, worktree-by-default fan-out,
multi-hunk patch, images. Each is a session's work and each closes a "why
doesn't it have…" that costs boggart credibility in a demo.

---

**Bottom line.** Measured against Qwen Code, DeepSeek Harness, OpenCode and
Devin, boggart is not behind on the agent loop, on multi-agent, or — now that
the wire adapters have landed — on providers. It is behind on exactly three
things: **policy** (everyone has a permission engine; boggart has a mode enum),
**interop** (everyone is addressable over a server or ACP; boggart is a
terminal), and **autonomy** (everyone can be triggered; boggart exits at
quiescence). All three are known, scoped, and mostly Lua. Meanwhile the field
spent 2026 catching up to boggart's *ideas* — self-written skills, sub-agent
fleets, composable cores — and in doing so demonstrated that none of them can
reach boggart's actual moat: a self-modifying agent whose generated code is
contained by construction, in one binary, that can write its own interface.
Close the three gaps and boggart does everything these systems do; the moat is
the part that was never on their roadmap.

---

Sources: [QwenLM/qwen-code](https://github.com/QwenLM/qwen-code) and the Qwen
Code docs feature-update log (Agent Skills GA 2026-02-09, LSP 2026-02-03,
channels 2026-04-09, sub-agents 2026-05-21, worktree isolation 2026-05-28,
`/learn` 2026-07-16, background agents 2026-07-30, desktop + sub-agent
permissions 2026-08-06/13, goal budgets 2026-08-27);
[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
README and `docs/architecture.md` (plugin tree, profiles/bundles, `dsh-base`,
Cordis services/events, the session-log principle), released 2026-08-13 under
MIT as a developer preview; [Devin docs](https://docs.devin.ai) 2026 release
notes and pricing (sub-Devin sessions, automations and triggers, machine
snapshots, Wiki v2, MCP marketplace, security profiles, API v3, ACUs) plus the
Windsurf → Devin Desktop transition (2026-06-02) and Devin Local;
[opencode.ai/docs](https://opencode.ai/docs) (server/client architecture,
OpenAPI 3.1 + SSE + generated SDK, and the permissions reference);
[Zed's Agent Client Protocol](https://zed.dev/acp) and its 2026 registry with
JetBrains; [alibaba/open-code-review](https://github.com/alibaba/open-code-review);
and a 2026 survey of the OSS CLI-agent field for stars, licences and stack.
