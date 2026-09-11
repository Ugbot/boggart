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
- **BCALL** — the compile loop's remaining wiring (lifecycle in the swarm,
  verified conversions).
- The gap above — the compile *trigger* and the cost *ledger* — is the piece
  that turns three loops that *can* turn into three loops that *do*.
