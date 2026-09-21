# Lua workflow context

`context` supplies injected values and ordinary Lua providers to a workflow.
It does not register workflows, persist runs, or execute a workflow DSL. Those
interfaces belong to subsequent workflow/runstore work. No mandatory context
JSON schema is imposed; capability input/output validation remains at the
[capability invocation boundary](capabilities.md).

## Host construction

```lua
local context = require('context')
local authority = require('invoke').context {
  state = {mode='auto', guards=false}, -- illustrative trusted local fixture
}
local ctx = context.new(injected, defaults, authority, {
  run_id = 'run-123',
  capabilities = {['characters.lookup'] = '1'},
  source_revisions = {character = 'manuscript-revision-7'},
})
```

`context.new(injected, defaults, exec_context [, options]) -> resolver` requires
an opaque authority from `invoke.context`. The resolver does not inspect,
modify, or expose it. The optional fourth host argument copies exact capability
pins and source revision labels; later mutation of those option maps cannot
upgrade a pin or relabel a cached value. There is no implicit latest version.
Supplied run/source revision labels must be strings or finite numbers; malformed
labels and source revision maps are rejected during construction. Omitted labels
remain optional. Use a new resolver for every run, even when the same authority is reused.
`run_id` is a correlation label, not a shared cache namespace.

`resolver:resolve(key, request) -> value, provenance | nil, error, provenance` uses only
absent (`nil`) injected entries to fall through to defaults. False, zero, and
empty strings are concrete values. An injected provider returning no value does
not silently switch to the workflow default. Context keys are nonempty strings.
The maps remain live host-owned bindings; changing a selected binding or provider
revision invalidates this resolver's caches. Mutating a concrete record in place
requires the host to revise its dependent provider or start a fresh resolver.

The same workflow accepts either representation:

```lua
local function greeting(ctx)
  local character, err = ctx:resolve('character')
  if character == nil then return nil, err end
  return 'Hello, ' .. character.name
end

local concrete = {character = {name='Ada'}}
local retrieved = {character = function(ctx, request)
  local outcome = ctx:call('characters.lookup', {name='Ada'})
  if outcome.status ~= 'succeeded' then return nil, outcome.error end
  return outcome.result
end}
-- greeting(context.new(concrete, {}, authority, options))
-- greeting(context.new(retrieved, {}, authority, options))
```

Providers are `function(ctx, request)` or objects such as:

```lua
local providers = {
  character = {
    revision = 'provider-source-sha',
    cache = 'step',
    resolve = function(ctx, request)
      local characters, err = ctx:resolve('characters', request)
      if characters == nil then return nil, err end
      return characters[request.name]
    end,
  },
}
```

Object `resolve` is called as `resolve(ctx, request)`, without an object `self`.
A table's `resolve` field is reserved for the provider protocol; other tables
are concrete values. A function supplied directly is always a provider. A
function-valued context result can be returned by a provider without serialization.
Provider context offers `ctx:resolve` and `ctx:call`; it contains neither the
host authority nor a mutable capability manifest. Requests and returned values
retain ordinary Lua identity; credentials must be opaque host handles, and the
resolver does not clone, stringify, or persist resolved values.

`ctx:call(id, args)` returns the full capability outcome with `status`, `result`,
`error`, `usage`, `artifacts`, and `receipt`. Missing pins return a failed outcome
with `capability_unpinned` before dispatch. Providers own their outcome handling;
returning an outcome as a value does not implicitly retry or unwrap it. In
particular, uncertain effects are never automatically retried. Both provider
and optional cache-key callbacks execute within `invoke.with_context`, so direct
mediated calls also inherit the supplied authority from ordinary host Lua.
Narrower enclosing authority remains effective. Observers inherit that authority.
These are trusted injected host functions, not an OS sandbox: arbitrary host Lua
with native/global access is not made safe by wrapping it in this module.

## Explicit cache contracts

`cache` defaults to `none`. Only successful non-nil values are cached; false is a
successful value. There is no automatic retry, cross-run cache, TTL, or promise
that an external source stays fresh. Choose `none` when fresh retrieval is required.

