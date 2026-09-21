# Durable Lua runs and cached results

`workflow.register {id, version, source, durable='replay-v1', capabilities=...}`
opts a source workflow into durable reconstruction. Ordinary registrations keep
live-coroutine behavior and do not become resumable. All nested workflow source
packages must also opt in. Each capability needs a nonempty immutable deployment
`revision`; host adapters must be installed again with the same exact version and
revision after restart. The store persists exact source bytes, hashes, recursive
workflow pins, capability deployment/provider/source revisions, concrete context,
source revisions, runtime representation, instruction ceiling and representable
invocation restrictions. Metadata never reconstructs host closures.

```lua
local runstore = require('runstore')
-- Defaults to the existing store's bog.db. Tests can inject a SQLite connection.
runstore.configure {db=db}
local handle, err = runstore.resume(run_id, {authority=current_host_authority})
local state = handle and handle:snapshot()
```

`resume` returns a live workflow handle or `nil,{code=...}`. The handle executes
immediately through the existing `workflow.start` engine, to completion or an
adapter yield. A missing/non-opted-in run returns `workflow_non_resumable`;
terminal success/cancellation returns `run_terminal`. The caller must supply a
new opaque host authority. Stored restrictions only narrow that authority. The
original run-local `options.policy`, ancestor restrictions, allowlists, and global
restrictions are retained; current global and enclosing authority are still
checked by the common invocation gate. No persisted label grants authority.

The standard SQLite quota ledger is supported through a module-private identity
backed by an additive `quota_identity` singleton UUID and exact current host subject
bindings. Reopen the same ledger and inject it in the current authority; another
database or different subject binding is refused. No ledger object or callback is
serialized. Duck-typed custom ledgers, custom estimate/actual authority callbacks,
invalid/blocked authority and unrepresentable restrictions remain unsupported.

Original durable reservations use the persisted operation ID, allocated before
admission, so even a crash between reservation and adapter entry has a recovery
reference. Adapter entry additionally records the original invocation ID. Recovery
does **not** settle the original reservation: a successful effect reconciliation
can coexist with held accounting. The recovered receipt's `accounting_pending`
contains ledger identities, reservation/invocation references and
`settlement='not_attempted'`. Existing held estimates continue to consume quota;
subsequent operations must fit the remaining current quota. There is no invented
refund or historical-spend charge. Host accounting recovery remains a separate,
explicit operation.

## Source replay contract

Recovery reexecutes ordinary Lua control flow from the start. It validates the
ordered occurrence and input of every explicit step, capability invocation,
context resolution and explicit observation; completed results replace the
corresponding external observation. Step bodies still execute as Lua. Branches,
helpers, nested steps, nested source workflows, loops, nil and false returns are
supported. Every capability call must occur inside an explicit `ctx:step`.
There is no serialized Lua stack or bytecode and no graph execution engine.

Durable input and observation values have **value-copy semantics**, on both the
first execution and replay. Plain acyclic tables are copied structurally; repeated
references become independent copies. Mutating a returned context value cannot
mutate another resolution or its original binding. Identity-dependent host values,
functions, userdata, metatables and cycles are unsupported. Tagged encoding
preserves nil slots, numeric keys, Lua integers and floats. It is bounded to
20,000 visited values, 32 levels and 1 MiB encoded data. Encoding version, Lua
version, integer/number sizes, native endianness and locale are pinned.

Source defaults and nested context bindings must also be concrete values;
provider functions are refused. Observations needed for computation belong in
`ctx:call`, concrete `ctx:resolve` inputs or recorded `ctx:observe` return values.
Clock/environment access, randomness, generated coroutines and `ctx:yield`,
metatable construction, JSON/native helpers, pointer formatting and bytecode
inspection are unavailable. `pairs`/`next` use stable string/number key ordering.
The checked `string.format` supports ordinary scalar formatting. Raw string
metatable formatting/dump aliases are rejected by a composing source call hook;
this also covers `('%p'):format(value)` and aliases passed through helpers.
Caught forbidden operations remain fatal. Existing instruction hooks compose and
are restored; host formatting inside adapters/storage remains available.

This contract excludes arbitrary nondeterministic host execution. Capability
implementations remain trusted host adapters; changing their code or captured
configuration requires a changed deployment/provider revision. The store is a
trusted local database, not an authenticated checkpoint import format.

