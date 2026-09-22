# Monitoring learned procedures

`learning.monitor.open` creates a privileged, project-scoped monitor and attaches
it to the supplied durable registry. It observes actual workflow terminal
snapshots; it does not infer independent verification from `status='succeeded'`
or from isolated evaluation reports. Use the same durable database as the registry.

```lua
local monitor = assert(require('learning.monitor').open {
  db=db, project='project-scope', registry=registry,
  assess=function(snapshot)
    -- Host-owned independent checks of this exact run, resolved current inputs,
    -- result, source/dependency versions and retained evidence. No application effects.
    return {
      variant='recipient-report',
      verifier={passed=independent_result_check(snapshot), ref='host:verifier:123'},
      dependencies={current=true, ref='host:current-dependency-check:123'},
      applicability={current=true, ref='host:current-input-check:123'},
      cost={value=2, unit='USD'}, latency_ms=42,
    }
  end,
  policy={window=64, min_samples=3, failure_rate=.2, unknown_rate=.5,
    z=1.96, cost_ratio=1.5, cost_max=1000, cost_unit='USD', alpha=.05,
    max_runs=10000, max_groups=256},
})
local health = assert(monitor:explain('followup'))
```

The shown policy values are defaults except `cost_unit` (default
`host_cost_units`). A verifier supplies exactly boolean `passed` and a nonempty
reference. Host callbacks receive a private snapshot and must check independently
of generated code. They are synchronous trusted host code and must not dispatch
application effects or perform unbounded work. They must account for all task
costs, including failed attempts and allocated mining/evaluation/judgment cost,
in the declared unit. Missing, negative, nonfinite, differently denominated or
above-`cost_max` costs remain missing; they are never silently clamped. The host
is responsible for the truth, freshness, independence and version binding of its
assessment references. This interface cannot authenticate fabricated privileged
host assertions. Failed assessments become explicit unknown observations.

The runtime calls privileged `options.on_terminal(snapshot)` once, after terminal
evidence capture, including eventual resume and cancellation. Suspension does not
count. Observer errors are reported in `snapshot.monitoring` without rewriting
application outcomes, rerunning effects or selecting a fallback. Registry starts
compose an existing caller observer after monitoring; an exception in that caller
observer does not change the monitor outcome. The monitor is attached explicitly
with `registry:monitor(instance)`; project identity must match. There is no global
selector. Ordinary unconfigured registries preserve their previous behavior.

Before starting the runtime, `registry:start` calls `monitor:begin(id,version,run)`
to reserve a bounded durable pending observation. A runtime creation refusal
calls `monitor:abort`; a completed observation removes the reservation in the
same transaction as its receipt and health sample. These are host integration
methods, not tools exposed to workflow Lua. Pending entries from another monitor
instance cause `monitor_recovery_required`, including after process restart.
Reconcile them with `monitor:observe(actual_terminal_snapshot)`. Do not invent a
successful outcome for a crashed or uncertain run. If no terminal snapshot is
available, admission remains blocked until an operator reconciles the underlying
runtime/effect evidence. `explain` includes pending run hashes and version IDs.

An observation failure also blocks subsequent admission in the attached registry
instance. Reopening and reconciling the durable pending record restores admission
without erasing failed evidence. Pending quarantine is saved before applying
`registry:set_state(...,'quarantined',reason)`; if that second operation fails,
the durable health flag still blocks registry admission. Replaying the observation
retries only the state transition. An inherited runtime admission check consults
current health and registry state before subsequent effects.

`observe(snapshot)` returns `{duplicate, quarantined, reason, health}`, or
`nil,{code=...}`. Logical identities are project/workflow/version/run, not caller
success labels. Duplicate outcomes remain duplicates after restart. Completed
outcomes cannot be revised by replay. The bounded sample window retains source
run references, terminal event references, independent verifier references,
classification, declared costs and dependency fingerprints. Health persistence
uses evidence redaction; raw arguments, contexts, results and error messages are
not copied. Failed/unknown observations carry `remine='failure_or_unknown'`;
mining consumers must retrieve retained original evidence and cannot treat these
as successful exemplars. Scope/run retention checks guard observe, explain and
admit; a retention revocation refuses access/admission.

`explain(id).versions` exposes total observations, retained samples, latest
same-variant/same-dependency counts, missing coverage, policy, confidence bounds,
comparison and quarantine reason. Dependency fingerprints include pinned
capability versions and injected provider identities. Unknown variants stay
explicit; they cannot establish a cost comparison. Host provider revisions must
identify their supported contracts. Changes in current schemas/applicability
reported as `current=false` with evidence quarantine immediately. Candidate and
active states are both subject to quarantine; later activation, rollout and
rollback cannot bypass it. No automatic recovery or version switching occurs.
Healthy prior versions remain available through the registry's qualified rollback.

Failure/unknown decisions require `min_samples` and a Wilson lower proportion
bound at least the configured rate. Three failures out of three meet default
failure policy. The bound is inspectable, not proof that runs were independent or
representative. Canary/current versions compare against the pinned previous
version by task variant. `cost_per_verified` includes the sum of all observed
attempt costs divided by independent verified outcomes; missing cost coverage
prevents regression decisions. Cost confidence uses Hoeffding bounds on bounded
mean attempt cost and verified fraction, with `alpha` split between those bounds.
A comparison requires samples in both cohorts and a finite baseline upper bound;
only a candidate lower cost-per-verified bound above `cost_ratio` times that upper
bound triggers quarantine. Nonrandom routing or changed task mixtures can violate
statistical assumptions; those assumptions and counts remain explicit. Latency is
reported with counts and totals and never independently triggers quarantine.

Retention is finite: at most `window` samples per version, `max_groups` observed
version groups and `max_runs` project run receipts plus pending reservations.
Capacity is reserved before effects and exhausted capacity refuses new admission.
Receipts are compact hashes but are never silently evicted, so old failures cannot
be recounted. These limits require an explicit host archival/migration procedure
for continued operation; increasing limits is a deliberate host configuration
change. This module does not supply an unsafe reset or automatic health recovery.
