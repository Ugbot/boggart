# Named workflows and durable occasions

A trusted host reconstructs bindings before accepting work. Persisted names,
schedules and restrictions alone cannot authorize an execution. All named,
button, hook and timer work enters the same current registry `start` path,
which pins its version and applies its live admission checks.

```lua
local triggers = require('triggers')
triggers.configure_workflows { db = bog.db }
triggers.bind {
  id = 'followups', workflow = 'followup', project = 'my-project',
  registry = qualified_registry,
  authority = function() return current_host_context end,
  context_provider = { participants = current_participants_provider },
  schedule = { at = '09:00' }, timezone = 'Europe/London',
  misfire = 'once', overlap = 1,
  -- on = 'hook:followup', -- optional additional event source
  -- policy_scope = an_additional_restrictive_policy_scope,
}
local handle, why = triggers.run('followups', 'named')
```

`context_provider` is a map of ordinary concrete values, provider functions or
provider tables; each value retains the context runtime's provenance/cache
contract. Preview never invokes these providers. Reconnecting a binding keeps
its persisted original restriction floor. Changing workflow, project, schedule,
timezone, hook, overlap or missed-run policy requires a new identity.

The coordinator returned by `configure_workflows` supports `bind`, `run`,
`enqueue`, `execute`, `claim`, `tick`, `status`, `preview`, `pause`, `cancel` and
`recover`. `run(id, origin, occurrence)` is synchronous; origins are `named`,
`button`, `timer`, `hook`. `enqueue` only claims and queues. Timer and HTTP
callbacks enqueue; the serve actor executes. The Studio Run button executes on
a Studio thread, through the same coordinator. Hosts may supply `enqueue(job)`
to `workflow_triggers.open` and then call `execute(job)` from their own actor.
The queue token's identity is private; editing event fields cannot retarget it.

SQLite primary keys deduplicate `(binding ID, occurrence ID)` across processes.
A schedule's occurrence ID is its due UTC second. Claiming does not mean effects
occurred: rows distinguish claimed, dispatching, suspended, uncertain and terminal
workflow statuses. There is no elapsed-time lease takeover. Concurrency is one
per binding; only `overlap=1` is supported. Uncertain and recovering work retains
the slot. Cancellation of another executor records a request and denies its next
admission; it does not assert that an already dispatched effect disappeared.

Intervals preserve their original phase. Daily `HH:MM` matching uses explicit
TZif transitions with gap skipping and first-instant-only folds. `misfire='skip'`
skips occasions more than 59 seconds late; `once` coalesces missed occasions into
one queued occurrence. Overlapping due work is skipped. Pausing prevents new
claims and subsequent workflow admissions. Resume applies the same missed-run
policy. Status includes binding availability, last/next UTC time and occurrence
outcomes. Missing current host bindings remain unavailable after restart.

The TZif reader follows [RFC 8536 sections 3.1–3.3](https://www.rfc-editor.org/rfc/rfc8536.html#section-3).
It reads `/usr/share/zoneinfo`; a trusted host can supply an installed database
with `require('trigger_timezone').configure(directory)`. UTC needs no database.
Explicit transitions and constant-offset POSIX footers are supported. Dates
requiring future DST footer rules are refused as `timezone_horizon_exceeded`;
leap-second tables are refused. There is no ambient process timezone mutation.
Native Windows timezone lookup is not implemented: use UTC or an installed TZif
database. OS database updates are an external dependency and should be monitored
by the deploying host.

`recover(id, occurrence, quiescent)` can reconstruct a replay-v1 run with the
original context/dependency pins and current registry/policy. The supervisor's
`quiescent(id, occurrence, run_id, ticket)` must return the exact-owner proof
described below only after establishing that the old executor stopped. Timeout is not proof. Recovery
claims one owner transactionally; runstore reconciles pending effects and never
blindly repeats them. A crash between dispatch admission and saving the run ID
stays explicitly uncertain. Non-replay-v1 workflows cannot be reconstructed.
An undispatched claim can be recovered without quiescence because the transition
to dispatch is serialized. Repeated recovery never creates a fresh logical run.

`invoke.live_context(resolve, initial)` is a trusted-host-only authority binding.
It retains the initial floor, resolves fresh opaque authority for every effect,
and rechecks after authorization callbacks. Replacement resource restrictions,
capability policy and quota ledgers therefore apply to queued work and subsequent
provider calls. A resolver must be synchronous and pure with respect to effects:
mediated calls are refused, yielding fails closed and Lua work has a 50,000
instruction bound. Raw host I/O is a host responsibility. Missing, cyclic or
invalid authority fails closed. No client payload can create this binding.

Scoped control clients may queue `/prompt`, post `/hooks/<name>`, and manage
legacy prompt triggers subject to their route capability grants. The boot actor
executes attached private authority; hook forwarding intersects both originating
client and trigger restrictions. Persisted trigger restrictions are not grants:
the named control binding must exist now. A client stop/revocation narrows pending
work. Scoped clients still cannot mutate `/permissions`.

`GET /workflows` shows configured bindings. `POST /workflows/<id>/run` queues a
named run, `GET /workflows/<id>/preview` has no effects or claims, and
`POST /workflows/<id>/pause` accepts `{paused=true|false}`. Studio's
`agent:workflows` command (Ctrl+Shift+W) opens actual Run, Pause/Resume, Cancel and Preview
buttons in both shell and legacy compositions. Only host-configured bindings
appear; creating or promoting code is a separate operation.

For reconstructible learned schedules, set `execution_profile='replay-v1'` on
the binding. The registry requires an additional explicit host qualifier:
`qualification.profiles['replay-v1'](candidate, report, phase, ctx)` must return
`true, evidence_reference`; the ordinary qualification check also runs and
`ctx.options.execution_profile` identifies the requested profile. Durable starts
use a distinct runtime identity, preserve candidate source/version/capability
pins, require deployment capability revisions and concrete snapshot-able context,
and never silently fall back to nondurable execution. Provider closures remain
available on ordinary bindings.

Recovery's quiescence callback receives `(id, occurrence, run_id, ticket)` and
returns `true, {owner=ticket.owner, monitor_owner=ticket.monitor.owner, ref=proof}`.
It must establish that precisely those executors have stopped. Occurrence and
monitor ownership both compare-and-swap the exact observed owner and rotate it;
a stale proof cannot take over a successor. `ticket.monitor.owner` is absent
for an unmonitored registry. Registry `resume` reconstructs current guards and
terminal observation using persisted original learning identity, not persisted
callbacks. The resumed terminal resolves the same pending monitor receipt and
retains independent verification semantics.
