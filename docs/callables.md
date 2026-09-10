# Callables: skills and tools as a little language

Status: core shipped (2026-09-10). `lua/callable.lua`, `tests/callable.lua`.

## The idea in one line

A skill or a tool is a value you can call, compose, and grow with code, and the
model call is just one primitive among them.

## Three lenses on the same thing

The design reads three ways at once; each names a real property.

**Try / catch / finally.** An invocation has a deterministic setup that can
answer without the model (`before`), a body, and a teardown that always runs
(`finally`). The `finally` is where verification and cleanup live, guaranteed,
not "the model remembered to."

**Unity GameObjects.** A Callable is an entity; behaviors attach as components;
boggart is the engine calling their lifecycle hooks. You extend a skill by
attaching a component that owns one deterministic slice, not by rewriting the
skill. `get` is GetComponent, `send` is SendMessage.

**Scheme.** It is a small combinator language. Callables are values;
`chain`, `first`, `cond`, `loop`, `then_`, `catch`, `verify`, `retry` are the
special forms. The model call is `eval` — the interpreter of last resort. Prose
is quoted intent; a Callable is compiled; every combinator you write is one
more thing that never reaches the interpreter.

The three agree on the point: **move work from the model into code, one slice
at a time, and the skill keeps working the whole way.**

## The gradient

Today a skill is prose the model reads and executes turn by turn — prose with
tool-call holes. Even a rigid five-step procedure spends a model round-trip per
step. The Callable model inverts it to code with model-call holes: `before`
does the deterministic setup, `cond` routes, `loop` iterates on a code
stop-evaluation, `verify` checks the result, and the model is called only where
judgment is actually required.

A skill migrates monotonically. Prose moves into components one step at a time;
each move deletes a model round-trip. A half-converted skill is prose-heavy and
correct; a fully-converted one calls the model zero times and is a Lua tool
wearing a skill's clothes. The `tools` table already records calls/failures/ms,
so you can see which skills have paid down their model cost.

## The primitives

    callable.new{ name=, before=, run=, finally= }   -- an entity
    node:attach(component)                            -- AddComponent
    node:get(name)  node:send(msg, ...)               -- GetComponent / SendMessage
    node(args)                                        -- invoke the lifecycle

Lifecycle per invocation: every component's `before` (attach order) → the first
`run` → every `finally` (reverse order, always). A `before` returning
`{ done = value }` short-circuits the whole invocation; `{ set = {...} }` threads
facts into the ctx.

## The special forms

    chain(a, b, c)          -- sequence; thread each result into the next (begin)
    first(a, b, c)          -- fallback; first real value wins (or / register_fallback)
    cond{ {test, body}, … }  -- code-decided branch; only the chosen body evaluates
    loop{ body=, until_=, max= }   -- iterate; until_ is a CODE stop-evaluation
    node:then_(next)  node:catch(fn)   -- compose; handle a raise
    verify(node, check)     -- run node, assert check(result) with code
    retry{ node=, check=, max=, repair= }   -- re-drive until it verifies
    model{ prompt=, tools= }   -- the eval primitive: a scoped model turn

### Stop-evaluations

`loop`'s `until_` is the sharpest case. Agentic loops (react-until-goal, ralph,
swarm rounds) ask the model "are we done?" every pass. A code stop-evaluation
answers for free when it can, and only a body that itself needs the model
spends a turn. `until_` receives `{ i = pass, last = the last result }` and
returns truthy to stop; `max` is the runaway backstop.

### Verifiers

A verifier is code that checks a result is real, not a model opinion. `verify`
runs a node and asserts a code check over its output, raising with a reason on
failure so an enclosing `retry`/`catch`/`loop` can react. A skill carrying a
`verify` FUNCTION gets it wired as a `finally` component automatically — its own
output is checked before it returns. (A `verify` STRING stays the model-run tool,
for skills that have not moved that check into code yet.) `retry` is the
contract: run, verify with code, repair, again — the retry decision is code, so
a flaky tool is re-driven without a model turn deciding to.

### The interpreter seam

