# Evidence retention

Retention operates on trusted scope identifiers, normally project names. It is a
local SQLite ownership boundary, not an authorization grant or a secure-erasure
claim. Call these APIs from the trusted host, not generated workflow source.

```lua
local retention = require('evidence_retention')
-- Optional: all participating modules must use the same database.
retention.configure {db = bog.db}
retention.configure_scope('project-a', {expires_at = os.time() + 30*86400})
local artifact, error = retention.export_run(run_id, 'redacted')
local deletion_manifest = retention.delete_scope('project-a')
local sweep = retention.sweep(os.time())
```

`delete_scope(scope)` returns `id`, `scope`, `local_deleted=true`, per-table
`counts`, `external_status` and `physical_erasure=false`. Storage errors throw a
fixed error and roll back the entire operation. No successful manifest is returned
for a partial deletion. Repeating deletion returns the same durable job ID; an
acknowledged job stays acknowledged. Tombstones are permanent: create a new scope
identifier for later work instead of reusing a deleted name.

`sweep(now)` applies explicitly configured absolute scope expiry times, returns
`deleted_scopes`, aggregate per-table `counts`, and `unresolved` external jobs.
Scopes without an expiry are retained. This is scope expiration, not an inferred
age policy for individual events. `pending()` reads durable pending jobs.

## What deletion covers

One immediate SQLite transaction writes the tombstones, invalidates recorded
lineage, deletes payloads and creates an external deletion job. Database triggers
and current ownership checks fence already-loaded modules, second connections,
late terminals, resumable steps, new imports and old checkpoints. External calls
never occur inside this transaction.

Owned copies include:

- Native events and artifact bodies, with permanent artifact-ID tombstones.
- Import events, source metadata, references, quarantine, checkpoints and aliases.
  Import tombstones survive; a new source cannot re-enter a deleted scope.
- Durable workflow packages (including context and source snapshots), step
  requests/outcomes and scope-owned cache bodies. A suspended handle, portable
  resume and reconciliation cannot reconstruct deleted resumable data.
- Project sessions, transcript records, related journal payloads, session FTS
  documents and project memory. Existing memory triggers update memory FTS.
  Unrelated and global rows survive deletion of a project scope. A journal message
  to or from a deleted session is removed even if the other endpoint survives.

Each new workflow gets its owner from trusted `workflow.start` options/current
project. Nested runs, invocations and context resolution inherit the owner. Direct
native event producers supply `scope` on first observation. Stored session project
ownership is also accepted for legacy session evidence. Child sessions inherit
their parent's project. Correlation IDs and scope names must be nonsecret labels.

Session IDs are allocated atomically above both live and deleted IDs, so deleting
the greatest ID cannot make an unrelated new conversation inherit its tombstone.
Session/project reassignment that would separate a scoped transcript from its
native evidence is visibly refused with `retention_scope_transfer_requires_migration`.
Project absorption is atomic: a refused session transfer cannot separately move
its memory to global. No automatic migration of caches or lineage is guessed.

`runstore.cache.store(..., outcome, {scope=...})` and
`runstore.cache.lookup(..., {authority=..., scope=...})` accept explicit trusted
ownership. Omission uses the active workflow scope/current project. An active invocation or workflow ancestor wins over current-project defaults;
conflicting explicit nested scope is refused. `invoke.correlation()` returns a
trusted copied snapshot shared by invocation, context, workflow and cache code.
Scoped context providers push their correlation for nested work and restore the
previous coroutine-local binding on return/error; yielding does not alter the
resumer's binding.
Scope is part of the cache identity: identical inputs in two scopes have independently deletable
copies. Cache hits still require current execution authority.

## Legacy stores and lineage

Migrations add tables and triggers; they do not relabel historical private data.
Legacy native rows without run ownership remain readable but export as incomplete.
Normal append cannot assign a new owner to an existing unscoped run. After an
operator establishes ownership independently, `adopt_run(run_id, scope)` explicitly
attests it, including artifact references. Conflicting existing ownership or shared
cross-run artifact references are refused. Evidence run IDs must identify one
owner. Legacy session IDs already have trusted project ownership in `sessions`.

Old unscoped cache entries are excluded from the new scoped cache key space. They
remain on disk until an explicit operator-led inventory and cleanup; this API does
not guess their owners or delete unrelated cache entries. Orphan legacy artifacts,
arbitrary key/value entries, filesystem transcripts, exported files and backups
likewise require explicit inventory. A scope deletion manifest covers identified
owned rows; it does not assert that every legacy byte was attributable.

`register_lineage(evaluation_id, run_ids)` records evidence dependencies without
storing evaluation/private payloads. `lineage(evaluation_id)` returns `valid`,
`dependencies` and `promotion_qualified=false`. Deletion permanently invalidates
recorded dependencies. Missing events/artifacts, incomplete capture, omitted values
or unavailable storage also make lineage invalid. This is a dependency seam for
future evaluation; it does not manufacture an evaluation or authorize promotion.

Reusable source code in the independent code registry/files/index stays inspectable.
Do not embed private examples or credentials in reusable source; keep those in
owned evidence. Credential stores and their access controls are separate. Quota
ledgers, reservations and consumed usage are not changed or replenished by deletion.
Retained ownership hashes/IDs, scope names, tombstones and outbox statuses contain
no example payload. Deletion does not discard learned credential redaction state,
even when that state has reached its fail-closed capacity limit.

## Redacted export

`export_run` exports native run evidence. Historical imports have separate session
identities and remain available through the import read API; this native export
API does not silently combine imported observations with a native run.