| Lifetime | Behavior |
| --- | --- |
| `none` | Evaluate every time. |
| `run` | Reuse eligible values within this resolver only. |
| `step` | Also require a stable `request.step_id`, identifying the step occurrence. Missing identity visibly bypasses caching. |

Keys include request content, provider and source revisions, and enclosing
invocation authority identity. A narrower caller cannot retrieve a value cached
by a more privileged caller. Authority joins can conservatively reduce cache hits
for nested resolutions. Policy revocation is still enforced on subsequent actual
capability dispatch; opting into a cache explicitly allows reuse without dispatch.

Default request keys are structural: finite numbers, strings, booleans, nil, and
acyclic metatable-free tables with scalar keys. Table ordering is immaterial.
Lua integers use exact integer encoding, including values above 2^53; floats use
17 significant digits and a distinct type prefix. Consequently numerically equal
integer/float representations may produce separate entries. Structural caching
assumes the provider treats plain request data by content, not table identity.
Closures, userdata, threads, metatables, and cycles bypass caching with visible
`cache_reason='unstable_request'`. Opaque handles must not be represented as
ordinary structural request data: give them a metatable or an explicit host key.

A provider may supply `cache_key=function(ctx, request) return stable_key end`
to key otherwise unstable requests. It executes under the same authority and is
traced just like `resolve`; it runs on every lookup, including hits. Nil or an
unstable explicit key bypasses caching. False is a valid explicit key. The host
owns this equivalence contract: include every input/source distinction that can
change the result. Step identity and revisions are still included automatically.

Provider `revision` must be a string or finite number. When any selected provider
identity, implementation, revision, cache mode, or key callback changes, all
resolver caches are invalidated, including composed parent results. Source
revisions in construction options are fixed snapshots: a new source snapshot
requires a new resolver (or a revised provider). Changes to external data cannot
be inferred from an unchanged revision. Cached Lua values are returned by
reference; consumers must treat them as read-only to preserve cache meaning.
Concurrent equal requests are not coalesced and may evaluate independently.
An in-flight evaluation whose source generation changes returns its observed
value with `cache_reason='source_changed'` and cannot populate the newer cache.

## Errors and observations

Failure returns retain the existing `nil,error` pair and add a third, copied
metadata-only provenance record when a resolution was started. This preserves
observed invocation/dependency outcomes even when the provider returns nil or
throws; invalid keys rejected before resolution have no third record.

Missing context returns `context_missing`; invalid keys/provider configuration
return `context_invalid`; a cycle returns `context_cycle` with the full resolution
`path` such as `{'a','b','a'}`. Stacks are coroutine-local, so independent suspended
providers do not produce false cycles. Providers can compose by returning the
child's `nil,error` pair, preserving its typed resolution error.

Other provider-returned errors or exceptions become `context_provider_error` with
generic prose, avoiding accidental credential disclosure. Raw exception strings
are not copied into metadata. A benign profiling/coverage hook does not change
this typed error contract. Hook callbacks are tracked and their original function,
mask and count restored; actual enclosing hook failures remain sticky even when
a provider attempts to catch them. Because reinstalling a Lua hook resets its
hidden remaining count, every resolution conservatively charges one enclosing
count quantum, including concrete, missing and cached paths. This prevents
repeated short resolutions from starving a budget; it is not exact VM instruction
accounting. Enclosing instruction-hook failures propagate
instead of being converted to recoverable provider errors, consistent with the
invocation boundary. Such abrupt exits may have only a start observation.

Events `context:resolve_before` (provider evaluation/lookup) and
`context:resolve_after` (terminal resolution, including concrete/missing/error/cache
outcomes) carry schema version 1. Provenance returned with a value shares the
terminal shape: resolution ID, parent ID, optional run ID, context key, selected
source, source/provider revisions, value type, status, and cache outcome/reason.
Dependencies carry nested resolution provenance. Capability records carry exact
ID/version, status, invocation ID, and usage, correlating to capability events.
Direct calls made outside `ctx:call` retain their normal capability events but
are not linked into this convenience provenance list.