`model{}` is `eval` made explicit: a Callable whose run does a scoped model
turn. `callable.evaluator` is the default, wired by the runtime to a real turn;
a test injects its own so the pure combinators stay testable without a model.
Everything else in the file is a special form or a compiled primitive.

## Call from anywhere

    bog.C(name)              -- a Callable for a skill or a tool, by name
    bog.tools.get(name)      -- a Callable over the tool registry
    bog.skills.as_callable(name)   -- a Callable GameObject for a skill
    bog.skills.invoke(name, ctx)   -- run a skill's code path directly

The model invokes a skill or tool by name; any Lua invokes it identically;
both go through one path. So a skill can call another skill as code, a tool can
be a step in a chain, and a stop-evaluation can invoke a tool to check state —
all without a model turn, all crossing the permission gate the same way a
model-issued call does.

## Converting a skill: what moves to code, what stays prose

Not every step should move. The rule that keeps a conversion safe:

- **`before` is safe, idempotent setup only** — reads and checks (pin a ref,
  read a fixed file, gather state), never a side-effecting action. A build, a
  deploy, a test run is the skill's *action*, and the model decides to take it;
  a `before` runs on every adoption, including when the skill was adopted to
  answer a question. Putting an action in `before` is the one real footgun.
- **`before` short-circuits with `{ done }` only when the answer is complete
  and free** — an empty diff, no merge in progress, a CLEAR report. Otherwise
  it `{ set }`s facts and lets the model do the judgment.
- **`verify` / `finally` checks should not need a runtime-chosen argument.** A
  check over the whole tree (conflict markers, leftover worktrees) runs as code
  cleanly. A check over "the file the model just wrote" needs the path the model
  chose, so it stays the model-run `verify` STRING until the skill threads its
  target — correct, not a gap.
- **Pure judgment, craft, and knowledge skills stay prose.** They are already
  Callables: an entity with a single model run. Guidance (grilling, research),
  craft (prose, tension), and knowledge packs (the luadox skills) have no
  deterministic slice to extract; converting them adds nothing.

The wins cluster where there is real plumbing: the git / build / diagnosis
skills for `before` and arg-free `verify`, and the state-reading skills
(supervisor) for `before`. The base set converted this way: code_review
(before), supervisor (before + short-circuit), resolving_merge_conflicts
(before + verify), git_worktree (finally teardown). The rest stay prose because
prose is already the right shape for them.

## Trust

Code that runs instead of the model runs with authority and no human mid-step,
so trust is the BTEAM tier question (docs/team.md): a builtin skill's
`before`/`run`/`finally` are trusted like `provides.run` today; an imported or
crew skill's code runs in the capability sandbox until blessed; and every tool
call a component makes still passes `perm.wrap_run`. "More code, fewer model
calls" is never "fewer safety checks" — the gate is at the tool boundary, and
code steps cross it exactly as model steps do.

## Worked example: code_review's setup as code

STEP 1 of `code_review` pins a git ref and fails on an empty diff — pure
plumbing that costs a model turn today. As a component:

    before = function(ctx)
      local ref = ctx.args.ref or bog.C("bash")({ command = "git rev-parse main" })
      local diff = bog.C("git_diff")({ base = ref })
      if diff == "" then return { done = "nothing to review (empty diff)" } end
      return { set = { ref = ref, diff = diff } }
    end,

An empty diff now answers in zero model turns; a real diff hands the model a
turn that already knows `ref` and `diff`, with the prose one step shorter. Do
this for STEP 2 and STEP 3 and the model is left only with the judgment: the two
review axes.

## Build order

1. `finally` — smallest, highest safety payoff, the guaranteed teardown.
2. `before` with `{ done }` — the zero-turn win.
3. the combinators — `loop`/`cond`/`verify`/`retry`, the language.
4. `model` wired to the real turn — close the interpreter seam so a skill can be
   an arbitrary mix of code and scoped model steps.

Steps 1–3 shipped as `lua/callable.lua` with 29 tests; step 4 is the wiring into
the agent turn.
