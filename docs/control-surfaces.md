# boggart — control surfaces, and the C/Lua line

**Snapshot: 2026-09-04.** What boggart can be *controlled through*, what it can
be *woken by*, and — the question this document exists to answer precisely —
**which parts of that are C, which are Lua, and why each C part has to be C.**

The companion documents: [`comparisons.md`](./comparisons.md) is the field
study, [`feature-gaps.md`](./feature-gaps.md) is the ranked backlog,
[`peers.md`](./peers.md) is the product snapshot. This one is the architecture
rule and the ledger that follows from it.

---

## 1. The rule

boggart's whole thesis is that the harness is rewritable at runtime. Every line
that is C is a line the agent **cannot** rewrite, so C is not where code goes to
be fast or tidy — it is where code goes to be **impossible to route around**.
Something belongs in C only if at least one of these is true:

1. **Lua cannot express it.** Sockets, syscalls, the event loop, process
   control, entropy, terminal control, pixels. No amount of self-modification
   adds a listening TCP port to a language with no sockets.
2. **It must be non-negotiable.** An enforcement point that the agent's own
   mutable Lua could edit is not an enforcement point. This is the existing
   house rule — `sys.rmtree` refuses `/` in C, `proc.run` bounds its output in
   C, `getenv` refuses secret-ish names in C — applied consistently.
3. **The cost is structural.** A hot path where the per-call overhead is the
   feature: glyph rasterisation, the dirty-rect cache, the pub/sub bus.

And the converse, which matters just as much: **anything that a reasonable
person would want to change should be Lua.** Routes, policy tables, payload
shapes, schedules, prompts, panels, skills, what a trigger means. If it is in C
and it is none of the three things above, that is a bug in the design, not a
detail.

The test for a proposed C addition is one sentence: *"what breaks if the agent
rewrites this?"* If the answer is "nothing, it just behaves differently", it is
Lua.

---

## 2. The ledger

Every C module in `src/`, why it is C, and what would be lost if it were not.

| Module | What it is | Why C | If it were Lua |
|---|---|---|---|
| `lauth.c` (routing) | the credential for the endpoint a request is **actually going to** | (2) the key must never be readable from Lua: Lua names a url, C picks the key | a fleet spanning two providers would send one's key to the other's host |
| `lserve.c` | **inbound control plane**: TCP listen/accept, HTTP/1.1 framing, SSE pump, bind rule, token check | (1) Lua has no sockets; (2) the loopback-default and the constant-time token compare must not be editable | there would be no inbound at all — and an auth check the agent can rewrite is decoration |
| `lhttp.c` | outbound HTTP + SSE streaming (libcurl) | (1) TLS and sockets | no model calls |
| `lsys.c` | fs, exec, paths, globs, process caps — **with the refusals in it** | (1) syscalls; (2) `rmtree` refusing `/`, `getenv` refusing secrets | the capability boundary would have a hole in exactly the places it matters |
| `ldb.c` / `lrepo.c` | SQLite store; the semantic data API behind a vtable | (1) the C library; (3) every session write | slower, and the store's integrity rules become suggestions |
| `lswarm.c` | agent mailboxes, pub/sub, the **journal** write-through | (2) the journal is the audit record; (3) hot | a self-modifying agent could edit its own audit trail |
| `lbus.c` | messaging fabric: pub/sub + work queues, one mutex, cross-thread safe | (1) threads and mutexes; (3) hot | no worker threads could publish |
| `lmcp.c` | MCP client: stdio + Streamable HTTP, both protocol generations | (1) subprocess pipes and sockets | no MCP |
| `lworker.c` | real OS worker threads, each with its own Lua state | (1) threads | cooperative concurrency only |
| `lgit.c` | git plumbing, checkpoints confined to `refs/boggart/` | (2) the ref-prefix confinement is enforcement | an agent could write any ref, including yours |
| `lauth.c` | credential storage and endpoint/wire resolution | (2) credentials | keys reachable from generated tool code |
| `lvoice.c` | whisper.cpp + audio capture (opt-in) | (1) audio devices | no voice |
| `lterm.c` / `termctl.c` / `ltermctl.c` | tty control, line editing, the full-screen cell grid | (1) termios/ioctl; (3) per-keystroke | no TUI |
| `lmem.c` | memory/FTS5 surface | (3) hot; (1) the C library | slower search |
| `jwriter.c` | lock-free journal ring buffer | (3) hot; (1) atomics | dropped records under load |
| `bogembed.c` | the baked-in Lua and the shared `boggart_open_libs` | (1) it *is* the embedding | no single-binary story |
| `studio/src/*` | renderer, rencache, fonts, assets | (1) GPU/FreeType/SDL; (3) every frame | no window |

