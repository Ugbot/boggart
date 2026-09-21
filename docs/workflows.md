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

`resolver:resolve(key, request) -> value, provenance | nil, error` uses only
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
