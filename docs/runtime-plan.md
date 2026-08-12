# boggart as an agentic runtime — the plan

The goal is not "a better coding agent." It is a **domain-neutral agent kernel**
that runs coding and business-process work from one core, is driven by external
events, and coordinates many agents without them clashing. "If you wanted to
build OpenClaw, you would build it *on* this and wire up the connectors."

This document is the map. It names what is C and what is Lua, maps every new
piece onto a primitive boggart already has, and sequences the build so each step
is useful on its own.

## The stack

Bottom to top. Each layer already has a foundation in the binary; the work is
the middle three.

| layer | status | where |
|---|---|---|
| libuv loop + real worker threads | **done** | `src/lworker.c` — N threads, N loops, N interpreters |
| **Blackboard** — shared coordination state | to build | C |
| **HTN** — decompose a goal into a task network | to build | Lua over a C store |
| **Event gateway** — outside world triggers a plan | to build | C transport, Lua policy |
| skills / tool-packs — the domain opinion | exists | `lua/skills/*` |
| approval grades + subprocess jail — safety | partial | studio gate + one C hole |

The insight from the audit (`comparisons.md` §4) is that boggart's primitives are
not coding primitives, they are **process** primitives — the same turn loop, the
same self-extension, the same journal serve a git repo and a company inbox. What
changes is the tool-pack and what counts as the record of truth. These three
layers are what turn "an agent that runs to quiescence and exits" into "a runtime
that stays up, is woken by the world, and coordinates a fleet."

---

## 1. The Blackboard (C) — the keystone

A game-AI blackboard is shared, structured memory that many agents read and write
to coordinate. Its job here is precise: **stop two agents doing the same work, or
conflicting work, at the same time** — the merge-conflict problem, solved before
the conflict rather than after.

It is a C feature, and this is not incidental. It is genuinely shared *mutable*
state across the worker threads we just built — the one case boggart's
"single-thread-ownership, no mutex" argument does **not** cover, because a
blackboard is shared-write by definition. It needs a real reader/writer lock, and
the honest thing is to say so rather than pretend the SPSC-ring idiom stretches
this far. It lives in C because it is the substrate every worker and the main
loop share, it must be fast, and its correctness is the whole point.

Three kinds of entry:

- **Facts** — `key -> value`, versioned. "build is green", "src/api.lua is 439
  lines", "invoice #4021 seen". Any agent reads or writes. This is a shared,
  watchable world-state — memory's fast, ephemeral sibling (memory is durable and
  FTS-searchable; the blackboard is live and coordination-shaped).
- **Claims / leases** — `resource -> {owner, mode, ttl, intent}`. "worker 3 holds
  an *exclusive* claim on `src/api.lua`, intent 'add retry', expiring in 60s."
  Claiming an exclusively-held resource **fails** and returns who holds it, so the
  agent picks other work instead of colliding. Shared (read) claims coexist;
  exclusive (write) claims do not. Leases expire, so a crashed agent does not
  freeze a resource forever. **This is the clash reducer.**
- **Work items** — the open tasks of an HTN plan (below): `status`
  (open/claimed/done/failed), `depends_on`. An idle worker claims an open item
  whose dependencies are satisfied and executes it. Parallelism falls out for
  free: unordered subtasks are just work items, and workers race to claim them.

Lua surface (`bb.*`), all thread-safe:

    bb.post(key, value)            bb.get(key)         bb.watch(pattern)
    bb.claim(res, mode, ttl, intent) -> ok | held_by   bb.release(claim)
    bb.claims()                    -- the coordination view
    bb.take_work() -> item | nil   bb.done(item, result)

**This also answers today's ask directly.** The worker roster (`worker.list()`,
just landed) says *how many* and their last line. The blackboard says *what each
is working on and on which resource* — the claims table **is** the "who is
touching what" visualization, and the studio's worker view should draw it.

---

## 2. HTN — hierarchical task networks (Lua over a C store)

Workflows today are linear: prompt, prompt, prompt. HTN is the structured
version, and it is what makes this "the best workflow tool" rather than a
step-runner.

A **task** is primitive (a tool call or a prompt) or **compound** (decomposes,
via a *method*, into subtasks — ordered or unordered, each with preconditions).
The **planner** takes a goal task plus the blackboard's facts and produces a plan:
a tree whose leaves are primitive tasks. The **executor** walks it — ordered
subtasks in sequence, **unordered subtasks posted to the blackboard as work items
that idle workers claim in parallel.**

