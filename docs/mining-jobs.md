# Directed and background mining

`mining.jobs` is a trusted host API. Both modes enumerate every unordered pair
of a selected native evidence corpus and run the same real `mining.align` and
`mining.compile` engine on a native worker. Candidates are persisted but never
registered, evaluated, activated or executed. Objective text is a redacted job
annotation, not an instruction to a model. This first adapter accepts retained
native run IDs, with optional source-backed refinement through the host registry
described below. Imported histories, arbitrary loaders, models and remote
providers are not supported by the jobs API.

```lua
local jobs = require('mining.jobs')
local engine = assert(jobs.configure {
  db = evidence_db,
  authority = current_invoke_context,
  scopes = {project = {revision = '1', enabled = true}},
  ledger = dedicated_mining_quota_ledger,
  policy = assert(require('policy').compile {{
    id = 'mining', revision = 1,
    capabilities = {allow = {'mining.analyze'}},
    quotas = {{id='elapsed', metric='analysis_ms', limit=10000,
               window_seconds=60}},
  }}),
  background_enabled = false,
})
local id = assert(jobs.start {
  scope = 'project', range = {'native-run-a', 'native-run-b'},
  objective = 'Find repeated report preparation', mode = 'directed',
  budget = {ticks=20, wall_ms=100},
})
assert(jobs.tick(id))
-- Pump the existing uv loop; worker completion is polled asynchronously.
local status = assert(jobs.status(id))
```

`open(options)` creates an independent engine; `configure(options)` additionally
sets the module facade used by `start/status/cancel/resume/tick` and
`supervisor.mining_cancel(job_id)`. Each engine provides the same methods with
colon syntax. `tick(job_id_or_nil, {wall_ms=...})` admits at most one pair or
polls one live worker; nil selects directed work before background work.
A completed cached pair consumes one cursor position without worker dispatch.
The range is 2–32 unique run IDs, sorted before snapshotting. The persistent
`i,k,cursor` enumeration includes nonadjacent repetitions. Defaults are 496 pair
attempts and a 100 ms cancellation deadline. Maximums are 1,000 attempts and
1,000 ms. A per-tick deadline may only narrow the job deadline. Token/cost budgets
must be zero; unknown budget fields are refused.

Call `engine:background(on)` to enable background admission independently of
candidate activation. `engine:foreground(true)` defers new admission while the
host has interactive work queued; already-running bounded analysis stays on its
worker. `engine:schedule(name, when, optional_job_id)` installs an ordinary process-local trigger
which calls `tick`; rebuild that function trigger after restart with the existing
host trigger setup. Background mode does not discover a corpus or start a daemon:
the host selects a retained corpus, creates jobs and installs its scheduling rule.
The 5 ms completion timer exists only while a worker is live and is unreferenced,
so it does not keep the host process open. No polling path joins a running worker.

## Authority and retention

The scope registry is host-owned access authority, never populated from logs.
`set_scope(scope, {revision=..., enabled=...})` applies live revocation.
Each start/tick/status rechecks current scope ownership and retention tombstones.
The saved scope revision must still match; a missing provider/scope registration
fails closed. There are no serialized provider closures. Invoke durable
restrictions are captured at start and rehydrated against current host authority
at each admission. Every state in that reconstructed authority is checked with
the shared `tools.allowed` and `perm.decide` semantics: allow sets, chat/manual
modes, explicit tool policies, rules, agent rules and live host revocations remain
restrictive. A required approval is refused by this background API; it is never
silently treated as approval. Ordinary allowed auto contexts remain supported.
Inherited policy capability/resource rules and hard limits are
evaluated against the mining read as well. Inherited quota scopes are explicitly
refused (`mining_inherited_quotas_unsupported`); they are not dropped or reassigned
to the dedicated mining ledger. The separate mining policy must grant `mining.analyze`; the
original exact policy scope snapshot must remain available. Policy changes fail
closed, including narrowing changes: create a new explicitly authorized job.

Each source snapshot stores native run ID, scope, content-derived revision,
first/last sequence, count and byte size. Native reads use `recognize.native`
and are limited to 64 events and 32 KiB per run. Before analysis, cache reuse and
candidate publication, the exact retained bytes and current ownership are
revalidated. Changed, deleted, expired-by-sweep, incomplete or unavailable
sources are refused. No stale cursor or cached candidate grants source access.
`status` hides candidates whose stored dependencies no longer validate. Candidate
lineage is registered in the existing retention table. Direct SQLite access is a
trusted administrative boundary; derived rows are invalidated by API checks,
not physically deleted by this scheduler.

## Source-backed refinement