On a hit, `evaluated_resolution_id` identifies the original evaluation;
`cached_dependencies` and `cached_capabilities` describe its inputs/calls.
`dependencies` and `capabilities` retain any work performed during this lookup's
cache-key callback. Cached usage is historical, not a new charge. Events and
returned metadata are independent copies, so observer mutation cannot alter
cache eligibility or future provenance.

This module deliberately records metadata only: request bodies, resolved values,
closures, raw credential handles, and raw error messages are excluded. Host-owned
keys/revision/run labels must themselves be nonsecret. BRAIN-18 owns redacted
value/artifact persistence and durable evidence correlation; this module does
not implement a competing store or claim that evaluated values have been saved.

## Versioned workflow runtime

`workflow` runs ordinary Lua functions with conditions, helpers, loops and explicit
boundaries. Registration, activation and run handles are trusted host APIs.

```lua
local workflow = require('workflow')
workflow.register {
  id='follow_up', version='1', source=source_bytes,
  capabilities={['fixture.slack.replies']='1', ['fixture.model.report']='1',
                ['fixture.report.record']='1'},
}
local handle = assert(workflow.start('follow_up', {
  context={expected_people={'Ada','Ben'}, query={replies={'Ada'}}},
  authority=host_invocation_authority,
}))
local outcome = handle:snapshot()
```

Source-backed registration accepts exact Lua **text bytes**, optionally with
`source_hash` checked against SHA-256. `workflow.hash(bytes)` returns lowercase
SHA-256 hex. The text returns a function or `{run, defaults, verify}`; it is
instantiated freshly inside each run's restricted generated-code environment and
instruction budget. It reuses `tools.tool_env()` for ordinary Lua and safe coroutine
helpers, but rejects unversioned `tools.call/names`, `sys.*`, `gold.fs.*`,
`events.notify` and `os.getenv` routes. All effectful workflow-source operations
must use declared exact `ctx:call` capability adapters. Rejection stays a failed
run even if source catches it. This prevents a suspended source run from observing
a replacement in the mutable legacy-tool registry. Its lexical helper functions and upvalues belong to that source execution.
Source cannot access `require`, raw databases, host capability registration or
raw effect dispatch. Ordinary local computation remains available. Source text
cannot also supply host `run`, `defaults` or `verify` fields. Syntax is checked at
registration; source initialization and returned contract are checked at execution.

The alternate `register {id,version,run,defaults,verify,...}` path is explicitly
`source_kind='trusted_host'`. It has **no source hash** and does not prove closure
immutability: host closures can capture mutable state. Such closures/providers
are not portable mined packages. A label, `tostring(function)`, adjacent file hash,
or dumped bytecode is never presented as executable closure provenance. Concrete
opaque context values and external data retain ordinary identity; pinning code
does not freeze the external world. Host provider functions remain trusted.

Versions cannot be replaced. The first registered version becomes active;
`workflow.activate(id, version)` atomically selects an existing version for future
starts. `workflow.resolve(id, exact_version)` returns identity/manifest metadata.
Registration and returned descriptor mutation cannot change saved source or pins.
Descriptor and dependency-map metatables are rejected. An explicit `version` at
start overrides active selection. All declared `capabilities={id=version}` and
`workflows={id=version}` dependencies, recursively, must exist at start and remain
pinned. There is no implicit latest resolution. Activation is a host mechanism;
evaluation/promotion gates are owned by the later learning subsystem.

Injected binding maps and provider object configuration are snapshotted at start;
replacing their provider function/revision while suspended does not switch the
run. Function upvalues and external data cannot be frozen by Lua; changing data
behind the same pinned provider is allowed. Provider revisions in manifests are
host labels, never fabricated content hashes. Source-defined defaults are tied to
the source hash and instantiated with that source; their provider metadata is
added as each nested source is initialized. `manifest.providers.injected` holds
root injected providers; `manifest.providers.occurrences[path]` holds separate
`injected` and `defaults` maps for each root/nested execution occurrence. Arbitrary
context names never share a namespace with workflow identities. Host defaults are snapshotted at
registration. Concrete opaque handles are neither serialized nor cloned.