`export_run(run_id, profile)` accepts only `nil`/`'redacted'`. It reads a consistent
SQLite snapshot and re-applies the current native redactor to events and referenced
artifacts. It returns a serializable table with `coverage`, `evidence_complete`
and `promotion_qualified=false`. Unmatched boundaries in either direction, mismatched lifecycle attempts, persisted
failed-start/incomplete metadata, known run-level capture gaps, omitted values,
legacy ownership and any known process capture/redaction failure yield incomplete
coverage. Disabled observation also yields incomplete coverage. Missing/deleted
runs, missing artifact bodies, storage failure or failed redaction return
`nil, 'retention_export_unavailable'`; a missing body is never substituted with a
successful export claim. Observation completeness is not evaluation qualification.

Capture failures produce payload-free `evidence_gaps` rows when storage permits.
If the first gap write also fails, the live evidence module retries through that
connection on subsequent capture. Each database queue is bounded to 256 distinct
run IDs and 64 KiB of ID/scope labels; only validated nonsecret or already-owned
labels enter retry memory. The strong registry additionally caps all pending
stores/candidate handles at 8, aggregate run IDs at 512 and aggregate label bytes
at 128 KiB. Unresolved gaps and markers are strongly owned until persisted,
proved tombstoned, or conservatively aggregated into a sticky incomplete marker;
ordinary Lua garbage collection cannot discard them. Up to 16 queued operations are attempted per capture,
round-robin across databases and runs, plus the immediate failed-run gap/overflow
marker attempts. Entries proven tombstoned are discarded. No retry yields or
calls capture recursively. `evidence.status()` exposes pending count/bytes/markers,
limits, pending store count, `gap_registry_overflow`, and `capture_blocked`.

Queue overflow sets sticky capture refusal and incomplete coverage. A payload-free
database-wide `evidence_capture_state` marker is persisted immediately if possible,
or retried after recovery. Once persisted it prevents complete exports after
reload/restart, even for unrelated runs whose missing observations cannot safely
be distinguished. Deleting a scope or toggling capture does not clear this marker.
There is no automatic reset API: keep that store conservatively incomplete;
operator-led reconciliation/new-store migration is separate work. A configured
degraded policy can still permit pure computation with explicitly incomplete
receipts, but cannot make the refused capture complete.

Store identity is a random opaque singleton in `evidence_store_identity`, elected
atomically with `INSERT OR IGNORE` and then read. It contains no filesystem path or
private source label. A replacement wrapper/connection rebinds a pending queue only
after reading the same identity; retries verify that identity before writing.
Configuring a reopened handle to the same store can therefore recover a closed
handle's pending gaps. Configuring an unrelated database cannot move those gaps.
An actual database copy carries the same logical identity; independent forks need
an explicit operator-led new-store migration rather than treating copies as
unrelated stores automatically.

Global registry/count/byte overflow leaves constant-size sticky refusal even for
an excess unavailable store whose handle cannot be retained. Retained stores get
pending conservative markers, and every subsequently configured/recovered store
is marked incomplete when writable. Excess handles/labels are not silently kept
in another unbounded candidate list. Recover affected stores while the live module
still owns this refusal if markers could not initially be persisted. A never-known
or unavailable identity cannot be guessed from a path; unavailable excess stores
that are not recovered before a crash have no promised durable marker.

Run-specific gap rows survive module/process restart and are removed with their
owned scope. The database-wide overflow marker survives scope deletion. Storage
failure cannot guarantee recording a gap before a crash: retry memory is
process-local, closed stores need a verified replacement handle, and an
uncommitted missing observation cannot be
reconstructed from nothing. Lifecycle pairing and terminal capture metadata add
independent durable checks; completeness describes available observed boundaries,
not a proof that arbitrary unobservable Lua activity never occurred.

Previously returned Lua values, user-created copies and already exported artifacts
cannot be recalled. Handles check ownership before exposing new snapshots and
resuming, but this is not guaranteed erasure of process memory. Stop participating
producers and restart them when operational policy requires clearing in-memory
values; destroy or expire previously exported files separately.

## External index reconciliation

Gestalt's index deletion protocol is not yet integrated. Local deletion therefore
returns `external_status='pending'`, even when no daemon is available. Supply a
trusted adapter when the real protocol and its index coverage have been validated:

```lua
local result = retention.reconcile(function(job)
  -- Perform the real external deletion using job.scope and job.id.
  -- Return only after all participating external entries are confirmed removed.
  return {id = job.id, acknowledged = true}
end)
```

The example defines the adapter contract, not a working daemon implementation.
A bare `true`, wrong ID, exception, or unconfirmed request leaves the job pending.
Adapters must be idempotent on `job.id`: a crash after remote deletion but before
local acknowledgement causes a retry. Their receipt acknowledges all external
indexes represented by that adapter, not just that a request was accepted. An
adapter can multiplex targets; it must wait for all of them before acknowledging.
Pending jobs survive restart and are included in sweep results. There is no
invented Gestalt action name and no network call in the core retention module.

## Deployment and physical copies

The current bundled store does not implement database encryption itself. Use an
encrypted operating-system volume and encrypted backups where supported; protect
keys separately and retain the store's owner-only filesystem permissions. A
separately deployed encrypted SQLite build needs its own supported integration and
verification; do not assume SQLCipher pragmas work on the bundled SQLite library.

Logical SQLite deletion does not guarantee removal from free pages, FTS internals,
WAL files, snapshots, backups, swap, filesystem copies or external indexes. Operators
may use the deployed SQLite version's supported secure-delete, checkpoint and
compaction facilities under their maintenance policy, after coordinating active
connections. These controls are not proof of physical erasure. Backup expiry,
export disposal and external acknowledgements remain separate operational work.
The retention API intentionally reports `physical_erasure=false` throughout.
