# Durable learning promotion

`learning.registry.open(options)` is a privileged host API backed by the supplied
SQLite connection. It returns an instance; methods use `registry:method(...)`.
Untrusted workflow source cannot obtain this registry. It stores immutable
candidate execution contracts and evaluator reports, mutable lifecycle states,
project/workflow controls, active pointers, logical run pins and an append-only
reason/evidence ledger. Storage and evaluation alone never activate a workflow.

```lua
local registry = assert(require('learning.registry').open {
  db = db,
  project = 'project-scope',
  revisions = {policy='12', resources='7', preconditions='4'},
  validate = function(candidate, report, phase, context)
    -- Recheck authoritative retained evidence/lineage, dataset and source access,
    -- policy/resource revisions, dependency revisions and applicable inputs.
    -- Enforce configured statistical thresholds using report measurements.
    return true, 'host-ledger:current-check'
  end,
  qualification = {
    id='qualified-runtime-and-adapter-contract', revision='3',
    check=function(candidate, report, phase, context)
      -- Require independent qualification for this exact source, dependencies,
      -- runtime, providers, execution options and supported preconditions.
      return true, 'host-ledger:runtime-check'
    end,
  },
})
assert(registry:register('followup','v1',candidate))
local report = assert(registry:evaluate('followup','v1',dataset,evaluation_policy))
local head = assert(registry:head('followup'))
local activation = assert(registry:activate('followup','v1',report,{
  expected_generation=head.generation,
}))
local handle = assert(registry:start('followup',{
  run_id='host-logical-run-123', authority=current_authority,
  context=current_injected_context,
}))
```

The callbacks above illustrate the host boundary, not implementations of source
retention, resource policy or runtime qualification. A host must supply real
checks and revision identities. Callbacks receive independent plain-data copies
of the candidate/report. `phase` is `activate`, `rollback`, `resolve` or `effect`;
context on resolve/effect contains `run_id` and, for actual starts, `options`.
Callbacks must return exactly `true` and a nonempty evidence reference, execute
synchronously, and never perform application effects. Exceptions fail closed.
The current `options.revisions` and qualification identity must match those bound
when the report was produced. Hosts must change revisions when callback semantics,
policy, resources, supported runtime or evidence lineage change; hashes cannot
identify closure implementations. Re-evaluation uses a new immutable version.

The registry runs `learning.evaluate.run` itself and stores its exact result.
Activation accepts only that stored report's hash, exact candidate contract/source
hashes, eligibility, complete costs, fresh held-out coverage, independent verifier
success and no known regression. It refuses missing, edited or stale reports.
Hosts can enforce additional statistical thresholds in `validate`; there are no
hidden success-rate or savings thresholds. Lossless tagged JSON preserves numeric
keys, integer/float distinctions and report floating-point values across restart.
The evaluator's shared identity serializer is used without changing its contract.

An isolated report retains `coverage.production_runtime_qualified=false` and
`runtime='isolated-compiler-subset-v1'`. A separate host qualification is mandatory
at admission; activation audit records cite it separately. The registry supplies
no universal production qualification and does not certify arbitrary authored Lua,
workers, asynchronous providers, backends or external services. Tests exercise
synthetic local adapters and actual workflow suspension; they send no messages.

## Controls, lifecycle and rollout

`control(nil, mode)` sets the project mode; `control(id, mode)` sets its workflow
mode. The default is `auto`. Effective mode is the most restrictive of project,
workflow and requested activation mode: `auto < review < off`. Thus a per-call
`auto` cannot widen a project `review` or `off` setting. `activate` in auto mode
switches immediately when every gate passes. Review returns an audited `queued`
record. Off returns an audited `off` record. Neither changes the active pointer.
These controls govern promotion, separately from mining background settings and
already selected execution.

Hosts may configure `approve(id,version,report,approval)` returning exactly true.
An activation with `approval=host_token` can then satisfy review mode; off remains
restrictive. Approval must be independently authenticated by that callback. Queued
records are discoverable with `audit(id)` and can be resubmitted against the current
generation after review; stale queued approvals cannot bypass fresh gates or CAS.

Versions transition `candidate -> evaluated -> active`; a replaced active version
returns to `evaluated`. `set_state(id,version,'disabled'|'quarantined',reason)`
blocks new resolution and subsequent admission for that version without changing
any run's pinned version. It does not automatically select a replacement. Use
`rollback(id,target,{expected_generation=N})` to select a previously evaluated,
currently valid, unblocked version. Rollback obeys current authority, runtime
qualification and review/off controls too. Blocked versions cannot be silently
re-enabled; register/evaluate a new version after correction.

`activate(...,{expected_generation=N,percent=10})` stages an evaluated version to
a deterministic percentage of new logical run IDs, with the previous version as
fallback. Staging requires an existing pointer. `rollout(id,percent,options)`
changes the percentage with the same gates and mandatory generation CAS; 100
finishes rollout. Fallback selection also revalidates its own evidence/admission.
The cohort hash includes project, workflow and logical run ID. Existing run IDs
retain their recorded selection through rollout changes and rollback. A disabled
or invalid fallback fails closed instead of silently rerouting the run.

## Transactions and execution pins

All pointer changes, CAS winner/conflict audit records, controls and pin selection
use SQLite `BEGIN IMMEDIATE`. `expected_generation` is mandatory for activation,
rollback and rollout. A stale generation returns `nil,{code='activation_conflict',
record=...}` and durably records the conflict. A lost activation response retried
with the original generation cannot claim another winner; inspect `head` and
`audit` to recover the outcome. The SQLite busy timeout is five seconds; unavailable
storage refuses admission. This is local/shared-file SQLite coordination, not a
cross-machine distributed authority.

`resolve(id,{run_id=...})` returns `{id,version,source_hash,contract_hash,run_id}`
and durably pins the logical run under `(project,id,run_id)`. Omit a logical run ID
only when using `start`, which generates one. Host IDs should represent a single
logical run; they are not dispatch deduplication or replay-safe effect keys.

`start` selects the durable pointer, registers an inactive immutable source under
`learning:<project-length>:<project>:<id>`, and calls the real workflow runtime with
an explicit version. It rejects a caller version override or conflicting scope.
The namespaced runtime ID avoids cross-project process-registry collisions;
`handle:snapshot().learning` records the logical project/workflow/run identity.
No process-local default active pointer is set. On restart, call `open` and `start`
again; durable selection is restored without relying on registration order.
The trusted legacy workflow API remains available for separately authored flows.
Hosts must route learned execution through this registry; privileged host code
can deliberately bypass its own policy and is not a security sandbox.

Actual source/capability/provider implementations are pinned by the existing
workflow runtime. A fresh admission callback runs on workflow operations and
immediately before each context capability dispatch, including provider calls.
Nested workflow resolvers inherit that callback. Ordinary invocation policy/quota
checks still run. A suspended run can therefore resume its old code while current
revocation denies its next effect. Admission failure cannot undo an already
dispatched effect. Logical pins survive restart, but this module does not serialize
suspended coroutines or promise exactly-once external effects; durable replay is a
separate runtime contract.

`get(id,version)`, `head(id)` and `audit(id)` expose copied durable state. Public
methods return `nil,{code=...}` on failure. The state tables and audit ledger are
host-trusted storage, not signed evidence or tamperproof against a database owner.
