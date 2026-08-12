# Planning in the C core — a rebuilt HTN + GOAP planner

A plan for a **from-scratch** planner in the C core: not a vendored library but
our own small, arena-backed, assertion-heavy planner that unifies **HTN**
(hierarchical task networks — structure and domain knowledge) and **GOAP**
(goal-oriented action planning — emergent goal-solving) over one world-state, and
exposes them to Lua as a first-class capability so boggart can plan a sequence of
actions and dispatch it across tools, skills, and sub-agents.

This follows the engine's doctrine — **capabilities live in C where the policy
lives with them; Lua composes** (`comparisons.md` §3), and **promote stable
mechanics, keep judgment in the agent** (§6). Search and decomposition are cheap,
deterministic, sub-millisecond mechanism; they belong below the Lua line. The LLM
supplies the goal and judges whether an action really succeeded — it does not do
the ordering.

## Why rebuild instead of vendor [stolk/GPGOAP](https://github.com/stolk/GPGOAP)

GPGOAP is a fine ~600-line reference, and reading it is the right starting point,
but its constraints are exactly the things we would have to work around forever:

| GPGOAP | Rebuilt planner |
|---|---|
| 64 atoms hard cap (single `u64`) | bitset of `PLAN_MAX_ATOMS` words — a raised, explicit compile-time bound |
| **Non-reentrant** — file-static `open[1024]`/`closed[1024]` | **reentrant** — all scratch from a per-run **arena**; safe for a future threaded path |
| Stores caller's `const char*` (dangles under Lua GC) | **owns** every name (arena-copied at intern) |
| Boolean atoms only | boolean now, but the world-state type is ours to extend |
| GOAP only | **HTN + GOAP unified** over one world-state |
| Sparse assertions | **TigerStyle**: assert invariants everywhere; bounded everything |

We still credit GPGOAP as studied prior art (Apache-2.0, © Abraham T. Stolk) the
way boggart already credits ds4 and rough.js — *the algorithms are standard GOAP
and HTN, the code is ours* — but we vendor nothing, so there is no third-party
license to carry and no non-reentrant scratch to inherit.

---

## 1. The unified model — one world-state, two planners, one output

Everything reduces to **primitive tasks**, which are the only things that ever
execute. HTN and GOAP are two ways of *producing an ordered list of them*.

