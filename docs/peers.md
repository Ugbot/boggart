# boggart — product-surface peers

How the **front ends** stack up against the three coding agents people actually
compare boggart to. The architecture studies ("could you rebuild X on the
kernel?") live in [`comparisons.md`](./comparisons.md). This file is the
**product** snapshot: TUI chrome, studio, permissions, MCP UX.

Snapshot date: 2026-08-19, after the cTUI composer/complete work, studio shell
chrome, shared `perm.lua`, and `/react`. The kernel verdict is the same in all
three: **boggart already is that core**. The remaining gaps are chrome, policy,
and distribution — not the agent loop.

Skip by design everywhere: voice, images, full vim, `keybindings.json`, OSC-8,
rewind UI. Those are listed in [`tui-complete.md`](./tui-complete.md).

---

## 1. OpenAI Codex — sandboxed TUI

**What it is.** A Rust terminal coding agent (`codex-rs`) with a thin CLI
wrapper, plus IDE and desktop apps. The TUI is the product people mean. Its
defining investment is **OS sandboxing + an approvals state machine**, not
composer polish.

Codex modes: sandbox `read-only` / `workspace-write` / `danger-full-access`
(Seatbelt on macOS, Landlock+seccomp on Linux); approval policies `untrusted` /
`on-failure` / `on-request` / `never`. File edits go through structured
`apply_patch`. Project guidance is `AGENTS.md`. MCP consume + serve. Headless
`codex exec`. Session resume from rollout files.

The architectural comparison (sandbox as the one heavy C lift, `apply_patch`,
provider lock-in) is [`comparisons.md` §2](./comparisons.md). This section is
what you *feel* in the terminal and in studio.

### Kernel

Peer. Streaming tool loop, read/write/edit/shell, sessions + resume, headless,
project-instructions file (`CLAUDE.md` / `AGENTS.md` / `BOGGART.md` loader).
Boggart exceeds Codex on **runtime self-modification** and **native swarm**.
Codex exceeds boggart on **OS jail + approval policy** and **multi-hunk patch**.

### TUI

| Surface | Codex | boggart `--tui` |
|---|---|---|
| Composer (multiline, history, paste, Tab / `@` / `/`) | ✅ | ✅ (this cycle) |
| Permission / sandbox bar | ✅ defining chrome | ❌ does not gate `run_tool` |
| Status footer (mode, tokens, sandbox) | ✅ | ❌ |
| Approvals state machine | ✅ | ❌ (policy lives in `lua/perm.lua`, unwired here) |
| OS sandbox | ✅ | ❌ by design until the subprocess jail |

The composer caught up. The thing people notice in Codex — **a visible
permission/sandbox mode you can cycle** — is still missing from the TUI.

### Studio

Studio is closer to Codex **desktop** than to the Codex TUI: AGENT / EDIT /
FLEET, diffs, approval gate, recents rail, recipes, MCP add/edit. It still has
no Seatbelt/Landlock, no `apply_patch`-grade atomic multi-file hunks, and no
Codex-style escalation-from-sandbox prompts.

### Biggest holes vs Codex

1. **No OS sandbox.** The capability boundary already jails Lua; `sys.exec` and
   MCP stdio leave it. That is still the one C lift ([`comparisons.md` §2 and
   §3](./comparisons.md)).
2. **TUI permission bar.** Shared `perm.lua`; Shift-Tab and `/mode` on both
   surfaces. Remaining Codex gap is the OS sandbox, not the mode chrome.
3. Do **not** start an IDE extension or desktop clone to "match Codex." The
   TUI bar + subprocess jail are the honest parity items.

**Bottom line.** Codex is the safer daily driver because of the jail. Boggart
is the better kernel (mutable Lua, swarm). Matching Codex *as a product* is
additive Lua for the permission bar, then C for Landlock/Seatbelt — not a
rewrite.

---

## 2. Goose (Block) — MCP desktop + CLI

**What it is.** [block/goose](https://github.com/block/goose) is an open-source
coding agent with a **desktop app and a CLI**, built around **MCP extensions**.
The product story is: pick a provider, add extensions, pick a permission mode,
run. Recipes are shareable prompt+tool packs. `/mode` and `goose configure`
are first-class.

Permission modes (the ones boggart copied into `lua/perm.lua`):

| Goose | boggart `perm.lua` | Behaviour |
|---|---|---|
| `auto` | `auto` | tools run without asking |
| `smart_approve` | `smart` | ask before writes / edits / commands |
| `approve` | `manual` | ask before every tool |
| `chat` | `chat` | no tools |

Goose also has per-tool Always Allow / Ask / Never, a smart-approval classifier
for borderline calls, `/plan`, and an extensions configure flow (builtin,
stdio MCP, streamable HTTP).

### Kernel

Peer on the loop. Goose's differentiator is **extensions as the growth path**
(MCP-first); boggart's is **Lua `define_tool` + overlay** (MCP is one of the
growth paths, not the only one). Swarm / FLEET is ahead of Goose's single-agent
default. Goose is ahead on **provider matrix** (many vendors out of the box).

### TUI / CLI

Goose CLI has `/mode`, `/plan`, extension flags, and an external-editor
prompt. Boggart `--tui` now matches Goose on **input** (composer, completion,
slash, `@` files) **and** on **mode cycling** (Shift-Tab / `/mode`).

### Studio vs Goose desktop

| Goose desktop | boggart studio (shell) |
|---|---|
| Mode button, per-tool permissions | AgentView Shift-Tab; `perm.lua` modes **match** |
| Add / toggle / remove extensions | MCP add/edit — landed; no extension marketplace |
| Recipes | recipes menu → `send_prompt` |
| Sessions sidebar | AGENT docks the recents rail |
| Provider configure wizard | env / flags / Lua; no `goose configure` equivalent |
| Plan mode | `plan` tool + HTN/GOAP; not a session UX mode |

Studio already has the Goose **permission shape**. The missing Goose-like
piece is **extension UX as a product**: a configure wizard, enable/disable
without editing Lua, and a browsable catalog. MCP add/edit is the start, not
the store.

### Biggest holes vs Goose

1. **TUI now exposes the modes studio already had.** Shift-Tab and `/mode`
   share `perm.lua`. Remaining Goose-like work is a configure wizard, not the
   bar.
2. **No OS sandbox** (same as vs Codex). Goose is also not Seatbelt-first;
   Codex is the sandbox bar, Goose is the **mode + extensions** bar.
3. **Provider picker / configure wizard.** Soft; overlay-mutable `api.lua` can
   grow adapters, but Goose ships the menu.

**Bottom line.** Goose is the template for **studio permissions and MCP
extensions**. Copy the mode enum (done). Copy the TUI bar (not done). Do not
build a plugin marketplace unless the studio configure flow is already boring.

---

## 3. Claude Code — the named TUI floor

**What it is.** Anthropic's coding-agent **product**: TUI, desktop, VS Code /
JetBrains, web, Slack. The TUI is the bar this repo already names
([`tui-quality.md`](./tui-quality.md), [`tui-complete.md`](./tui-complete.md)).

Signature pieces (2026):

- **Permission modes** on Shift-Tab: `default` → `acceptEdits` → `plan` →
  `auto` / `dontAsk` / `bypassPermissions`. Rules: deny > ask > allow.
  `/permissions`. `--dangerously-skip-permissions`.
- **Hooks**: JSON configs, ~29 events (`PreToolUse`, `PostToolUse`,
  `SessionStart`, `Stop`, `SubagentStart`, …). Exit 2 from PreToolUse **blocks**
  the tool. Prompt-based hooks. `StopFailure` can auto-continue.
- **Skills**: project/user/plugin `SKILL.md`, auto-discovery, `/skills`.
- **Subagents**: `/agents`, Explore/Plan built-ins, fork (`--agent`,
  `--delegate`), `/subtask`, background agents, `/loop`.
- **MCP**: `/mcp`, OAuth, resources, server instructions.
- **Memory**: `CLAUDE.md` / `CLAUDE.local.md` hierarchy, `/memory`, auto-memory.
- **Worktrees**: `/rewind`, isolated checkouts, `/resume`, `/session`.
- **Chrome**: `?` overlay, status footer (mode / tokens / MCP / vim), Esc
  interrupt, `/clear` `/compact` `/cost`, `!` bash, Ctrl-G editor, `/copy`,
  vim, transcript search `{` `}`, thinking blocks, tool cards + diffs.
- **Plugins / marketplace**, LSP, voice, images, desktop.

### Kernel — already in the same league

| Claude Code | Boggart |
|---|---|
| Tools, streaming, sessions, git, web | Same idea: `bog.*`, `run_tool`, `api.run_on` |
| Skills (`SKILL.md`) | First-class **Lua** skills + `SKILL.md` **import** (compile, not native markdown runtime) |
| Subagents / Task / Explore | **Swarm** + FLEET + `subagent` / `task` / `explore` / `plan` tools |
| MCP | `bog.mcp`, `/mcp`, `mcp_add` / `mcp_auth` |
| `CLAUDE.md` | `lua/claudemd.lua` + `/init` |
| Worktrees | `git_worktree` skill + `worktree` tool |
| Hooks | `lua/events.lua` + `on_event` — **nvim-style globs**, not CC's JSON + exit-2 gate |
| Permissions | `lua/perm.lua` — **both surfaces**; TUI gates `run_tool` and draws the bar |
| ReAct / loops | Inner Thought→Act→Obs; `/until`; `/react` |

Boggart is **more programmable** (Lua REPL, live `src/`, swarm as a first-class
UI). Claude Code is **more productized**.

### TUI — this is where Claude Code still wins

**Shipped (matches CC well enough).** Readline, multiline (Shift-Enter /
Ctrl-J), history, Ctrl-R, paste, Tab / `@` / `/`, files+skills+MCP in `@`,
slash registry.

**Still missing** (the [`tui-complete.md`](./tui-complete.md) "Next" list,
still accurate):

1. **Permission bar + Shift-Tab** — wired. Studio and TUI share `perm.lua`.
2. **Status footer** — mode is on the TUI status row (tokens via `/cost`).
3. **`?` shortcuts overlay**
4. **Esc = interrupt generation** (CC; vim Esc is skipped by design)
5. **`/clear` `/compact` `/cost` `/copy`**
6. **`!` bash mode**
7. **Ctrl-G external editor**
8. **Transcript**: tool cards, diffs, thinking, search, `{` `}` blocks
9. **Too-small terminal** handling
10. **Plan mode** as a permission/UX mode (CC `plan`), not only a `plan` tool

### Studio vs Claude Code desktop

Studio is the closer analogue to **Claude Code desktop / Cowork**, not the TUI.

| Claude Code desktop | Boggart studio (shell) |
|---|---|
| Chat + editor + permissions | AGENT / EDIT / FLEET, perm in AgentView |
| File attach, session mgmt | attach, search/rename/delete |
| Skills / MCP UI | recipes, MCP add/edit |
| Subagents panel | FLEET + SwarmView |
| Plan / hooks / marketplace | thinner; no plugin store |
| Rewind, voice, Slack | no |

Studio is **ahead of the TUI** on permissions, sessions, MCP UX, and swarm. It
is **behind Claude Code** on hooks-as-product, plan mode, marketplace, and the
polished transcript.

### Permission model (important mismatch)

Claude Code: **policy engine** (settings.json allow/deny/ask) + **mode** (how
aggressive) + **hooks** (PreToolUse can veto).

Boggart: **mode enum** in studio (`perm.lua`) + **Lua events** (can log/react,
not a first-class deny channel like exit 2). TUI: **no gate**.

Goose-like **mode cycling** exists in studio; Claude Code-like **rules +
bypass + plan** do not.

### Skills / agents

- CC: drop `SKILL.md`, auto-loads, `/skills`.
- Boggart: Lua modules in `lua/skills/`; markdown is an **import path**.
  Power-user win, worse "just add a file" story.

- CC: named subagents with their own tools/prompts, foreground or background.
- Boggart: swarm + `subagent` tool + FLEET. Similar **capability**, different
  **UX** (no `/agents` wizard, no `--agent` fork flag on the CLI in the CC
  sense).

### Honest ranking

| Layer | vs Claude Code |
|---|---|
| Agent runtime / tools / MCP / git | **Peer** (different language) |
| Swarm / multi-agent | **Peer or stronger** (FLEET is a real UI) |
| Studio | **Same category**, less polish, no marketplace/hooks product |
| cTUI composer | **Caught up** on input |
| cTUI chrome + permissions + transcript | **Caught up** on chrome and permissions; transcript cards still thinner |

Claude Code's remaining moat is **product chrome + permission/hook policy +
distribution** (IDE, web, Slack), not the agent loop. Boggart's moat is
**Lua-as-the-harness**.

---

## What to do with this

If the goal is "feels like the peers," do **not** start with desktop clones,
voice, or a plugin store.

1. **TUI permission bar** — done (Shift-Tab / `/mode`, shared `perm.lua`).
2. **TUI chrome** — done (`?`, footer mode, Esc interrupt, `/clear` `/compact`
   `/cost` `/copy`, `!`, Ctrl-G). See [`tui-complete.md`](./tui-complete.md).
3. **Transcript cards** — tool calls as blocks + diffs, not raw stream. The
   remaining polish (thinking collapse in the TUI, in-transcript search).
4. Then **hooks that can deny** (map `PreToolUse` → `events` + perm) if the
   Claude Code security story matters, and the **subprocess jail** if the Codex
   story matters.

| Peer | Their moat | Ours | Next honest step |
|---|---|---|---|
| Codex | OS sandbox + approvals | Lua mutability, swarm | Landlock/Seatbelt |
| Goose | MCP extensions + mode UX | same modes on both surfaces | studio configure flow |
| Claude Code | chrome, hooks, distribution | kernel + FLEET | transcript polish |
