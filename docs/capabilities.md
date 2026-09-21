# Versioned capabilities

`capability.register(descriptor, runner)` registers one immutable `(id, version)`
and returns a descriptor copy or `nil, error`. `capability.resolve(id, version)`
requires an exact nonempty version string and returns a copy or `nil, error`.
There is no implicit latest-version substitution. Existing Boggart and Station
names remain capability identities; registration does not require a remote service.

`capability.call(context, id, version, args)` invokes through the common policy
and quota gate and returns an outcome:

```lua
{status = "succeeded", result = {answer = 42}, usage = {tokens = 12},
 receipt = {invocation_id = "host-generated", id = "model.answer", version = "1",
            target = "worker", effect = "read", dispatched = true,
            status = "succeeded", execution = {job_id = "provider-job"}}}
```

Other statuses are `failed`, `cancelled`, and `uncertain`; errors have `code`,
`message`, and `retryable=false`. Artifact references can replace a large result
via `artifacts`. User results are never interpreted as outcome metadata: a table
with its own `status` field, numbers, booleans, and nil results remain values.
Failed version resolution and admission have `receipt.dispatched=false`.
A raised error or timeout after dispatch of a `write` or `unknown` capability
is uncertain unless the trusted adapter explicitly supplies `effect_disproven=true`.
Cancellation requests do not prove cancellation. Invalid output after a write
also cannot disprove its effect. Nothing here automatically retries, falls back,
or compensates an uncertain invocation.

The descriptor fields are:

| Field | Contract |
| --- | --- |
| `id`, `version` | Required nonempty strings; exact immutable identity |
| `input_schema`, `output_schema` | Optional validated schema subset below |
| `input_validator`, `output_validator` | Optional trusted functions `(value) -> true` or `nil/false, reason`; replace the corresponding schema validator |
| `effect` | `pure`, `read`, `write`, or conservative default `unknown` |
| `requires_approval` | Explicit approval requirement; unknown effects also require approval |
| `resources` | Trusted `(args) -> resource attributes`, evaluated by policy at admission and rechecked after approval |
| `estimate` | Trusted `(args) -> {metric=amount}` reservation estimate |
| `bounded` | Trusted provider adapter assertion `{tokens=true, monetary_micro_units=true, ...}` |
| `target` | Informational execution target, default `local`; adapter owns actual dispatch |
| `cancel` | Optional trusted host cancellation callback; not automatically invoked |
| `reconcile` | Optional trusted `(args, execution)` callback used by explicit host reconciliation and opted-in durable recovery |
| `reconcile_estimate`, `reconcile_bounded` | Separate estimate/enforcement contract for reconciliation-query usage; original-effect usage is historical |
| `revision`, `provider_revision`, `source_revision`, `cache` | Host revision labels and explicit `cache='result'` eligibility used by [runstore](runstore.md); writes are ineligible |

A runner receives `(args, execution)` where execution contains the host-generated
`invocation_id`, `operation_id`, `target`, and `ceilings`. Durable execution gives
the original adapter a stable operation ID before its first effect. It returns `result, metadata` with
optional metadata `{status, usage, receipt, artifacts, error, effect_disproven}`.
Default status is succeeded. Provider-specific job IDs, cancellation acknowledgements
and reconciliation tokens belong in `metadata.receipt`. Registering a callback
is a support declaration, not proof of remote cancellation/recovery qualification.
Lua retains logical control flow; expensive work can be dispatched by the runner.
No workflow DSL, transport runtime, or closure serialization is required.

## Validation

Supported schema keywords: `type` (object, array, string, number, integer, boolean,
null), `properties`, `required`, boolean `additionalProperties`, `items`, `enum`,
`minimum`, `maximum`, `minLength`, `maxLength`, `minItems`, `maxItems`, and annotation
fields `title`, `description`, `default`. Constraints require their corresponding
explicit type. Defaults are annotations, never injected arguments. Strings use
**byte lengths**; Lua nil represents null and cannot represent a present null
object property. Empty tables are interpreted by the declared schema type.
Arrays must be dense with positive integer keys; objects require string keys.
Nonfinite numeric values fail numeric validation. Unknown schema keywords,
including `$ref`, `pattern`, `format`, combinators and union types, reject registration.
This is deliberately not full JSON Schema. Hosts needing richer schemas must
supply an explicit trusted validator; its correctness belongs to that host.

## Bounded usage

An estimate alone cannot authorize spending. Only a trusted adapter declaring
`bounded[metric]=true` can admit that non-call policy limit or quota. The adapter
must apply **every supplied ceiling before dispatch**, for example to a provider's
hard maximum token/cost parameter or a host-controlled bounded worker. Adapters
unable to enforce such a ceiling must not declare that metric. Arbitrary in-process
Lua/native code is privileged; the gate cannot prevent a lying host adapter from
spending, but it detects contradictory receipts and halts the ledger.

The gate reserves all inherited quotas once, passes the reserved metric ceilings
to the runner, and requires actual usage on successful bounded calls. Actuals
above ceilings fail and quarantine the authority; quota settlement durably records
and blocks overruns, including policies containing only hard per-call limits.
Unknown failed usage retains reservations; missing successful usage is refused
and quarantines the live ledger object. Recovery after unknown accounting remains
a host responsibility. A replacement custom runner cannot inherit a bounded
adapter's authority; reconciliation declares its own bounds. Cache reuse reports
zero new provider usage under current authorization and keeps historical usage
and artifacts separately. Multiple inherited limits take the minimum ceiling.

`quota_bounds` is an additive SQLite table recording new hard-limit reservations.
Existing tables and historical reservations are unchanged; historical reservations
without bound rows retain their prior settlement semantics. Shared quota bucket
usage still reconciles normally. The durable global overrun halt has no automatic reset.

## Legacy and ecosystem mapping

`capability.adapt(name, version, tools_generation?, metadata?)` or
`tools.capability(name, version, metadata?)` explicitly registers a legacy tool
using its bound registry generation. It preserves arguments and structured results,
original permission name, host resource extraction, and one admission/event pair
and quota reservation. Changed legacy entries are refused. Candidate tools reloads
do not automatically publish global registrations. Legacy adapters cannot claim
bounded provider metrics. CLI/model `tools.run`, `tools.call`, and `tools.get`
retain their string boundary. Fallback skips absent entries and can use a typed
`tool_not_found` from a non-uncertain call; arbitrary “is not connected” text and
uncertain write/unknown errors never authorize another target.

The source-reviewed AIbyWire `ToolSchema` concepts map as follows (no imported
runtime dependency or transport parity claim):

| AIbyWire concept | Capability mapping |
| --- | --- |
| `tool_id`, `name`, `description` | Existing registered `id`, optional display `name`/`description` |
| `input_schema`, `output_schema` | Same fields, supported subset or explicit host validator |
| `requires_approval` | Enforced mandatory approval |
| `is_async` | Preserved descriptive metadata; delegated job receipt belongs to the runner |
| `preconditions`, `effects` | Preserved GOAP fact metadata; **not** the effect-safety class |
| `capability` tags | Preserved descriptive tags |
| `cost` | Preserved metadata; actual enforced cost requires `estimate`/`bounded`/usage |
| `compensation` | Preserved metadata; never automatically dispatched |

Station and AIbyWire adapters can retain their existing IDs, target names and
provider receipts. Qualification of concrete transports, durable resume, and
provider cancellation is separate work. Inject a narrow calling function into
workflow/context Lua instead of exposing host registration or raw dispatch.

Regression suites: `tests/capability.lua`, `tests/invoke.lua`, `tests/quota.lua`,
`tests/luatool.lua`.
