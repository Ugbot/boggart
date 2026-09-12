# Skill conversion playbook: prose to executable, for token reduction

Status: active batch (2026-09-12). The contract every skill conversion follows.
Read with docs/callables.md (the calculus) and docs/compounding.md (the why).

## The one goal

Cut model round-trips. A prose skill spends a turn per step; the deterministic
steps are code the model is hand-interpreting. Move each into `before` /
`finally` / `verify` / a component, and it is free next time. The model keeps
only the judgment. Order the work by round-trips saved.

## The shape (GameObject / Callable)

A converted skill is a table with any of:

    before = function(ctx)  ... end   -- code setup, runs first, per invocation
    finally = function(ctx, res) ... end  -- code teardown, always runs
    verify  = function(res, ctx) ... end  -- code check of the skill's OWN output
    components = { {name=, before=, finally=}, ... }  -- attached behaviors
    instructions = function(ctx) ... end  -- prose the model runs, now ctx-aware

`before` returns `{ done = value }` to short-circuit with zero model turns, or
`{ set = {...} }` to thread facts into the turn. `verify` returns `true` or a
string reason. See lua/skills/code_review.lua and resolving_merge_conflicts.lua.

## What moves, what stays (the safety rule)

Prefer, never replace. Code is a preference with the model as fallback.

- **`before` = safe idempotent reads only** — pin a ref, stat a file, read a
  fixed doc, gather state, probe a daemon. NEVER a side-effecting action (build,
  deploy, test run, write): the model decides to take those.
- **`before` short-circuits `{done}` only when the answer is complete and free**
  — empty diff, no merge in progress, daemon down, cache hit.
- **`verify` FUNCTION only when the check needs no runtime-chosen argument** — a
  check over the whole tree (conflict markers, leftover worktrees, a style scan
  of a known file) is clean code. A check over "the file the model just wrote"
  needs the model's path, so it stays a `verify` STRING nudge.
- **Pure judgment/craft/knowledge bodies stay prose.** They are already
  Callables: one model run. Do not fake code into them. BUT most still gain a
  real code slice below.

## Per-category recipe

- **Coding / build / test** (tdd, cmake_build, cmake_test, diagnosing_bugs):
  `before` gathers and pins (repo root, target, last failing output, the build
  command that exists). `verify` runs the build/test/lint as CODE and returns
  the failure text on red. This is the biggest saver: the "did it pass?" loop
  stops costing a turn.
- **Writing / craft** (prose, tension, worldbuilding, plotting, six_prose,
  science_draft, science_proofread, style_extract): body stays prose (voice is
  judgment). These deliver to a model-chosen FILE and return a path, so `res` is
  not the prose and an arg-free `verify` FUNCTION cannot see it. The working
  pattern: the skill `provides` a `check_*` tool whose body reads the manuscript
  file and scans it against the style guide's single-source lists (style.lua /
  sci.lua, published on the `data` channel so writer and checker cannot drift),
  and `verify` NAMES that tool. A code style pass then replaces a second model
  proofread turn. A skill with no checker and no `bash` puts the de-slop rule in
  its instructions prose, pulling the ban list live from style.lua.
- **Reference / knowledge** (luadox-*, science_references, novel_project_layout):
  `before` loads the fixed doc/layout from disk as code and `{set}`s it, so the
  model is handed the reference instead of spending a turn fetching it. No
  short-circuit; the model still does the work with the facts in hand.
- **Orchestration / state** (research, planner, orchestrate, supervisor✓):
  `before` runs the read-only status gathering (plan_status, fleet_status, a
  scan) and `{set}`s it, or `{done}`s on a clear/empty state.
- **System / IO** (sysmon, media_opener, local_gptoss): often fully compilable
  to a tool — a `before` that does the whole read (system stats, resolve a
  path) and `{done}`s the answer. Zero model turns is the target here.
- **Meta** (mcp, memory, comms, core, data, selfmod, grilling, grill_me): mostly
  guidance; convert only a genuine slice (e.g. memory's recall probe in
  `before`). Leave the rest prose rather than force it.

## Rules of the batch

1. Never delete the prose the model needs; `instructions` degrades to a plain
   string when called with no ctx (the ambient-grant path, lua/thread.lua).
2. Keep boggart's prose style: no em-dash, no needless adjectives/adverbs,
   comments one line unless a docstring.
3. After converting, the skill must still `bog.skills.as_callable(name)` without
   error and its `before` must run without a daemon/model present (guard every
   external call, degrade to `{}` or a prose fallback).
4. Report per skill: what slice moved to code, and the model round-trips saved.
