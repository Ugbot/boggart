# The compounding runtime: what we are actually building

Status: thesis (2026-09-11). The frame the callable, memory, and team work
all serve.

## The one sentence

An agent runtime whose cost per task falls and whose ability rises with use,
because it compiles its own experience into deterministic code it prefers over
model calls, verifies that code against the model, falls back to the model when
the code does not fit, and shares the compiled capability across a team.

## The bet

Every other agent framework keeps the model as the executor. Each run of the
same task costs the same: the model reasons through it again, at the same
latency, the same tokens, the same nondeterminism, forever. LangChain graphs do
not learn; aider re-derives each session; a prompt is a prompt.

boggart's bet is different: **the model's role shifts from executor to compiler
and judge.** The first time a task-shape appears, the model does the work. The
deterministic parts of that work — pin a ref, gather files, check a result,
decide a loop is done — are a program the model was hand-interpreting. Once
written as Lua, they are free next time. The model is left only the novel
judgment, and the judgment surface per task-shape shrinks with exposure.

Stated as economics: today an agent task is O(model calls). The aim is that a
repeated task-shape becomes O(1) code plus O(model) on only the novel delta.
The model becomes the thing that writes and checks the code, and the safety net
when the code does not fit — not the thing that runs every step.

## Why this is possible here and not elsewhere

Three properties, all already true, make the compilation a first-class move
rather than a research aspiration:

