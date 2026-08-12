# Planning at the C layer — GPGOAP in boggart

A plan for adding [GPGOAP](https://github.com/stolk/GPGOAP) (Abraham Stolk's
Generic-Precondition Goal-Oriented Action Planning) to the C core, so boggart
can plan a *sequence of actions* toward a goal and dispatch that plan across
tools and sub-agents — deterministic mechanism below the Lua line, judgment
kept in the agent above it.

This follows the doctrine the rest of the engine already states: **capability
primitives live in C where the policy lives with them; Lua composes them** (see
`comparisons.md` §3), and **promote stable mechanics, keep judgment in yourself**
(§6). A* over a bitfield world state is exactly the kind of cheap, deterministic,
sub-millisecond computation you do *not* want an LLM doing turn after turn.

---

## 1. What GPGOAP is (and why it fits)

A tiny, dependency-free C GOAP planner. The relevant shape:

- **World state** (`worldstate_t`) is two 64-bit fields: a *values* bitfield and
  a *don't-care* mask. So a state is "these atoms are true, these are false, the
  rest don't matter."
- **Atoms** are named boolean predicates, interned to bit indices by the planner.
  Hard cap: **`MAXATOMS 64`**.
- **Actions** (`MAXACTIONS 64`) each carry preconditions (`goap_set_pre`),
  postconditions/effects (`goap_set_pst`), and an integer cost (`goap_set_cost`).
- **Planning** is `astar_plan(ap, start, goal, plan[], worldstates[], &plansize)`
  → returns total cost, fills `plan[]` with action-name strings and
  `worldstates[]` with the intermediate states. A* with a bit-difference
  heuristic.

Properties that matter for embedding:

- **No `malloc`.** The open/closed sets are file-static arrays
  (`MAXOPEN`/`MAXCLOS` = 1024 nodes each, ~80 KB total), overflow returns `-1`.
- **Non-reentrant** — those static sets mean two `astar_plan` calls must not
  interleave. Under boggart's **cooperative single-threaded scheduler** this is a
  non-issue: a plan call is pure synchronous C that never yields, so it always
  runs to completion before another begins. We rely on that explicitly (see §3).
- **Boolean/discrete only.** Costs are static ints; there is no numeric or
  resource planning. This bounds what GOAP is *for* here — ordering discrete
  capabilities by precondition — and we should not force fuzzy goals into atoms
  (see §9).

The whole thing is four files (`goap.h/.c`, `astar.h/.c`) and vendors cleanly.

### Verified against the source (the digging)

- **License: Apache-2.0**, © Abraham T. Stolk, 2012 — the same license boggart
  already carries for luv and ltui, so it composes with the vendored set. Not a
  ship-blocker. Vendoring must still ship the Apache-2.0 text at
  `src/vendor/gpgoap/LICENSE` and preserve the per-file copyright headers (the
  root `LICENSE` 404s on `master`, so take the license from the README's
  statement and the file headers).
- **Names are stored by pointer, not copied — a use-after-free trap.** A new
  atom or action registers as `ap->atm_names[idx] = atomname;` /
  `ap->act_names[idx] = actionname;` — GPGOAP keeps the *caller's* `const char*`,
  it never `strdup`s. Driven from Lua, whose strings are GC-managed, the stored
  pointer dangles the moment the Lua string is collected, and `astar_plan`'s
  `strcmp`/description walks freed memory. **`src/lgoap.c` must own the name
  strings** (§3). This is the single most important finding — it would have bitten
  in Phase 1.
- **A typo is a silent new atom.** The author warns: mistyped atom/action names
  "will end up representing different atoms." There is no error — the planner just
  quietly plans over a predicate that never becomes true. We turn this into a loud
  failure with an atom-declaration discipline (§3).
- **Separate planners are the author's own advice** for distinct action sets —
  which validates the per-domain-planner strategy for living inside the 64-atom
  cap (§3), rather than one global namespace.

---

## 2. The conceptual mapping

