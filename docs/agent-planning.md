# Agent-level planning + swarm supervision

> **Status (2026-08).** Shipping. `lua/plansup.lua` is the module; the `planner`
> and `supervisor` skills, the `planner` standard agent, the durable
> `swarm:actor_stopped` handler, and the studio dashboard are all wired and
> tested (`tests/plansup.lua`, ctest `plansup`).

This is the **agent-level** layer on top of the swarm: how one agent plans work
across many, and how anyone (a human, the coordinator, or a sub-agent) can see
what the swarm is doing and what needs attention. It deliberately does NOT touch
the C-core HTN+GOAP design in `planner.md` (whose Lua prototype —
`lua/plan.lua`/`lua/goap.lua`/`lua/blackboard.lua` — is that planner's current
form). The two live at different altitudes: the core planner searches over
declared boolean actions; this layer decomposes goals into *agents*.

## The one decision: plans are rows, not files, not processes

`plans` and `plan_steps` live in the shared SQLite store (`~/.boggart/boggart.db`),
the same store every session, agent, and the studio already read. That makes the
plan:

- **shared** — any agent in any session can read or advance it; the supervisor
  does not need to be the planner's parent;
- **durable** — a plan survives restarts, because it is not a conversation;
- **queryable** — progress, ownership, failures are SQL, not prose;
- **single-sourced** — the planner skill writes these rows, the supervisor skill
  reads them, the dashboard renders them; there is exactly one truth.

There is no supervisor process and no background loop. Supervision is
on-demand reads over the same store (plus the in-memory claims registry).

## Schema

```sql
plans(
  id, project, goal, status,            -- planning|active|done|failed|superseded
  owner, created, updated, context, result)
plan_steps(
  id, plan_id, seq, label, detail,
  deps,                                 -- JSON array of step ids
  status,                               -- pending|running|done|failed|skipped
  agent_id, spawned_at, started_at, finished_at, result, error)
```

Dependencies are edges between steps: a step is *ready* when it is pending and
every step it depends on is done. `plan_wave` dispatches the ready set (the
"wave"); a wave can contain several independent steps, which is where the
parallelism comes from. A step depending on a **failed** step is not ready —
the planner must re-add the step (fixed) or fail the plan, it does not silently
proceed.

## The planner (skill + standard agent)

`lua/skills/planner.lua` teaches the loop; `lua/agents/planner.lua` is the
standard agent you can `spawn` by name (`agent="planner"`). The loop:

1. **Decompose** the goal into a dependency DAG of 2-8 steps, each one
   self-contained task for one sub-agent.
2. **Persist** — `plan_new`, then `plan_step` per step (deps by label or id).
3. **Audit** — `plan_audit` before anything runs; fix every finding (a
   typo'd dep label is reported by `plan_step` at add time and by audit).
4. **Dispatch in waves** — `plan_wave` returns the ready steps; spawn one
   sub-agent per step; `plan_assign` records who owns what (so the supervisor
   and the event handler can track it). Respect the agent cap: if `spawn`
   refuses, await what is running and retry, or do it yourself.
5. **Verify + advance** — `await` the results, judge each one
   (`ok=false` on "Tool error:" or a missing deliverable), `plan_report`,
   then `plan_wave` again.
6. **Synthesize + close** — `plan_finish` with the outcome; a plan whose
   steps all resolve done auto-finishes.

`verify = "plan_audit"` makes the audit the planner's self-check: boggart
nudges it to run and fix what audit flags before finishing.

## The supervisor (skill + tools)

`lua/skills/supervisor.lua` teaches the read-pass; the tools are:

| tool | what it returns |
|---|---|
| `fleet_status` | every sub-agent + root: id, status, age, silence, stuck flag, skills, last message |
| `plan_status` | every plan with done/running/failed/total |
| `swarm_report` | the cross-check verdict: stuck agents, running steps + owners, FAILED steps, stalled plans, dead-agent claims |
| `panel_refresh` | rewrites the studio dashboard with a fresh snapshot |

`verify = "swarm_report"` makes the report the supervisor's self-check. A
*stuck* agent is one that has been `running` and silent for more than
`M.STUCK_AFTER` (600s) — silent, not merely slow; agents legally wait on the
scheduler and on sub-swarms.

## The dashboard (studio panel)

`~/.boggart/ui/swarm.lua` renders the snapshot: plans with progress bars, the
fleet table with stuck flags, claims. Panels run in a restricted environment
(no io, no db — "a panel that wants data should be given it by the host"), so
`panel_refresh` regenerates the file from a fresh `SNAP` embedded in the source
and the studio hot-reloads it on change. `draw_panel` can be used to put it on
screen; `panel_refresh` keeps it current.

## Durability: the actor_stopped handler

`~/.boggart/lua/events/plansup.lua` subscribes to `swarm:actor_stopped`
(`{id, reason, detail}`, reason = done|crashed|killed). When an agent stops it
closes the plan step it owned (`plan_steps.agent_id`): done on `done`, failed
with the detail otherwise. So plans advance to the truth even if the planner
never calls `plan_report` — supervision reads reality, not intentions.

## Files

- `lua/plansup.lua` — schema, plan lifecycle, fleet/supervise reads, panel
  generator, `M.tools` (registered by `lua/tools.lua`, same pattern as claims)
- `lua/skills/planner.lua`, `lua/skills/supervisor.lua` — the two ways of working
- `lua/agents/planner.lua` — the standard agent (added to `agents.lua` list)
- `~/.boggart/lua/events/plansup.lua` — the durable event handler
- `tests/plansup.lua` — hermetic suite (lifecycle, deps, audit, fleet, panel,
  registry wiring, real-registry round-trip); runs as ctest `plansup`
