# Shared local quota ledger

`quota.open(conn, clock?, {subjects={principal="host-identity"}}?)` opens a
ledger on a trusted native `db` connection and returns `ledger` or `nil, error`.
The clock defaults to `os.time` and returns nonnegative epoch seconds. Subject
bindings are copied at open; policy `subject` names a dimension in this host
configuration. Invocation arguments cannot choose a bucket identity. Use one
durable database for every local agent/run sharing a quota authority.

```lua
local ledger = assert(require('quota').open(conn, os.time, {
  subjects = {principal = authenticated_principal},
}))
local reservation, err = ledger:reserve(compiled, invocation_id, {tokens=200})
if not reservation then return nil, err end
if reservation.replayed then
  -- Recover the existing invocation; never dispatch it again.
  return recover_invocation(invocation_id)
end
-- Apply the reserved ceiling to the provider before dispatch.
local result, actual, outcome = dispatch_with_ceiling(200)
local receipt, settle_error = ledger:settle(reservation.id, actual, outcome)
```

`reserve(compiled, invocation_id, estimate)` reserves every policy quota before
dispatch. `calls` is the attempt metric: it always consumes one regardless of
caller usage values. Every other quota metric needs an explicit finite,
nonnegative estimate. Hard per-invocation ceilings in the compiled policy are
also checked against estimates. Longer-lived run budgets need an explicit host
policy or shared quota; a per-invocation limit is not a cumulative run budget. Values above 2^53−1 are refused to bound SQLite numeric accounting.
Use integral units (tokens, monetary micro-units) when exact accounting matters.

A reservation is `{id, status="reserved"|"settled", replayed, overrun, outcome?}`.
IDs are global within the ledger and must be host-assigned invocation identities.
Repeated reservation requests with the same policy revision, obligations,
estimates and host bindings return the existing receipt. Different requests
using the same ID fail with `conflict`. A replay is evidence of prior reservation,
**not authorization to dispatch again**; even an unsettled replay could have
already executed before a crash. Durable execution/recovery belongs to the gate.

`settle(id, actual, outcome)` reconciles the reservation in its original buckets.
Outcomes are `success`, `failure`, or `uncertain`. Calls are never refunded.
Successful cost reconciliation requires actual usage for every reserved cost
metric. Failed/uncertain invocations may provide known actual usage; missing
metrics retain their full reservation. Only trusted, authoritative accounting
can justify a refund. The first committed settlement wins; subsequent calls
return that receipt without modifying usage, even if their inputs differ.

Actual usage above a reservation is charged and produces `overrun=true`. The
ledger durably blocks **all new reservations** afterward, even in later windows
or unrelated scopes. This conservative halt needs host investigation and an
explicit administrative recovery/migration; there is no automatic reset API.
Hard-limit-only policies are also reconciled against their reserved amounts,
even when no shared bucket exists. The additive `quota_bounds` table records
these ceilings for new reservations. Historical reservations without bound rows
retain their earlier settlement semantics; no historical usage is invented.
The gate must stop work on this receipt and enforce provider ceilings to avoid
spending beyond reservations in the first place. Unsettled reservations remain
charged across crashes; there is no timeout-based refund.

Each bucket is identified by scope ID, quota rule ID, host-bound subject and
fixed epoch window start (`floor(time/window_seconds)*window_seconds`). Policy
revision, invocation ID, workflow and run do not identify buckets. Changing a
revision or restarting a workflow therefore cannot replenish an ancestor quota.
Rule limit changes use existing usage. Changing a rule's metric, window size or
subject dimension is refused with `rule_changed`, requiring an explicit host
migration. New scope/rule IDs create new authorities and are trusted policy
publisher decisions, never user-controlled reset mechanisms.

A persistent database-wide high-water time clamps backward clock changes.
Windows advance naturally with the clock; unused capacity does not carry over.
A late settlement modifies only its original window. Large forward clock jumps
can advance a window and the watermark will not move back; clock discipline is
an operational responsibility.

Every reserve and settlement uses `BEGIN IMMEDIATE`, checks/updates all buckets,
and commits atomically. Any statement or commit failure rolls back all changes.
The injected clock runs before the transaction. Transaction bodies call only
synchronous native SQLite methods and private plain-data operations, with no
Lua callbacks or coroutine yields. Callers must dedicate an idle connection to
this synchronous use; the ledger does not nest inside caller transactions.
Opening a ledger creates additive `quota_*` tables on that connection.

Errors are `nil, {code, message, retryable}`. `exhausted`, `limit`, `conflict`,
`rule_changed`, `overrun`, `invalid`, `unknown`, `overflow`, and `database` explain
refusals. SQLite busy/locked errors are retryable; no refusal authorizes an
unmetered effect. Connection failure and malformed input also fail closed.
SQLite uses the connection's configured busy timeout (native default 5 seconds).
After an ambiguous I/O/commit failure, recover by reusing the same invocation ID
and reconciling durable state before any effect; do not generate a new identity.

The database and ledger are trusted host objects, not capabilities exposed to
restricted generated Lua. Local SQLite does not implement cross-machine quota
coordination. The host must use shared authority or apportioned leases there.

`tests/quota.lua` covers two independent connections, live writer/read lock
contention (including failed commit), all-bucket rollback, statement failure,
restart, idempotency, subject isolation, backward clock, late refunds and durable
overrun halting. Lock tests deliberately hold one connection's transaction open
while the other attempts admission; they exercise actual SQLite lock conflicts,
not process-scheduling stress or a throughput benchmark.