Any changed pin, observed occurrence/input/result, missing observation, unavailable
checkpoint, or incomplete prefix stops reconstruction before the next effect.
Redaction runs through the existing evidence prerequisite; a value changed by
redaction or containing partial/unavailable/artifact markers cannot become an
executable checkpoint. Disabled or saturated evidence capture also refuses durable
checkpoints. Evidence remains an independent observational log; its native origin
alone never makes an event resumable, and external artifact references are not
fetched as checkpoint content.

## Uncertain effects, ownership and limits

A committed start receipt allocates an OS-random `operation_id` before dispatch.
`execution.operation_id` reaches the first adapter call and is also recorded in
invocation evidence and its receipt. Missing/uncertain outcomes are never retried,
including reads, merely because an idempotency key exists. A registered
`descriptor.reconcile(args, execution)` can inspect the original operation ID.
It uses the original capability's input/resource/permission contract and the
current invocation gate; it is not an independent authorization route.

`runstore.reconcile(operation_id,{authority=current_authority})` returns the known
outcome or `nil,{code='reconciliation_uncertain',...}`. The hook must perform an
observational status lookup, return the original result only when it can prove the
operation completed, and use the normal `(result, metadata)` adapter convention.
Its usage reports **new status-query spend**, not the recovered operation's
historical spend. A hook that enforces provider ceilings must separately declare
`reconcile_bounded={tokens=true,...}` and `reconcile_estimate(args)`; the gate
passes query ceilings in `execution.ceilings` and validates new query usage. It
does not inherit the original runner's enforcement promise. Current limits and
quotas govern the query's new invocation/reservation independently of the held
original reservation. A not-found response is still uncertain; this implementation
does not use absence to retry a write. Repeated conflicting reconciliation receipts
are refused. Completed recorded outcomes are reauthorized before being returned.
Unknown providers leave the run visibly uncertain with no duplicate write.

Each resume claims a new persisted owner token. Older handles/reconstructors lose
permission to append/completely finish steps or dispatch later adapters. Unique
sequence insertion claims each new operation frontier before its first dispatch.
Takeover cannot stop an adapter already dispatched; the host/provider must
reconcile that operation. It does not infer process death from missing evidence.
Owner checks and operation identity prevent an older surviving handle from
advancing to new effects after takeover.

There are no automatic retries or compensation dispatches. At most eight executions
(initial plus seven reconstruction attempts) are allowed. Each attempt's instruction
ceiling is the minimum of its requested and original ceiling; replay consumes that
attempt's budget again. This is a bounded per-attempt instruction limit, not a
persisted cumulative VM counter or wall-clock timeout. Cancellation is terminal
for future reconstruction and does not undo external effects. Compensation, if
needed, must be an explicitly registered/pinned capability invoked in an ordinary
step, so it receives the same admission and evidence treatment.

## Result cache

Cache reuse is an explicit host action, separate from fresh workflow starts and
reconstruction. Fresh starts always resolve their current context and dispatch
their calls normally. No capability implicitly consults this cache.

```lua
local cache = require('runstore').cache
local freshness = {ttl=60, revision='dataset-epoch-7'}
cache.store(descriptor, args, dependency_manifest, freshness, successful_outcome)
local outcome, miss = cache.lookup(descriptor, args, dependency_manifest,
  freshness, {authority=current_host_authority})
```

Only registered `effect='pure'|'read'` capabilities declaring `cache='result'`
qualify. Nonempty deployment, provider and source revision labels, input content,
exact descriptor identity, dependency manifest and freshness revision/TTL form the
key. TTL must be positive and at most one year. Writes and unknown effects never
qualify. Changing source/code/provider/dependencies/inputs or expired wall-clock
freshness yields a miss. The host owns the declared input/dependency equivalence;
external changes without revised freshness/revision labels cannot be inferred.

A hit passes through current authorization, resources, approval, evidence and
quota checks before exposing the result. Its receipt names `execution.reuse`,
`original_invocation_id`, and `historical_usage`; artifacts are retained. New
provider usage is empty or zero for every enforced bounded metric, never the
historical token/cost usage. Current call-count quotas still count the local cache
invocation. Bounded cached reads reserve zero provider cost and settle zero actual
provider usage. The common gate's general custom-runner bound restrictions remain
unchanged outside this trusted no-provider reuse path.

The additive module-owned tables `durable_runs`, `durable_steps`, and
`durable_cache` use the existing store connection without changing legacy tables,
bus journal meaning or `store.SCHEMA_VERSION`. The quota module separately owns
the additive `quota_identity` table; it does not reinterpret prior reservations. Callers may inspect the evidence
log separately. Tests in `tests/runstore.lua` include two distinct executable
processes and only synthetic local/SQLite remote adapters; no external messages,
model calls or job dispatch are performed.
