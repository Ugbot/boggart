# Ordinary request routing

A trusted host enables learned routing per session or turn by supplying
`session.learning` or `api.run_on(..., {learning=configuration})`. Fresh requests
then enter `route.request` → `skillrouter.learned` → `learning.route.run` before
specialist dispatch. Resumed turns and sessions without configuration preserve
the previous API behavior. Model endpoint resolution and `find_skill` are unchanged.

```lua
local configuration = {
  project = 'project-scope', registry = learned_registry,
  authority = current_authority, ledger = current_quota_ledger,
  context = { call_1_args = {recipient = current_recipient} },
  catalog = {{
    id = 'followup', scope = 'project-scope',
    terms = {'follow up', 'chase', 'missing replies'},
    required = {'call_1_args'},
    applicability = function(request, binding)
      -- Host-owned, conservative intent and current-input checks.
      return task_is_applicable(request, binding), 'host:applicability-evidence'
    end,
  }},
  planning = {capability='model.plan', version='1', max_tokens=512},
}
local message, status = api.run_on(session, ordinary_request, sink, {
  learning=configuration,
  context=current_context, -- optional per-turn override
})
```

The host supplies a real BRAIN-30 registry, current authority and qualified catalog
contracts. A catalog is a retrieval index, not permission or activation. Registry
selection revalidates evaluation, source/dependency qualification and current
admission, then durably pins the logical run. Each entry's ID must name a registry
procedure. A fragment can be indexed only when it is independently executable as
such a registered, evaluated procedure. No source, argument defaults or authority
are reconstructed from the catalog or historical evidence.

`learning.route.select(request, context, configuration)` returns
`{workflow, version, binding, evidence}` or
`{fallback='model_planning', reason, terminal, evidence}`. `execute(selection)`
starts that private decision exactly once, through registry/workflow start.
`run` returns `handle, selection, error`; failed admission returns no handle.
The public selection is descriptive: editing it cannot retarget execution or
clear a denial. Plain context tables are copied; project, registry and authority
identities are captured per decision. Live registry revocation still applies.

Retrieval scans at most 32 catalog entries, each with at most 64 short terms;
requests are bounded to 4096 bytes. Local matching is case-insensitive substring
matching against host-authored vocabulary, including paraphrase terms. It makes
no semantic equivalence claim. Optional `configuration.memory` accepts an existing
scoped `memory.open` port. Routing invokes `memory:search(request, {scope=project,
limit=32, mode='text'})` and joins same-scope retained `source_ref` hits to catalog
entries. Backend/provenance/coverage are retained; Gestalt availability is reported
by the port. Missing semantic coverage is explicit. Retrieval never pretends
ordinary prose is an observed execution trace for BRAIN-26 recognition.

Required inputs must exist in current injected context before applicability.
Callbacks return exactly `true, nonempty_evidence_reference` to accept; multiple
applicable entries cause visible ambiguous fallback, regardless of scores. Each
callback receives a private copy, has a 50,000-Lua-instruction bound and runs under
an authority denying all ordinary capability calls. No model judgment is used.
Catalog size bounds aggregate callback work. Trusted callbacks must remain
synchronous and avoid raw host I/O; Lua instruction accounting cannot interrupt a
blocking native function. The optional memory port must have its normal host
capability authority, timeouts and budgets configured. Its one retrieval call and
coverage are recorded separately from zero model recognition calls.

Concrete values, functions and provider tables retain context runtime behavior.
Each provider receives a fresh per-decision wrapper, including metatable-bearing
provider tables; wrapping preserves enumerable provider metadata and never rewrites
the caller-owned resolver. Providers resolve only inside the chosen workflow; their resolved values join a
cumulative applicability binding and are checked before the learned body receives
them. Guards that accept an unresolved provider must explicitly distinguish that
pending state from its eventual concrete value. A failed binding check sticks for
subsequent admission even if a provider ignores a nested resolution error. Provider
implementations themselves remain trusted host code and use ordinary capability
admission. Registry qualification must cover their identities and supported inputs.
Missing required keys never receive historical arguments. Opaque objects/closures
retain identity, so hosts remain responsible for their external mutable state.

No-match, missing-input, ambiguity and retrieval-budget decisions execute a real
Lua workflow containing a `model_planning` step. It resolves current inputs and
calls the pinned planning capability with `{request, context, reason, max_tokens}`.
Envelope names cannot collide with user context keys. The child authority narrows
to that capability, enforces the token ceiling and permits one capability call per
planning decision. Its quota ledger must be supplied as `planning.ledger` or the
configuration's `ledger`, matching inherited quota authority. The capability must
provide token estimation, `bounded={tokens=true}`, provider ceiling enforcement
and actual usage; missing accounting refuses execution. No legacy chat loop is
used as an unbudgeted fallback.

Registry refusal, failed or denied runtime admission, cancellation and uncertain
effects never retry through another route or planner. `api.run_on` returns the
workflow status, appends its result (or status/error) to the transcript, checkpoints,
and shows `[learning fallback: reason]` when planning was selected. The live handle
is `session.learning_run`; suspended workflows remain available there for explicit
host resumption. `session.learning_selection` retains routing evidence. Recognition
evidence uses the normal redacted evidence recorder; unavailable persistence is
reported through its capture error rather than claimed complete.

`tests/learning_route.lua` uses synthetic capabilities and a genuinely compiled,
evaluated and promoted fixture. It covers current recipients, changed intent,
missing inputs, ambiguity, scope, live denial, provider checks, private pins,
mutation resistance, bounded judgment and planning, memory scope and actual API
request routing. No real messages or paid model calls occur.