`start` executes immediately to completion or its first yield; `defer=true` leaves
it created. `handle:resume(...)` continues a suspended run and returns a snapshot
plus yielded values, if any. `handle:snapshot()` returns status, identity,
dependency manifest, steps, context provenance, explicit invocation receipts,
result and verification flag. States are created, running, suspended, succeeded,
failed, uncertain or cancelled. Terminal handles never restart. No replay,
automatic retry, disk persistence or crash resume is implied.

Workflow context provides:

- `ctx:step(site_id, fn)` runs ordinary Lua and preserves multiple return values.
  IDs combine workflow/version, execution thread, nested source-site path and
  occurrence number. Repeated loop sites and recursive/nested sites stay distinct.
  Site IDs are explicit author-owned nonsecret labels, not AST-inferred positions.
- `ctx:call(id,args,{required=false}?)` returns the complete capability outcome.
  Required calls are the default; failed/cancelled required outcomes remain sticky
  even when code ignores them. Uncertain calls always prevent successful completion.
- `ctx:resolve(key,request,{required=false}?)` preserves the resolver's two returns,
  including concrete false. Plain table requests receive the actual step ID in a
  copy. Scalar, function and opaque requests pass through unchanged; step caching
  may visibly bypass without a table step identity. Missing required context and
  failed required provider capability provenance prevent lifecycle success. Both
  current and cached dependency/capability provenance are inspected. Uncertainty
  prevents success even for optional resolutions and nil/error/throwing providers;
  the additive third return carries failure-path provenance.
- `ctx:workflow(id,{context=bindings,site=label}?)` executes a declared exact nested
  dependency under the same authority, budget and run. Omitted context inherits
  the parent's pinned injected bindings; child defaults remain its own.
- `ctx:yield(...)` suspends and receives values passed to the next resume.

Thrown step errors, ignored required failures and rejected/throwing verifiers
cannot become verified success. Exception prose is replaced by generic typed
errors. A verifier is `verify(ctx,result) -> true`; successful execution without
one has `verified=false`. This flag only records the local verifier result; it is
not evidence of independent held-out evaluation or automatic promotion eligibility.
Provider capability summaries preserve context's provenance; direct `ctx:call`
records keep receipts, usage and artifacts separately from user result values.

`handle:cancel()` makes cancellation terminal and stops subsequent handle resumes.
It does not claim a dispatched external effect stopped. Suspended calls/resolutions
retain incomplete records and `effects_incomplete=true`; no provider cancel,
reconcile, retry, compensation or coroutine close handler is automatically called.
Abrupt hook/runtime exits also mark pending call/resolution records incomplete;
absence of returned provenance never proves an effect absent. A nominally successful
run with unfinished child calls becomes uncertain. The host must reconcile
external jobs and owns resource cleanup. Cancellation is
cooperative while executing host code; a blocking native adapter cannot be
preempted by Lua. Retain the handle until needed reconciliation is complete.

The cumulative `instructions` ceiling defaults to `tools.LIMITS.instructions` and
must be finite and positive. It uses the reviewed composing count-hook and safe
coroutine helpers, preserves narrower invocation authority on resume, and remains
sticky if source catches budget errors. Accounting uses 1,000-instruction quanta
and conservative nested-hook charges, not exact VM counts or wall-clock deadlines.
This is not native process containment. No wall-time duration is claimed.

`workflow.current()` is a read-only host correlation seam returning current
run/workflow/version/step and attempt (currently always 1) on the executing
workflow coroutine. BRAIN-18 can capture it **at the invocation boundary before
observer dispatch**, including trusted-host direct mediated `sys`/`tools` calls. Source packages must
use version-pinned `ctx:call` instead. Event observers
run in separate coroutines and cannot infer their emitter using `current()`.
Arbitrary user-created child coroutines have no inherited correlation before
entering an explicit step; evidence integration must propagate that association
when supporting those direct calls. No competing persistence layer is introduced.

The executable package [slack_followup.lua](../examples/workflows/slack_followup.lua)
gathers fake replies, computes missing people locally, branches to an optional
fake model, and records a fake report. `tests/workflow.lua` injects only local
capabilities: it never sends a real Slack message or invokes a model account.