**Deliberately NOT in C**, and the reasons are the mirror image:

| Surface | Where it lives | Why not C |
|---|---|---|
| The agent loop, streaming, tool dispatch, compaction | `lua/api.lua` | the thing most worth rewriting |
| Permission **policy** — rules, guards, agent narrowing | `lua/perm.lua` | a policy table is data, and people must be able to read and change theirs |
| Control-plane **routes** | `lua/control.lua` | endpoints change weekly; a compiled-in route list would be a different project |
| **Triggers** — schedules, event bindings, what firing means | `lua/triggers.lua` | "every 5 minutes" is not a syscall |
| Tools, skills, agents, prompts, panels | `lua/*`, `lua/skills/*` | the self-extension story |
| Studio menus, views, keymap | `studio/data/**` | discoverability is content, not machinery |

---

## 3. What shipped in this pass

### 3.1 Permission policy engine — Lua (`lua/perm.lua`)

The four modes (auto/smart/manual/chat) answered *how much should it ask?* and
nothing else, so "git is fine, never touch `~/.ssh`" had nowhere to live. Rules
add the missing axis — **which call** — as plain data:

```lua
permissions = {
  ["*"] = "ask",
  bash  = { ["*"] = "ask", ["git *"] = "allow", ["sudo *"] = "deny" },
  edit  = { ["src/**"] = "allow", ["~/.ssh/**"] = "deny" },
  read  = { ["**/.env"] = "deny" },
}
```