When a native run includes `workflow.start`, its observed root workflow identity
must include a source hash. Supply `options.sources[source_hash]` as
`{scope, revision, version, source, parameters={}}`. The registry is host-owned;
`version` must match the observed workflow version, `revision` identifies the
registry entry, and the bytes must hash exactly to the observed identity.
Optional parameters are a list of `{node=<literal AST node>, key=<context key>}`
(up to 256 entries). This list maps to the existing compiler parameter contract.
The source is limited to 32 KiB and is never executed by mining.

The snapshot retains hash, version, registry revision and parameter mapping.
Missing entries, changed bytes or revisions, scope mismatch and nested root
associations are refused. Re-register the same immutable entries after restart.
The worker builds fresh real AST indexes and passes them to both alignment and
compilation; source branches and local transformations retain BRAIN-27 semantics.
Mixing source-backed and source-free evidence in one pair produces an explicit
rejection. Mode does not affect generated source or provenance.

## Durability, overlap and cancellation

Schema version 1 uses `mining_jobs`, `mining_pairs`, `mining_candidates` and
`mining_slot` on the evidence connection. SQLite is configured with zero busy
wait. Transactions contain only bounded local metadata work, never worker
execution or waits. A singleton atomic claim allows one active miner per shared
SQLite store. Claims carry a random fencing token and owner PID. An alive owner
cannot be displaced by elapsed time. A dead owner permits pure analysis to be
recomputed; stale results cannot commit against a different token. PID reuse or
inability to establish death conservatively blocks reclamation. Shared storage
across machines is unsupported because local PID liveness is not distributed
ownership. A paused worker retains its claim; no replacement is started.

The pair key includes engine version, scope and both immutable source revisions,
independent of mode/objective. Candidate admission uniquely keys scope, actual generated source hash and the
execution contract (compiler/schema, capability pins and observed descriptors,
required context, verifier requirements and runtime limits); every completed pair retains its own provenance and jobs
retain input snapshots. A candidate stores its first admitted pair, while the
retention lineage table accumulates supporting runs. This conservatively
invalidates access if that first pair disappears even if other support survives.
There are no duplicate active candidates: every result remains inactive.

Pair selection is optimistic, but claim acquisition compares the persisted
cursor, generation and exact pair identity again inside the write transaction.
A changed selection returns `superseded`; the next bounded tick selects fresh
work. Cached advancement and result publication are fenced as well. A claim is
tracked locally before quota admission or worker startup. If reservation fails
and releasing the claim encounters a database lock, the same engine retries the
pending release before admitting any new work. No running worker is attached to
that cleanup state; a successful reservation is conservatively settled if startup
fails. These paths use the same completion timer and idempotent quota ledger.

`cancel` persists cancellation immediately, preserves cursor/results and requests
native worker cancellation without waiting. `resume` requeues cancelled work
under the same immutable snapshot and original budget. Clean restart opens the
same store and continues queued jobs. A killed process leaves its uncommitted
pure pair replayable after owner-death validation. No remote/model operation can
be blindly replayed because none is dispatched. Budget-exhausted/failed jobs
require a new job; resume does not replenish budget.

## Resource accounting and responsiveness

`wall_ms` is a cancellation deadline, not a hard CPU or wall-time ceiling. Native
C work, worker startup and host event-loop delays may overrun it. The native worker
safepoint is preserved; the scheduler never replaces it with a Lua debug hook.
Input bounds and compiler bounds cap the available analysis, while actual heavy
compilation runs off the foreground thread. The completion timer requests kill
when the deadline expires. The slot remains owned until the worker is terminal
and joined. Late results are rejected, retain their cursor for diagnosis and are
not cached as compiler rejection.

The `analysis_ms` quota reserves the deadline before dispatch, then settles at
at least that reservation or observed elapsed milliseconds, whichever is larger.
`last_elapsed_ms` and `deadline_overrun` expose measurement. An overrun blocks the
mining ledger through the existing quota contract and exhausts the job. A crash
retains the reservation. Use a dedicated mining ledger/database so resource
accounting cannot consume interactive invocation buckets; matching a ledger
identity captured from the invocation authority is refused. Foreground calls
continue through actual `invoke`/`quota` policies, and mining makes no capability
or model calls. This is a local responsiveness design with measured host tests,
not an OS CPU-priority or real-time scheduling guarantee.

`tests/mining_jobs.lua` exercises actual native evidence/compiler provenance,
pair coverage, overlapping candidate admission, cancellation/reopen, current
scope/policy revocation, changed retained bytes, SQLite lock contention and
foreground invocation quotas with a live uv heartbeat during worker analysis,
source-backed lowering/registry revisions, and settlement retry after an actual
SQLite writer lock. A joined result is retained until accounting and admission
commit, so transient database failures do not lose a live owner’s completion.
