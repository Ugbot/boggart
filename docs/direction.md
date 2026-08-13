# boggart — direction, planning & competitive analysis (map)

One place that ties together the strategy, the competitive/borrow studies, the
planning work, and what is **built vs specced**. The detailed material lives in
the docs referenced here; this is the map so it can be reviewed and merged as a
whole.

## Competitive analysis & borrows

- **`comparisons.md`** — the studies, framed "could you rebuild X on boggart,
  what are the gaps":
  - §1 **OpenClaw** — boggart is the kernel, not the shell.
  - §2 **OpenAI Codex** — boggart's closest peer; wins on self-modification and
    multi-agent, loses on OS sandboxing.
  - §3 **pi** — the minimal harness boggart forks from; pi's aesthetic inverted
    into a self-modifying kernel. The capability boundary is the through-line.
  - §5 **Trigger.dev** — the durable-execution substrate §4 implies; borrow
    replay + waitpoints + idempotency, don't chase CRIU.
  - §7 **CodeRabbit** — an AI PR-review *platform*; the brain is boggart's
    strength, the platform is a separate build. Compete as a local-first,
    CI-integrated, swarm reviewer, not a SaaS clone.
  - §8 **t3code** — an agent control surface; complementary. Borrow git-ref
    checkpointing (done) and *be controllable* rather than build a client suite.
  - **Appendix** — why Lua, not a Lisp or a Scheme (the runtime vs the surface;
    Fennel dissolves the question).
- **`rendering.md`** — lite-xl visual/perf borrows for the studio (HiDPI and
  rencache already present; borrow the GPU renderer, gamma/subpixel fonts, a
  libuv-unified loop, subsyntax highlighting, multi-cursor).

## The forward direction (`comparisons.md` §4–§6)

- **§4 One kernel, two domains** — coding *and* business-process work over one
  loop with two tool-packs; the primitives are process primitives, not coding
  primitives.
- **§5 Durability** — replay + journal, not snapshot; lift waitpoints,
  idempotency, and a trigger source.
- **§6 Lua steps as workflow nodes** — the capability boundary *is* the
  effect-replay boundary, so safe + replayable + agent-authored steps are one
  thing.

## Planning — the HTN / GOAP work (`planner.md`)

- **HTN execution** — `lua/plan.lua`: a named task decomposes into ordered steps
  that fire with **no model turn between them** ("a skill minus the per-step tool
  call"). **Built, tested (23/23).**
- **GOAP search + per-agent blackboard** — `lua/goap.lua` + `lua/blackboard.lua`:
  an **opt-in** planner; state a goal world-state, A* over declared actions finds
  the tool ordering from the blackboard. **Built, tested (20/20).**
- **The C planner** — `planner.md`: the from-scratch HTN+GOAP core with arenas
  and TigerStyle discipline, unified over one world-state. **The destination if
  and when planning must drop below the Lua line** (performance, GOAP search at
  scale); the Lua prototypes exist to tell us whether it is worth building.

## Workspace & git (`workspace.md`)

- **git as a C capability** — `src/lgit.c` (via `uv_spawn`): checkpoint / restore
  / diff / worktrees, policy locked in C (hidden `refs/boggart/` refs,
  untracked-safe checkpoints) because git is the *safety net*. The Lua layer
  chooses what to do; the calls are locked in C. **Built, compiles clean.**
- **Model tools + skill** — `lua/gittools.lua` + `lua/skills/git_worktree.lua`.
  **Built, tools tested (15/15).**
- **Shared edit blackboard** — `lua/claims.lua`: agents claim files so they
  coordinate instead of colliding. **Built, tested (14/14).**
- **git for coders, the same safety without it** — the four capabilities
  (isolation, checkpoint/undo, review, collision-avoidance) with a git backend
  *and* a git-free snapshot backend, so non-coders get versioned, undoable,
  collision-safe editing of an ordinary folder. **Snapshot backend specced.**

## Other coding-agent work

- **Project-instructions file** — `BOGGART.md` / `AGENTS.md` / `CLAUDE.md` in the
  system prompt (the per-repo steering file boggart lacked vs Codex/Cursor).
  **Built, tested (9/9).**

## Built vs specced

| Built + verified | Specced (needs a build/runtime) |
|---|---|
| `plan.lua` (23), `goap.lua`+`blackboard.lua` (20), `claims.lua` (14), `lgit.c` (compiles) + `gittools.lua` (15), project-instructions (9) | the C planner; the git-free snapshot backend; auto-workspace wiring (auto-checkpoint on `turn:end`, auto-claim on `edit`/`write`); the studio renderer borrows; a `review` mode; the daemon/inbound layer |

Verification note: Lua verified on the vendored Lua 5.5 (81 assertions), `lgit.c`
compiles clean under `-Wall -Wextra`; the in-binary ctest suites and the studio
need the CLI/SDL to build, which the authoring environment lacked (no
libcurl-dev / SDL).

## The blocker that recurs everywhere

Nearly every direction here — business-process work (§4), CodeRabbit-style
review (§7), t3code-style remote control (§8) — is gated on the **always-on
daemon + inbound transport** boggart does not have. The cheapest first step is a
**CI Action wrapper** (`boggart review`, `boggart run` triggered by CI); the
fuller answer is a `boggart serve` control protocol on the vendored libuv loop,
which doubles as the substrate all three need.