- **One substrate.** Capability is Lua the agent reads, writes, and reloads.
  There is no plugin format to author against, no second language. The model
  can write the code that replaces its own future calls, mid-task
  (`define_tool`, `define_skill`, a skill's `before`/`finally`).
- **A calculus to compile into.** The Callable model (docs/callables.md) gives
  the model an eval primitive and a set of special forms — `chain`, `cond`,
  `loop` with a code stop-evaluation, `verify`, `retry`, `first`. Control flow,
  branching, iteration, and checking are things code can express, so more of a
  procedure than "call the model again" has a home.
- **Measurement.** The tools table already records calls, failures, and
  cumulative time per capability. Whether a compiled slice paid for itself is an
  answerable question, not a belief.

## The three loops that must all turn

The flywheel is not one loop. It is three, and it compounds only when all three
turn.

1. **Compile (per instance).** A task runs; its deterministic slices are
   identified; they are written as code — a `before` that short-circuits, a
   tool, a verifier — and preferred over the model next time. Measured, so the
   payoff is visible.
2. **Know (per instance).** Experience becomes memory; recall surfaces it so the
   model does not re-derive what it already learned; the unused decays so the
   base stays sharp (the tiered-retention model, docs/team.md M4).
3. **Share (per team).** One instance's compiled capability travels as a signed
   skill-pack (the moot protocol, docs/team.md); the team's code base grows from
   any member's learning, so the compounding is across people and machines, not
   one process.

## Two axes: deepen and widen

"Increasing the ability base" is two motions, not one, and the compounding
runtime needs both.

- **Deepen** (cheaper at known work): compile the deterministic slices of a
  task-shape you already have skills for into code. The model-calls-per-task
  curve falls. This is everything above.
- **Widen** (capable at new work): when a genuinely new *domain* appears — a
  field the runtime has no skills for: a new codebase's conventions, hardware
  bring-up, legal review, a game's rules — model it. Produce the domain's
  vocabulary, its actions, its ways of working, and what "correct" means, so
  the compile and know loops have something to turn on in new territory.

Without widen, the runtime only ever compounds on shapes it was born knowing.
With it, the ability base grows into fields it has never seen, and then deepens
there. Deepen makes known work free; widen makes new work possible; both feed
the same three loops.

## Modeling a new domain

A **domain is the unit above a skill.** A skill is a way of working; a domain is
a whole field of work — its language, its actions, its procedures, its
standards. The project is already the unit of context (`lua/project.lua`): it
scopes memory, skills, tools, and search. So a domain lives in a project, and
modeling one means giving that project an *executable* model, not a document:

- **Vocabulary** — the domain's entities and relations, the ubiquitous language
  (DDD). Named once, in project memory, so every skill and prompt in the domain
  refers to the same things by the same names and cannot drift. (The existing
  `domain-modeling` skill produces this today as prose; the widen move is to
  make it also produce the executable parts below.)
- **Actions** — the domain's verbs, as tools (Callables). `rollout_status` and
  `scale` for a kubernetes domain; `save_chapter` and `check_canon` for a novel.
  Drafted by the model via `define_tool`, scoped to the project.
- **Skills** — the domain's ways of working, as project-keyed skills over those
  actions, drafted via `define_skill`.
- **Verifiers** — what correct means in the domain, as code (docs/callables.md):
  a kubernetes deploy is verified by a healthy rollout, a chapter by its canon
  check. So domain work is checked in the domain's own terms, not the model's
  opinion.

Modeling a domain is therefore itself a compile: a bootstrap pass (the
`domain-modeling` skill, elevated to emit executable capability) that turns a
description plus some sources into vocabulary + actions + skills + verifiers,
registered scoped to the project. The output is a **domain-pack** — the same
shape as a skill-pack, one level up — and it travels across a team by the moot
protocol (docs/team.md), so a domain one person models is a field the whole team
can then work and compound in.

Once a domain is modeled, the three loops turn inside it: its skills compile
their slices to code (deepen), its memory accrues and decays (know), its
domain-pack is shared (share). Widen bootstraps a field; deepen and the loops
compound it.

## The load-bearing rule: prefer, never replace

The failure mode that kills this vision is over-compilation. Code is
deterministic but brittle; the model is flexible. A slice compiled too eagerly
breaks on the case the model would have absorbed. So the compiled path is never
a replacement — it is a preference with the model as fallback:

    first(compiled_code, eval)

Try the code; if it does not fit — returns nothing, fails its verifier, errors —
fall through to the model. This is `register_fallback` and `first` already, and
it is the shape every conversion should take. "More code, fewer model calls" is
safe precisely because the model is always still there underneath. The goal is
to lower the *rate* the model is reached, not to remove it.

## What is built, and the gaps that keep the flywheel from turning on its own

Built: the substrate (callables, combinators, verifiers, fallback), the
authoring (self-written tools/skills, the `before`/`finally` lifecycle), the
gradient (a skill migrates prose to code slice by slice), the measurement data
(the tools table), and the designs for memory retention and team sharing.

Missing — and these are what make it a passive possibility rather than a
self-driving flywheel:

- **The compile trigger.** Nothing acts on the measurement. A capability called
  often, with identifiable deterministic slices, should prompt (or auto-draft)
  its own conversion. The data exists; the policy that reads it does not.
- **The equivalence check.** Replacing a model step with code should be verified
  — run both on real inputs, confirm the code matches the model's behaviour,
  then trust the code. Safe compilation is a protocol, not a hope, and it is not
  built.
- **Prefer-with-fallback as the default shape.** Conversions should land as
  `first(code, eval)`, so a compiled slice that does not fit degrades to the
  model instead of failing. Today a `before` short-circuit is hard (done, or the
  model) rather than soft (code, else the model).
- **The unit-invocation wiring** (BCALL-1) so the lifecycle actually runs where a
  skill is a unit — the swarm — and the zero-model-turn win lands.
- **Recall good enough to displace re-derivation.** Memory only cuts calls if the
  model trusts recall over re-checking. Retrieval quality is the gate.

## The metric that proves it is real

Not "fewer model calls" in the abstract — that is easy to fake by degrading
quality. The claim is specific and measurable: **model-calls-per-task-shape
trend down over repeated exposure, while the number of task-shapes handled trends
up.** Cost per repeated task falls; reach grows. If that curve is visible in the
telemetry, the flywheel is turning. If it is not measured, this is a nice
architecture and an unproven promise.

So the next thing worth building is not another feature. It is the
instrumentation that makes the curve observable — a cost ledger per task-shape,
attributing model calls and tokens — and the trigger that reads it and proposes
the next slice to compile, verified against the model. Make the flywheel
measurable, then make it self-driving.

## How the pieces line up under this frame

- **docs/callables.md** — the calculus you compile into. The compile loop's
  substrate.
- **docs/team.md** M4 (memory) — the know loop. M0-M3 (moot) — the share loop.
- **docs/extending.md** — the four routes capability arrives by, all resolving to
  the same Callable, all compilable.
- **docs/projects.md** + `lua/project.lua` — the project as the domain's scope;
  the widen axis lives here (a domain is a project with an executable model).
- **BCALL** — the compile loop's remaining wiring (lifecycle in the swarm,
  verified conversions).
- The gap above — the compile *trigger* and the cost *ledger* — is the piece
  that turns three loops that *can* turn into three loops that *do*.