- **World-state** — `{ u64 values[WORDS]; u64 care[WORDS]; }` (a value bitset and
  a don't-care mask), `WORDS = PLAN_MAX_ATOMS/64`. POD, arena- or stack-lived.
- **Atom** — a named boolean predicate, interned to an id, its name arena-owned.
- **Primitive task** (a GOAP action) — `pre` (world-state to satisfy), `effect`
  (world-state delta), `cost` (u32), and an **opaque dispatch handle** (a u32 the
  Lua layer resolves to a tool / skill / sub-agent). The C core never learns what
  a "tool" is — same boundary as the rest of the engine.
- **Compound task** (the HTN piece) — a named task with ordered **methods**; each
  method has a `guard` (world-state precondition) and an ordered list of subtasks
  (primitive or compound). First method whose guard holds is taken, with bounded
  backtracking to later methods on failure (SHOP-style, total-order).

How the two compose, rather than sit side by side:

- **HTN is the outer structure.** Decomposing a compound task expands domain
  knowledge you authored — the sensible procedure — into subtasks.
- **GOAP solves declarative leaves.** A subtask can be *"achieve this
  world-state"* rather than a named action; that leaf runs A* over primitive
  tasks to synthesise the sub-sequence. So GOAP is, formally, one kind of method
  for an achieve-state task.
- **Both emit primitive tasks** — i.e. the §6 dispatch nodes. A plan is a flat,
  ordered list of `(primitive task, dispatch handle)`; the caller neither knows
  nor cares whether a given run of steps came from decomposition or from search.

This is the "do better": HTN gives control and legible procedure; GOAP gives
robustness and emergent recovery; boggart gets one planner that does both and one
execution model (§5/§6) underneath.

---

## 2. TigerStyle — the constraints that make it trustworthy

The planner is model-adjacent (agents and generated actions feed it), so it is
built to TigerBeetle's rules, which happen to be exactly what a planner wants:

- **Bounded everything, named as constants.** Every limit is a `#define`, and
  every loop and buffer is checked against one. No unbounded search, no unbounded
  recursion, no dynamic growth in the steady state.

  ```
  PLAN_MAX_ATOMS         256     // bitset = 4 x u64
  PLAN_MAX_TASKS         512     // primitive + compound, per planner
  PLAN_MAX_METHODS       512
  PLAN_MAX_METHOD_STEPS   32
  PLAN_MAX_PLAN          128     // primitive steps in a produced plan
  PLAN_MAX_DECOMP_DEPTH   64     // HTN decomposition depth (explicit stack)
  PLAN_MAX_DECISIONS     256     // HTN backtrack stack
  PLAN_MAX_OPEN         4096     // GOAP A* frontier nodes
  PLAN_MAX_WORK       100000     // total node expansions before we give up
  ```

- **No recursion.** HTN decomposition is naturally recursive; we run it as an
  explicit **frame stack** in the arena, depth asserted `<= PLAN_MAX_DECOMP_DEPTH`.
  Every iteration asserts progress against `PLAN_MAX_WORK` so the loop provably
  terminates.
- **Assertions vs. errors — the load-bearing distinction.** *Assertions* catch
  **our** bugs (id in range, arena not overflowed, bitset word index valid,
  invariants between g/h/f) and abort in debug builds; there are at least two per
  function on average, covering positive and negative space. *Errors* are expected
  runtime outcomes — **plan not found**, **work budget exhausted**, **frontier
  full**, **undeclared atom**, **task budget exhausted** — and return typed values
  that become boggart's `Tool error: [kind]` taxonomy. A bad plan request is an
  error; a corrupted planner is an assertion. Never the two confused.
- **Deterministic.** A* ties broken by (lower f, then lower g, then lower task
  id); methods tried in declared order. Identical inputs yield an identical plan —
  which the test suite asserts and which the replay/journal model (§5/§6) needs.
- **Simple, sized code.** Functions kept short (≈70 lines), one job each;
  fixed-width integer types (`uint16_t` ids, `uint32_t` cost); zero-initialised
  arena allocations; no signed/unsigned mixing.

---

## 3. Arenas — one region per plan run

All transient planning memory comes from an **arena** (a bump allocator over a
fixed buffer), never `malloc` in the hot path:

- A planner owns one arena buffer, sized deterministically from the limits above
  at `planner.new()` and asserted large enough — so **arena overflow is a
  programmer error (assertion), not a runtime error**. The runtime failures are
  "search too big" (frontier/work budget), which are typed errors.
- `arena_alloc(a, n, align)` asserts `used + padded <= cap`, returns zeroed
  memory, and never frees an individual object. `arena_reset(a)` reclaims the
  whole region in O(1) at the end of a plan run.
- Because every run's open set, closed set, decomposition frames, backtrack
  decisions, and output plan live in *its* arena, `planner_run` is **reentrant** —
  the concrete win over GPGOAP's file-static scratch. Cooperative scheduling
  already serialises runs, so one arena per planner suffices today; a threaded
  path later just needs one arena per thread, with no code change.

The arena is part of the planner userdata's storage, so its lifetime is the
planner's and `__gc` reclaims it with everything else.

---

## 4. C layer — `src/lplanner.c`, exposing the `planner` global

A new C module in the exact shape of `sys`/`db`/`swarm`/`mcp`, and following the
**userdata + metatable** convention that `src/ldb.c` and `src/lmcp.c` already
use: `lua_newuserdatauv` for the planner (its tasks, interned+owned atom/action
names, and its arena), `luaL_newmetatable(API_TYPE_PLANNER)` with `__index = mt`,
methods resolved through it, and `__gc` that frees the owned strings and arena.

Proposed surface (Lua passes names; C interns, owns, validates, and asserts):

```
planner.new(opts)                 -> p        -- opts.atoms budget asserted <= PLAN_MAX_ATOMS
p:atoms{ "tests_pass", ... }                  -- declare the vocabulary; names arena-copied
p:action(name, {pre=, eff=, cost=, dispatch=})-- a primitive task (GOAP action / HTN leaf)
p:task(name, { {guard=, steps={...}}, ... })  -- a compound task: ordered methods
p:plan(world, goal)                           -- goal = {task="deploy"} | {state={tests_pass=true}}
                                              --  -> { steps={{action=,dispatch=},...}, cost=, kind= } | nil, reason
p:describe()                                  -- text for doctor / the library panel
planner.LIMITS                                -- the constants above, for the fingerprint & tests
```

Two safety disciplines carried over from the digging into GPGOAP, enforced in C:

- **Owned names.** Every atom/action/task name is `arena`-copied on intern; the
  planner never retains a Lua string pointer (GPGOAP's use-after-free, designed
  out).
- **Declared vocabulary.** Atoms must be declared via `p:atoms{}` first; a
  precondition/effect/goal that names an undeclared atom is a typed error, not a
  silently-interned new atom (GPGOAP's typo footgun, designed out). This is
  `strict.lua`'s philosophy — a misspelled name is loud — and it matters because
  the model writes these names.

The planner is pure and side-effect-free (it computes a plan; executing it is
someone else's job), so it is safe to expose to generated tool/step bodies as a
read-only capability alongside `db`.

---

## 5. Lua layer — `lua/plan.lua`, the registry and the loop

The C module plans; Lua drives. `lua/plan.lua` (overlay-mutable) owns:

- **The task/action registry.** Actions and compound tasks declared next to the
  capabilities they invoke — a primitive binds `{pre, eff, cost}` to a dispatch
  `{kind="tool"|"skill"|"agent", ...}`; a compound binds ordered methods.
- **World-state derivation** — "atom providers": functions that read current
  truth from `kv`/`sql`/`memory` or cheap probes, plus a `tool:after` hook so an
  action's real result updates atoms and feeds replanning.
- **The plan→act→observe→replan loop.** Build the world-state → `p:plan(world,
  goal)` → dispatch each primitive to its target and await → apply observed
  effects → if reality diverged from the declared effect, replan from the observed
  state.

Model-facing tools mirror the self-extension pair, now spanning both paradigms:

- **`plan`** — compute and return a plan for a goal *without executing*, so the
  agent (or a human, in the studio) can inspect or approve it first.
- **`define_action`** — a primitive task (dispatch + pre/eff/cost).
- **`define_task`** — a compound HTN task (ordered methods) — encode a procedure
  the agent has learned.

All persist to `<data dir>/lua/` in the same data-only file format as generated
tools and appear in the library panel with provenance (scope, git revision,
call/fail counts). The planner's action *and* task space grows with the agent —
the self-modification thesis (§3) reaching planning, HTN methods included.

---

## 6. How it coordinates sub-agents and tools

The swarm coordinator gains a planning-driven mode: derive the world-state,
`p:plan(goal)`, then for each primitive step route by dispatch kind onto the
existing bus — a `tool` runs inline, a `skill` reshapes the acting agent's
permitted tool set, an `agent` is `spawn`+`await` over `lswarm.c`. Effects update
the world-state; transitions are journalled; divergence triggers a replan. HTN
decomposition is where a compound task naturally maps onto a **sub-agent
workflow** (a method's ordered steps become a delegated sequence), and GOAP is
where a coordinator turns a fuzzy "get to this state" into a concrete order. Both
feed the §6 dispatch model, so each step is a node boggart already knows how to
run and journal.

---

## 7. Build, parity, credits (the wiring that must not drift)

boggart is one engine behind two front ends, so each of these has a matching
pair, and `ninja core-parity` fails the build if only one side gets it:

- **CMake**: add `src/lplanner.c` and our `src/planner.c` (+ `planner.h`) to
  *both* the CLI source `set(...)` and the studio source list; no vendored lib and
  no third-party license, since the implementation is ours.
- **Registration**: add `luaopen_boggart_planner` + its `luaL_requiref(...;
  "planner"); lua_setglobal(L, "planner")` to *both* `src/boggart.c` and
  `src/bogembed.c`.
- **Fingerprint**: the `plan`/`define_action`/`define_task` tools are Lua (baked
  identically into both binaries) so the existing `tools` line covers them for
  free. The `planner` C global is *not* otherwise fingerprinted, so register it in
  `sys.caps()` (already dumped) or add `put("planner_limits", …)` from
  `planner.LIMITS` — so a missing C registration, or a limits drift, fails
  `core-parity` loudly.
- **Credits**: a README line crediting GPGOAP as studied prior art (Apache-2.0, ©
  Stolk) and naming SHOP/HTN as the decomposition model — code ours, ideas
  standard.

---

## 8. Tests

- **`tests/planner.lua`** (a ctest suite against a throwaway HOME):
  - **GOAP**: a textbook state goal returns the known optimal action sequence;
  - **HTN**: a compound task decomposes to the expected primitive order; method
    backtracking picks the second method when the first guard fails;
  - **Mixed**: a compound task with an achieve-state leaf splices a GOAP
    sub-sequence in the right place;
  - **Determinism**: identical inputs → byte-identical plan;
  - **Typed errors** (not crashes): undeclared atom, atom/task budget exhausted,
    work budget exhausted, frontier full;
  - **Ownership**: names survive a forced Lua GC between definition and planning
    (the GPGOAP trap, asserted absent);
  - `define_action`/`define_task` persist and reload through the data-only format.
- A TigerStyle note: debug builds run with assertions on, and the suite is
  expected to exercise the negative space (bad ids, over-budget) so the assertions
  themselves are covered.
- A **headless swarm test**: a compound goal that decomposes across two
  sub-agents; assert the plan, the dispatch order, and the journalled transitions.

---

## 9. Prompt and studio surfaces

- **`lua/prompt.lua`**: teach the coordinator *when to plan* — a goal with several
  discrete, precondition-ordered steps and clear success atoms (GOAP), or a known
  multi-step procedure worth encoding once (HTN) — versus when to just act. The
  planner orders known capabilities; it does not reason open-endedly.
- **Studio**: a `draw_panel` visualising the plan — the HTN decomposition tree and
  the GOAP search path, chosen route highlighted — the agent drawing its own plan.
  Optional, Phase 4.

---

## 10. Phasing

1. **Planner core.** `src/planner.c` + `planner.h`: world-state, arena, atom
   interning (owned), GOAP A*, HTN total-order decomposition with bounded
   backtracking, all limits and assertions. Pure C, unit-tested through a tiny
   harness before any Lua.
2. **The `planner` global.** `src/lplanner.c` + userdata/metatable, CMake and
   registration parity, `tests/planner.lua`. `p:plan` returns correct GOAP, HTN,
   and mixed plans.
3. **Registry & tools.** `lua/plan.lua` registry, atom providers, `plan` /
   `define_action` / `define_task`. Planning over real boggart capabilities.
4. **Orchestration & surfaces.** plan→act→observe→replan in the swarm; dispatch
   across tools/skills/sub-agents; journalled transitions; library-panel
   provenance; the studio plan panel; final prompt guidance.

---

## 11. Decisions to confirm

1. **Atom bound.** `PLAN_MAX_ATOMS = 256` (4 words) as the raised cap, with
   per-domain planners keeping real vocabularies well under it. Bigger is cheap
   (bitset words) but widens the world-state struct copied per A* node — 256 is a
   good default. Confirm.
2. **HTN ordering.** Total-order (SHOP-style, ordered subtasks) first — simpler,
   deterministic, TigerStyle-friendly; partial-order decomposition deferred.
   Confirm that is enough for the orchestration cases you have in mind.
3. **Action granularity & who may plan.** Primitives dispatch to tool / skill /
   sub-agent uniformly; the coordinator plans by default, plus any agent whose
   skill grants `plan`. Confirm scope.
4. **Boolean world-state.** Discrete/boolean atoms only for now (numeric/resource
   preconditions kept in the agent or a later planner). Confirm.