| GOAP concept | boggart meaning |
|---|---|
| **Atom** | a named world-fact / predicate: `repo_cloned`, `tests_pass`, `deps_installed`, `invoice_parsed`, `manager_approved` |
| **Action** | a **dispatch target** — a tool call, a skill invocation, or a spawn-and-await of a sub-agent — declared with preconditions, effects, cost |
| **Start state** | current facts, derived from `kv`/`sql`/`memory`, prior tool results, or explicit probes |
| **Goal state** | the task's success condition, expressed as the atoms that must hold |
| **Plan** | an ordered list of action names boggart executes in sequence, routing each to its dispatch target |
| **Replan** | when an action's real effect diverges from its declared postcondition, re-derive the start state and plan again (classic GOAP) |

The payoff the request names — *planning across sub-agents / tools* — is the
coordinator building a world state, planning a goal into an ordered action list,
and dispatching each action to the right actor on the swarm bus, updating the
world state as effects land and replanning on divergence.

---

## 3. C layer — `src/lgoap.c`, exposing the `goap` global

A new C module in the exact shape of `sys`/`db`/`swarm`/`mcp`: a
`luaopen_boggart_goap` built with `luaL_newlib`, registered as a global. It owns
the string→atom interning (a C concern, capped at 64) and keeps the `worldstate_t`
/ `actionplanner_t` opaque behind a small Lua-facing surface.

Proposed `goap.*` API (names Lua passes; C interns and validates):

```
goap.new()                         -> planner handle (userdata wrapping actionplanner_t)
p:action(name, pre, pst, cost)     -- pre/pst are {atom=bool,...}; interns atoms, caps at 64
p:atoms()                          -- introspection: interned atom names
p:plan(start, goal)                -- start/goal are {atom=bool,...} (unset = don't-care)
                                   --   -> { actions={...}, states={...}, cost=N } | nil, "reason"
goap.describe(p)                   -- goap_description() text, for doctor / the library panel
```

The handle is a **userdata with a metatable**, following `src/ldb.c` and
`src/lmcp.c` exactly: `lua_newuserdatauv` for the `actionplanner_t`,
`luaL_newmetatable(API_TYPE_GOAP)` with `__index = mt`, methods resolved through
it, and a `__gc` that frees what the userdata owns. That "owns" is load-bearing
here (see the name-lifetime finding):