Resolution, first answer wins: an explicit runtime `tool_policy` entry → a guard
verdict → a rule match (last match wins; a tool's own table beats `"*"`) → the
mode enum, unchanged. Three guards ship on by default because every peer has
them and boggart had none: **secrets** (`.env`, `id_rsa`, `.ssh/**`,
`.aws/credentials` — denied, and no rule can open them), **outside the
workspace** (asks), and **doom loops** (the same call three times running asks).
`st.guards = false` turns them off per project.

Two properties are load-bearing. **Segmentation follows the subject, not the
pattern**: `*` stops at `/` for a path and crosses it for a shell command, so
`src/*` means one directory level and `sudo *` still matches `sudo rmdir /tmp/x`.
And **an agent may narrow what it inherited, never widen it** — a sub-agent
profile can turn allow into deny, never the reverse, which is what makes a
per-agent profile a safety property instead of a suggestion.

The invariant that keeps this additive: **with no rules configured, every
decision is exactly what the mode enum gave before.** `tests/perm.lua` asserts
that across all four modes and five tools.

### 3.2 A veto channel — Lua (`lua/events.lua`)

`events.emit` notifies and discards every return value, which is right for an
observer and useless for a gate. `events.ask(name, data)` dispatches the same
handlers and returns the **first non-nil answer**, so a hook can refuse:

```lua
bog.events.on("tool:before", function(_, ev)
  if ev.tool == "bash" and ev.input.command:match("push %-%-force") then
    return { deny = true, reason = "this repo forbids force-push" }
  end
end)
```

The reason reaches the model in the `permission_error`. Existing handlers return
nothing and are unaffected. This is Claude Code's `PreToolUse` exit-2 idea, in
the language the harness is written in.

### 3.3 The inbound control plane — C transport + Lua routes

**C (`src/lserve.c`, ~600 lines).** `uv_tcp` listener on the existing loop,
HTTP/1.1 request framing (request line, headers, `Content-Length` body — no
chunked, no pipelining, because every feature parsed is a feature that can be
malformed at you), SSE keep-alive and broadcast, size caps, `uv_random` tokens.
Plus the two rules that must not be Lua:

- **loopback by default**, and a non-loopback bind **with no token is refused
  outright** — in C, with a message, not a warning in Lua;
- the bearer token is compared in **constant time**, before any route is
  reached, so no route can forget to check it.

**Lua (`lua/control.lua`).** The routes, and nothing else:

| Route | What it does |
|---|---|
| `GET /health` | version, mode, model, session, fleet size, client count |
| `GET /routes` | describes itself — a control plane you must read the source of is not one |
| `GET /tools` | the live registry |
| `GET /sessions` | recent sessions |
| `GET,POST /permissions` | read or set the mode **and the rule table**, over the wire |
| `GET /agents`, `POST /cancel` | the live fleet; stop it |
| `POST /prompt` | queue a turn (async — watch `/events`) |
| `POST /hooks/<name>` | **an outside event becomes `hook:<name>`** |
| `GET,POST,DELETE /triggers…` | schedules and event bindings |
| `GET /events` | SSE: every event on the bus, live |

### 3.4 `boggart serve` — the daemon

The always-on mode every comparison study kept naming as the missing piece.
`boggart serve [--port N] [--host H] [--token T]` stands up the same runtime as
every other mode, keeps the process alive, restores persisted triggers, and
serialises inbound prompts through one queue.

One design note worth keeping: **the daemon is a scheduler actor, not a uv timer
callback.** A turn yields (on HTTP, on a subprocess), and yielding is only legal
inside a coroutine the scheduler drives — running a turn from a timer callback
re-enters `uv.run` and kills the process on its first job (it did, before this
was fixed). As an actor it yields like any other agent, and because it never
returns, `sched.run` keeps turning the loop, so the C listener keeps accepting
while a turn is in flight.

### 3.5 Triggers — Lua (`lua/triggers.lua`)

What starts work when nobody is typing. A trigger names an occasion and what to
do about it:

```lua
triggers.add("nightly",  { at = "09:00" },     "summarise yesterday's commits")
triggers.add("poll",     { every = 300 },      "check the deploy queue")
triggers.add("on-push",  { on = "hook:push" }, "review the pushed diff")
```

`every` and `at` are clock-driven from **one** uv timer (a hundred schedules
should not be a hundred handles); `on` binds any event, which includes every
webhook that arrives through the C listener. String bodies queue a prompt
through the same door a human or a webhook uses — a timer callback is not a
place to spend minutes. String-bodied triggers persist in the store and are
restored on start; function bodies are honestly dropped rather than half-saved.

### 3.6 Studio discoverability

"Some features are too hard to find" turned out to be measurable: **248
commands, 76 in a menu.** Recipes, voice, agent-authored panels, the library's
verbs, project search and the swarm controls were reachable only if you already
knew the keystroke — and three menu rows pointed at commands that did not exist,
which draw fine and do nothing.

Now **101 menu rows and every one of the 81 product-surface commands reachable**,
including a new **Service** menu for the control plane (start / stop / status /
copy URL). `ninja ui-discover` keeps it that way: it fails on a dead menu row,
and on any `agent:`/`studio:`/`shell:`/`service:`/`automations:`/`library:`/
`swarm:` command with no menu home unless it is listed as internal *with a
reason* (in-widget editing keys; clipboard verbs already in Edit).

### 3.7 Structured returns, budgets and per-agent profiles — Lua

Three things that turn fan-out from a demo into something a coordinator can
actually drive, all on `spawn`:

```lua
spawn{
  task   = "review the auth change",
  schema = { type = "object", required = { "verdict", "findings" } },
  budget = 40000,                                  -- output tokens
  perms  = { bash = { ["*"] = "deny" } },          -- a read-only reviewer
}
```

- **`schema`** — the child must end its reply with a matching JSON object. The
  check is part of the **exit contract**, not a parse-and-hope: a prose-only
  answer fails and the existing bounded retry feeds the failure back and asks
  again. The parsed object rides the bus to the parent as `result`, so a
  coordinator branches on a value instead of re-reading English. Extraction is
  last-object-wins with a real brace scanner that respects string literals and
  escapes — models narrate before they answer, and a `}` inside a command string
  must not end the object.
- **`budget`** — output tokens for that child. `api.lua` already enforced
  `token_budget` and reported `stop = "token_budget"`; the only thing missing
  was a way for the coordinator to *set* it per child. A runaway worker can no
  longer spend the whole run.
- **`perms`** — a permission profile for one child. The skill allowlist answers
  *may this agent use this tool*; a profile answers *may it make this call*. It
  can only **narrow** what the run already permits (`perm.decide` takes the
  stricter of the two), so a spawn can never hand a child more authority than
  the coordinator has. That direction is the whole point.

### 3.8 Per-agent and per-call models — C credential routing + Lua routes

`model` was per-session, but the endpoint, the wire and the key were **global**,
so "use a different model" only worked if the other model happened to live on
the same server behind the same protocol. A fleet could not put a cheap local
critic next to a strong cloud coder — the obvious thing to want the moment there
is more than one agent.

A **route** is the whole destination — `{ model, url, wire }` — resolved per
request rather than read from global state:

```lua
spawn{ task = "review this diff", model = "ds4" }        -- a whole provider, in one word
spawn{ task = "rename the symbol", model = "cheap" }     -- somewhere else entirely
route.resolve("ds4/deepseek-v4-pro")                     -- that endpoint, a specific model
```

A spec may be `nil` (unchanged behaviour), a bare model id (same endpoint), the
name of an endpoint **preset** — which already bundled exactly this trio — or
`preset/model-id`. An unknown name is treated as a model id rather than an
error, because failing a turn over a typo is worse than letting the endpoint say
it does not know that model.

**The C part, and why it had to be C.** `boggart_auth_header()` derived the
credential from the *globally configured* base URL. That is fine with one
endpoint and wrong with two: a fleet spanning a local port and a cloud host
would have sent one provider's key to the other's server. `lauth.c` already
warned about exactly this — *"a stored provider can disagree with the URL the
request is actually going to, and that disagreement is invisible at exactly the
moment it matters"* — so `boggart_auth_header_for(url, wire)` is the correctness
fix and the feature at once. It stays in C for rule 2: **the key must never be
readable from Lua**, so Lua names a destination and C picks the credential
registered for it. The store was already keyed per provider; nothing new is
stored.

Two things fall out for free. **Compaction gets the cheap seat**: summarising a
transcript is bookkeeping, not judgement, so if a `cheap` (or `fast`) preset
exists the summary goes there while the conversation stays put — the one place
per-call routing pays for itself on every long session. And `GET /models` on the
control plane reports the current destination, the utility route and every named
one, so a client can see where each agent is pointed.

Precedence, once, because it is the whole contract: **what this call asked for**
(`opts.model` / `opts.route`) → **what this agent was given** (`sess.route` /
`sess.model`, from `spawn{model=}` or the agent's own spec) → **the configured
endpoint**. With nothing specified anywhere, every request goes exactly where it
went before.

### 3.9 The model catalog — DB-backed, C-enforced, JSON-portable

Adding Grok used to mean knowing that xAI is at `https://api.x.ai/v1`, speaks
the OpenAI wire and wants a Bearer token, and typing all four into a preset.
Adding GLM also meant knowing Z.ai's Anthropic-compatible endpoint takes a
**Bearer** token rather than `x-api-key` — a combination nothing in the code
could express, because the header shape was derived from the wire.

**The store is the truth.** Three tables (`providers`, `models`, `roles`) with
their schema beside every other table in `lua/store.lua`, and their operations
in C (`src/lrepo.c`) on the existing vtable seam. Rows rather than a blob
because "which models do vision above 500k context" is then a query, the agent
can already read and edit them through the `sql`/`kv` tools it has, and
telemetry can join against them. **JSON is the exchange format**, not the store:
`boggart models import|export|refresh`, with the baked `lua/models.json` seeded
on first open — so the seed, the export and an import are one format.

**One key can only go where it was registered.** The catalog's `key_slot` is
not just configuration: `boggart_auth_header_for(url, wire, slot, style)` reads
the `providers` table and **refuses** a (host, slot) pair nothing registers,
returning no credential rather than the wrong one. Lua may route anywhere; it
cannot take a key along. Stated honestly, this stops a routing mistake and a
single confused request, and makes the mapping auditable — it is not a wall
against an agent that first INSERTs a provider row, which is what tool
permissions are for. `auth.slot_allowed(url, slot)` exposes the predicate (never
the key) so the property is testable, and `tests/catalog.lua` asserts it.

Two defects fell out of building it, both pre-existing and both now fixed:
`provider_of()` derives a credential slot from the host's second-to-last label,
giving `api.x.ai → "x"` and `api.z.ai → "z"`; and **`auth.has_key()` ignored its
argument**, always answering for the current provider — so "is the xai key set?"
was really "is the anthropic key set?".

**Roles are the UX.** An agent declares intent (`role = "critic"` in
`lua/agents/critic.lua`); a user binds roles to models
(`boggart models role critic grok-4.6,glm-5.3`). The same agent definition then
works for someone with five providers and someone on one local model, which is
what makes a shared spec worth having. A binding may be an ordered fallback
chain. Precedence, most specific first: **this call** (`spawn{model=}`,
`opts.model`) → **this agent** (spec's explicit model) → **its role** → **the
default**. An explicit model id works at every level, so roles are sugar, never
a cage.

**One behaviour change worth knowing:** naming a *catalogued* model now
redirects to that model's provider. `/model grok-4.6` goes to xAI — that is the
feature — which means `/model claude-opus-5` while pointed at a local
Anthropic-shaped server now goes to Anthropic rather than staying local. The
escape hatch is a preset, which outranks the catalog by design, and
`tests/route.lua` pins both halves.

---

## 4. Gates

Everything above is guarded, because a control surface that regresses silently
is worse than one that was never built.

| Gate | What it holds |
|---|---|
| `ctest` (51 suites) | `perm` (72 assertions), `control` (29, real HTTP round trips), `triggers` (36), `structured` (27) among them |
| `ninja core-parity` | the CLI and the studio expose one core — `serve` is registered in both |
| `ninja ui-discover` | every feature reachable from a menu; no dead rows |
| `ninja ui-overlay` | overlays survive partial-damage frames |
| `ninja ui-check` / `ui-bench` | the studio renders and stays fast |

---

## 5. Still missing, with the line drawn in advance

| Gap | Where it would land | Why |
|---|---|---|
| **Subprocess jail** (Landlock / seccomp / Seatbelt) | **C** | rule 1 and 2: syscall filters, and an unjailed shell-out is the one hole left in the capability boundary. The single most important remaining item |
| **ACP endpoint** (JSON-RPC over stdio) | **Lua**, on C stdio | the protocol is data; 25+ agents and JetBrains/Zed/Neovim for one endpoint |
| **MCP serve** (expose boggart's tools) | **C** transport (`lmcp.c` has it) + **Lua** surface | the registry is Lua; the framing is not |
| **Durable waitpoints + idempotency keys** | **Lua** on the C journal | the journal is already the one lawful channel to interpose on |
| **Network policy per session** | **C** | rule 2: a policy the agent can edit is not a policy |
| Multi-hunk patch, web search/fetch, session export, cheap-model compaction | **Lua** | ordinary tools; see [`feature-gaps.md`](./feature-gaps.md) |

The pattern in that table is the point. Almost everything left is Lua, and the
short C list is short for a reason: it is the syscalls and the refusals.