That is the synthesis the whole design turns on:

> HTN produces the task graph. The blackboard holds it and coordinates who does
> what. Workers execute in parallel. Claims prevent clashes.

Mapped to what exists: a linear workflow is the degenerate HTN (one method, all
primitive, all ordered), so `workflowview` and `recipes` are the front of this,
not a separate thing. The journal is already a saga log (`processed_at` stamps);
HTN gives it the plan structure above the log. Skills are the method libraries —
a skill is "here is how to decompose *review a PR*," and a domain pack is a set of
methods plus their tools.

Kept in Lua because a plan is data the agent should be able to write, inspect and
rewrite — the same argument as tools and recipes — over a C-side work-item store
(the blackboard) that Lua cannot corrupt.

---

## 3. The Event Gateway (C transport, Lua policy) — the world drives it

Coding runs to quiescence and exits. A business process must **stay up and be
woken**: a webhook, a cron tick, a mailbox poll, a queue message. `events.lua`
already does *internal* autocommands (turn started, tool ran); the gap the audit
names is an **inbound transport and a supervisor**. libuv is already the loop, so
this is a transport and a lifecycle, not a new foundation.

- **Inbound transports** (C, on the existing loop): an HTTP listener for
  webhooks, a timer wheel for cron, and a generic "external message" ingress that
  MCP-style connectors and the eventual OpenClaw channels feed.
- **The rule** (Lua): "when an event matching X arrives, start plan Y / wake
  session Z." This is `events.on` pointed outward — the same inversion of control,
  applied to the world instead of the turn loop.
- **The supervisor** (C): keep the process alive, own the transports' lifetimes,
  restart a plan that a trigger asks for. This is the always-on daemon the
  OpenClaw study flagged; BPM is the reason to build it.

Once this exists, "take any event-driven thing from the outside world and trigger
onward from it" is literally the description of the runtime.

---

## The safety through-line (must land alongside, not after)

Inbound events change the threat model: coding assumes a **trusted operator**, but
a webhook or an email is **attacker-controlled input**, so prompt injection gains
real blast radius — money, records, outbound messages. Three defenses compose,
two of which mostly exist:

1. **The C capability boundary** (already the design): generated Lua reaches the
   world only through C capabilities with policy attached. No ambient authority.
2. **The subprocess jail** (the one real hole): Seatbelt on macOS, Landlock +
   seccomp on Linux, wrapping `proc.run` and MCP-stdio — the *only* tier that
   leaves the boundary into native land. Small and sharp, not a general jail.
3. **The approval gate, generalized**: the studio gates file writes today;
   generalize it to any capability tagged **approval-required**, and add capability
   **grades** — `read-only`, `requires-approval` — so a BPM agent gets
   `mcp__mail__*` for reading but `send` only behind a human.

The library panel's provenance (which tool, what scope, which git rev, call/fail
counts) stops being a nice touch and becomes an **audit surface**: a record of
what an autonomous process was permitted to do and did.

---

## Sequence

Each step ships something usable on its own; nothing waits on the whole vision.

1. **Blackboard (C)** — facts + claims first. *Immediately* powers the worker
   visualization the owner asked for (claims = "who is on what"), and is the
   thing every later layer stands on. Start here.
2. **Claims wired into the existing tools** — `write`/`edit`/`bash` take an
   exclusive claim on the path they touch; two agents editing one file is now a
   refusal with a reason, not a merge conflict. Coordination with zero new UI.
3. **HTN executor over the blackboard** — work items, dependency-gated claiming,
   unordered-subtasks-as-parallel-work. Workflows become the linear special case.
4. **Capability grades + generalized approval** — needed before any untrusted
   input, so it lands with (or before) the gateway.
5. **Event gateway** — cron and webhook transports, `events.on` outward, the
   supervisor. This is the "stays up, woken by the world" turn.
6. **Subprocess jail** — the residual security hole; can land in parallel with 4–5.

Deliberately later, external, and not on this critical path: **LLM Station** as an
MCP tool server — cyclomatic complexity, step-through debuggers, deep code
intelligence — plugs in as `mcp__llmstation__*` once the gateway and grades exist,
and needs nothing from the kernel it does not already have.

## What this is not

Not two products. One kernel plus two tool-packs — a coding pack and a BPM pack
over the same loop, journal, and blackboard. The failure mode is a single
front-end diluted trying to serve a coder and an analyst at once; the success
mode is the same core wearing different skills. Ship the kernel; let skills carry
the opinion.