- **Name ownership — the fix for the use-after-free.** `lgoap.c` must not hand
  GPGOAP a Lua string pointer. On intern, `strdup` the atom/action name into
  C-owned storage held by the userdata (freed in `__gc`), *or* pin every name in
  a uservalue table so the collector can't reclaim it (`lua_newuserdatauv(L, …,
  1)`, as `lmcp.c` already does for exactly this reason). Recommend the `strdup`
  route: self-contained, and `__gc` has a clear job.
- **Atom-declaration discipline — the fix for silent typos.** A planner declares
  its atom vocabulary up front (`p:declare_atoms{"tests_pass", …}`); thereafter
  `p:action`/`p:plan` **reject** any atom name not in that set with a typed
  validation error instead of interning a new one. This is `strict.lua`'s
  philosophy (a misspelled global is a loud error) applied to the planner, and it
  matters most precisely because the model writes these names.
- **Interning & the 64-atom cap** enforced in C: `p:action`/`p:plan` raise a
  typed error (`Tool error: [validation] atom budget exhausted (64)`) rather than
  silently corrupting the bitfield. Design *around* the cap with **per-domain
  planners** — one planner per task/skill domain, not one global namespace, which
  is the author's own recommendation — so 64 is per-plan, not per-process.
- **Reentrancy** is guaranteed by construction, not by patching GPGOAP:
  `p:plan` is a single non-yielding C call. We add an assertion/guard so that if a
  future threaded path ever calls it re-entrantly it fails loudly instead of
  corrupting the static sets. (If we ever go multi-threaded, the fix is to pass
  caller-owned scratch buffers into a reworked `astar_plan` — noted, not done.)
- **Overflow** (`astar_plan` → `-1`, or open/closed set full) surfaces as
  `nil, "plan search exhausted"`, never a crash.
- **`actionplanner_t` is a value struct**, so many planners coexist; only the A*
  *scratch* is static, and cooperative scheduling serialises its use.

Vendor under `src/vendor/gpgoap/` (`goap.c/.h`, `astar.c/.h`), built into a
`gpgoap_vendor` static lib like `cjson_vendor`/`sqlite_vendor`.

---

## 4. Lua layer — `lua/plan.lua`, the orchestration loop

The C module plans; the Lua module *drives*. `lua/plan.lua` (overlay-mutable like
everything) owns:

- **The action registry.** Actions are declared next to the capabilities they
  invoke — a `goap` block on a skill or tool, or registered explicitly — each
  binding `{ pre, pst, cost }` to a **dispatch**: `{kind="tool", name=...}`,
  `{kind="skill", name=...}`, or `{kind="agent", spec=...}`.
- **World-state derivation.** An "atom provider" layer: functions that read
  current truth from `kv`/`sql`/`memory` or cheap probes and return `{atom=bool}`.
  Plus a hook on `tool:after` (events, §events) so an action's real result can set
  atoms, feeding replanning.
- **The plan→act→observe→replan loop.** Build start state → `p:plan(start, goal)`
  → for each action, dispatch to its target and await → apply observed effects →
  if reality diverged from the declared postcondition, re-derive and replan.

Two tools expose this to the model, mirroring the existing self-extension pair:

- **`plan`** — given a goal (a set of atoms), compute and return the ordered
  action list *without executing* (so the agent can inspect/approve a plan).
- **`define_action`** — `define_tool`'s planner-side twin: name, preconditions,
  effects, cost, and dispatch target. Persists to `<data dir>/lua/actions/` and
  is listed in the library panel with provenance, exactly like a generated tool.

---

## 5. How it coordinates sub-agents and tools

The swarm coordinator gains a planning-driven execution mode:

1. Derive the current world state from atom providers.
2. `p:plan(start, goal)` → ordered actions (deterministic, in C, sub-ms).
3. For each action, route by dispatch kind onto the existing bus: a `tool` runs
   inline; a `skill` switches the acting agent's permitted tool set; an `agent`
   is `spawn`+`await` over `lswarm.c` (the machinery already there).
4. Apply the action's effects to the world state; journal the transition.
5. On divergence (a sub-agent reports the effect did not hold), replan from the
   observed state.

This keeps the LLM out of the mechanical ordering problem and in the judgment
problem: *what are the goal atoms, did this action really succeed, is this the
right decomposition* — while A* owns *in what order do these capabilities fire.*
It composes with §6's Lua-steps model: a GOAP plan is a graph of dispatch nodes,
and each node is a tool / step / agent turn boggart already knows how to run and
journal.

---

## 6. Where the facts come from

World-state atoms are only as good as their providers. Sources, cheapest first:

- **`kv` / `sql` / `memory`** — durable facts the agent already records.
- **Tool results** — `tool:after` handlers translate an outcome into atoms
  (`tests` exited 0 → `tests_pass=true`).
- **Explicit probes** — small Lua sensor functions (file exists, git clean) run
  at plan time.

Providers are Lua, overlay-mutable, and namespaced per domain so the 64-atom
budget is spent locally.

---

## 7. Self-modification angle

`define_action` is to the planner what `define_tool` is to the toolset: the agent
can, at runtime, declare a new action — its preconditions, effects, cost, and
what it dispatches — persist it, and have it participate in the *next* plan. The
planner's action space grows with the agent, under the same provenance and
library-panel visibility that keeps runtime self-extension legible (§3's
auditability point). This is the self-modification thesis reaching planning.

---

## 8. Build, parity, and credits (the wiring that must not drift)

Because boggart is **one engine behind two front ends**, every one of these has a
matching pair — and `ninja core-parity` will *fail the build* if only one side
gets it, which is the intended safety net:

- **CMake**: add `src/lgoap.c` to *both* the CLI source `set(...)` (~L302) and the
  studio source list (~L447); add the `gpgoap_vendor` static lib and link it into
  both `boggart` and `boggart-studio`.
- **Registration**: add `luaopen_boggart_goap` and its
  `luaL_requiref(...; "goap"); lua_setglobal(L, "goap")` to *both* `src/boggart.c`
  and `src/bogembed.c`.
- **Fingerprint**: the `plan` / `define_action` **tools** are registered in
  `tools.lua` — shared harness Lua baked identically into both binaries — so they
  appear in both front ends for free and the existing `tools` line already parity-
  checks them. The gap is the **`goap` C global**: `fingerprint.lua` dumps
  `bog.api`/`bog.store`/`bog.tools`/`bog.memory`/`sys.caps()`, *not* arbitrary
  globals, so a front end that forgot its `luaopen_boggart_goap` /
  `luaL_requiref` would **not** be caught. Fix: register `goap` into `sys.caps()`
  (already fingerprinted) or add an explicit `put("goap", sorted_keys(goap))`
  line — so a missing C-side registration fails `core-parity` loudly.
- **Credits + license**: license is **Apache-2.0** (§1) — compatible, already in
  boggart's license set. Ship `src/vendor/gpgoap/LICENSE` (the Apache-2.0 text)
  and a credits line in the README; preserve the per-file headers. Confirmed, so
  no longer an open blocker — just wiring.

---

## 9. Tests

- **`tests/goap.lua`** (a new ctest suite against a throwaway HOME):
  - a classic textbook plan (start → goal) returns the known optimal sequence;
  - replanning: after an injected divergence, the loop produces a corrected plan;
  - the 64-atom cap and the 1024-node search overflow both return typed errors,
    not crashes;
  - determinism: same inputs → same plan (no `Date`/`random` in the path);
  - `define_action` persists and reloads through the same data-only file format
    as tools.
- **A headless swarm test**: a goal that decomposes into actions dispatched to
  two sub-agents; assert the plan, the dispatch order, and the journalled
  transitions.

---

## 10. Prompt and studio surfaces

- **`lua/prompt.lua`**: teach the coordinator *when to plan* — a goal with
  several discrete, precondition-ordered steps and clear success atoms — versus
  when to just act (a single obvious step, or a fuzzy goal that does not
  discretise). GOAP is for ordering known capabilities, not for open-ended
  reasoning.
- **Studio**: a `draw_panel` visualising the plan as a graph (states as nodes,
  actions as edges, the chosen path highlighted) — the agent drawing its own
  plan, which is exactly the "agent writes the interface" capability turned on
  the planner. Optional, Phase 4.

---

## 11. Phasing

1. **Planner works.** Vendor GPGOAP; `src/lgoap.c` + the `goap` global; CMake and
   registration parity; `tests/goap.lua`. No orchestration yet — just
   `p:plan(start, goal)` returning correct sequences.
2. **Actions & world state.** `lua/plan.lua` action registry, atom providers,
   `plan` and `define_action` tools. Planning over real boggart capabilities.
3. **Orchestration.** The plan→act→observe→replan loop wired into the swarm
   coordinator; dispatch across tools/skills/sub-agents; journalled transitions;
   the headless swarm test.
4. **Self-mod + surfaces.** Library-panel provenance for actions; the studio plan
   panel; prompt guidance finalised.

---

## 12. Decisions to confirm

1. **Action granularity.** Recommend actions dispatch to *any* of tool / skill /
   sub-agent (unified dispatch target), not just tools — it is the flexible
   choice and matches the swarm. Confirm this is the intended scope.
2. **Who may plan.** Recommend the coordinator by default, plus any agent whose
   skill grants the `plan` tool. Confirm.
3. **Vendor as-is vs. patch.** Recommend vendoring GPGOAP's `goap.c`/`astar.c`
   unmodified and relying on cooperative scheduling for the reentrancy guarantee,
   accepting the 64-atom / 1024-node caps as per-domain budgets. The name-lifetime
   fix lives in *our* `lgoap.c` wrapper (own the strings), not in a patch to
   GPGOAP — so the vendored files stay pristine and updatable. Patching GPGOAP for
   reentrancy/heap is deferred until a threaded path exists. (License is
   Apache-2.0, resolved — no longer a gating question.)
4. **GOAP's boolean limit.** Confirm we accept discrete-only planning here and
   keep numeric/resource decisions in the agent (or a later, different planner).
