# Process recognition and alignment

BRAIN-26 implements `mining.recognize.find(request, context, scope)` and
`mining.align.compare(traces, ast_indexes)`. These are privileged host analysis
APIs, not capabilities to inject into generated Lua. They never execute source,
candidate functions, models, or workflow steps. Every result has
`activation_eligible=false` and an unresolved applicability checklist.

A **trace** is `{id, scope, revision, source_ref?, events}`. Events are actual
native evidence envelopes or normalized `imports.read` records. A **step
occurrence** is an observed invocation, preserving correlation, step, parent and
attempt IDs. Explicit workflow step occurrences and workflow start metadata are
also retained. Matching a step's name alone proves nothing about its effect.
A **fragment** is a contiguous pairwise region of matching observed invocations;
it is not executable code or proof that surrounding effects can be discarded.

## Host integration

```lua
local recognize = require('mining.recognize')
local candidates, err = recognize.find({
  text = 'identify people who have not responded',
  trace = reference_source, -- optional; omitted means retrieval-only suggestions
  ast = reference_ast,      -- optional mining.ast.index output
}, {
  scope = project_scope,
  corpus = selected_sources, -- bounded host-selected array; no implicit history scan
  authorize = function(scope, operation)
    return host_current_source_permission(scope, operation)
  end,
  validate = function(source, scope)
    -- Check source ownership, retention/tombstones and exact current revision.
    -- This is an authoritative, side-effect-free host check, not evidence claims.
    return host_source_is_current(source.id, source.revision, scope)
  end,
  load = function(source, options)
    return recognize.native(source.run_id, options.scope, bog.db)
  end,
  capabilities = current_capability_descriptors, -- optional map keyed by id
}, project_scope)
```

Each selected source has `id`, `scope`, `revision`, optional `source_ref`, `ast`,
`bm25_score`, `code_hash` (required to associate an AST), and either `events` or loader-specific identity such as `run_id`.
The request trace also passes `validate`. Loader callbacks receive a maximum
observation count of 512. `native(run_id, scope, db)` reads at most 513 persisted
rows (one sentinel), checks authoritative ownership and tombstones on that same
connection before/after reading, and surfaces persisted capture gaps. It does
not read artifacts. Provide a current revision rule through `validate` (for
example a host source revision or persisted event watermark); a fixed `true`
callback is only appropriate in immutable synthetic tests.

Alternatively supply `retrieve(text, {scope, limit=32, mode='text'})` instead of
`corpus`. It returns `{sources={...}, coverage={backend=..., ...}}`. This trusted
port MUST partition retrieval by the admitted scope before querying, rather than
returning cross-project hits to be filtered. It can call the shipped scoped
`memory.search`/port search and map validated source references to trace sources.
The callback options use the actual memory API's `mode='text'`; `mode='bm25'`
would be unsupported. A concrete adapter maps memory hits to authoritative sources:

```lua
retrieve = function(text, options)
  local page = port:search(text, options) -- already bound to this scope
  local sources = {}
  for _, hit in ipairs(page.hits) do
    sources[#sources+1] = {
      id=hit.source_id, revision=hit.revision, scope=hit.scope,
      source_ref=hit.source_ref, run_id=host_run_for(hit.source_ref),
      bm25_score=page.backend=='gestalt' and hit.score or nil,
    }
  end
  page.coverage.backend=page.backend
  return {sources=sources, coverage=page.coverage}
end
```

`validate` must recheck the memory revision and underlying evidence source, while
`load` uses the bounded native reader above (or an equivalent scoped import page).
Memory's BM25/scalar filters and local literal fallback retain their actual
coverage. No semantic/vector endpoint is invented: `semantic_available=false`
and `vector_available=false` remain explicit. BM25 only breaks structural ties.
Source-backed local corpus selection is useful even when different wording
would prevent literal recall. There is no automatic upload, indexing or history
import. An unavailable injected retriever returns `retrieval_unavailable`; it
never silently widens access through a fallback.

Admission precedes retrieval and loading, runs after each external retrieval or
load, and is checked again before return. Current source validation runs before
loading, after loading, and for all admitted sources after callbacks complete.
An inherited invocation scope also constrains admission. Source authority checks
are trusted, side-effect-free host code; callback-provided evidence never grants
scope. Policy revocation, stale revisions and tombstones must be reflected by
these host checks. Retention expiry becomes authoritative deletion through the
existing retention sweep. No cache bypasses those checks.

Import records can be supplied directly from an explicitly bounded host query
of the selected import scope/session. `imports.read(scope)` currently reads the
whole scope; do not use it as a production bounded loader. The test uses it only
for its one-record synthetic scope. Preserve imported `source_refs` (including
observed variants), representations and source observations. Boggart `historical.*` imports retain steps, branches and context observations,
but their admissions/outcomes remain imported and unverified. Imported tool names
and output text do not establish capability revisions, effects, native success,
or lineage, so they remain unknown and cannot drive a proven process match. They remain tentative workflow suggestions;
up to four imported invocation occurrences per candidate can also appear as
`tentative=true` fragment suggestions with zero structural coverage. These are
observed operations to investigate, not name-based equivalence claims.

## Results and limits

`find` returns an array sorted by observed alignment score, then ID. It also has
`coverage` and `activation_eligible` fields. Entries distinguish `kind='workflow'`
and `kind='fragment'`, with source revision/reference, rank, evidence, alignment,
coverage, unknowns, ambiguity, and applicability. At most 32 sources and 64
results are considered. Retrieval truncation is explicit; no complete recall is
claimed. Without a reference trace, suggestions have zero structural coverage
and `request_structure_unavailable`. Text is bounded to 4,096 bytes.

Alignment accepts 2–8 traces, each capped at 512 events and 128 invocations.
It uses bounded pairwise LCS against the first trace, matching exact observed
admitted capability ID, version, target and known effect. Different literal
arguments/descriptions do not prevent grouping. Different effects/versions do
not match; incomplete whole alignment records `observed_process_difference`.
Contiguous runs become separate regions, so intervening unmatched effects never
vanish inside a claimed fragment. Several traces yield pairwise regions, not a
claim that every region is shared by every trace. Repeated identical effects can
have multiple optimal mappings; `ambiguity.mapping_possible` conservatively flags
repeated signatures or an optimal-path tie. Unique observed mappings return false,
while `semantic_equivalence='unknown'` remains separate. The mapping flag is a
conservative warning, not an exhaustive proof of uniqueness for arbitrary code. The algorithm
does not certify determinism, semantic equivalence or source-level code regions.

`compare` returns `{common_regions, variants, bindings, evidence, unknowns}` plus
normalized traces, ambiguity and coverage. Branch values (including false),
context observations, loop/step occurrence IDs and provenance remain attached.
All unobserved paths are unknown, even when one branch was observed. AST indexes
whose exact `source_hash` matches the trace's host-validated `code_hash`
supply source/version/structure provenance and bounded dynamic-region warnings;
Matching AST structure breaks otherwise equal observed-effect sequence ties;
different predicates/structure add an applicability conflict. Missing source
association disables this structural signal. Lexical def-use and structure
hashes never prove runtime lineage or effects.

Optional native `observation.dataflow` annotations use
`payload={source='explicit_annotation', links={producer=<correlation_id>,
consumer=<correlation_id>, output=<pointer>, input=<pointer>}}`. A binding survives
only when both occurrences exist and a succeeded producer terminal precedes the
consumer start. Provenance remains `explicit_annotation`, not a verifier claim.
Pointers are retained as authored, not resolved against redacted/artifact data.
Other link shapes, imported source pointers, missing lineage and equal values do
not create bindings. Bindings are per trace and are not rewritten through an
ambiguous alignment. Compilation still requires independent binding checks.

Failures use `nil,{code=...}` (`invalid_context`, `invalid_request`, `scope_denied`,
`request_source_unavailable`, `retrieval_unavailable`, `corpus_required`,
`source_changed`, `invalid_trace`, `invalid_event`, `invalid_ast`, `trace_limit`,
`scope_mismatch`, or native `source_unavailable`). Host callbacks are trusted
functions, but their failure is refused rather than executed as candidate code.

## Relationship alignment

Each `alignment.variants[i].relationships` contains `bindings`, `branches`, and
`contexts`, each with `status='compatible'|'different'|'unknown'` and evidence-bearing
`comparisons`. Its `mapping` names reference-to-candidate invocation occurrences.
These statuses describe observed relationships only, not semantic equivalence.

Binding comparison requires an unambiguous pairwise occurrence alignment and a
single explicit annotation for the same mapped consumer/input on each side. A
mapped producer or output-pointer difference is `different`; missing, duplicate,
unmapped or ambiguously aligned annotations are `unknown`. A known difference
adds `binding_relationship_difference` to workflow applicability conflicts and
reduces its ranking score by 20. Identical invocation coverage cannot hide a
different producer. Candidate `compatibility.bindings` exposes this distinction.

Branches align by unique explicit `links.site` annotation identity. Opposite
observed scalar outcomes become `observed_branch_outcome_variant`, while repeated
sites (including loops without sufficient branch occurrence information), imports
and missing site identity remain unknown. An outcome variant is not automatically
a different process; unobserved paths remain unknown.

Native resolved context observations align by unique `payload.provenance.key`.
The comparison distinguishes source identity/revision, provider revision, direct
context dependency keys/revisions, and mapped capability dependencies from the
ordinary resolved value. Known dependency changes become applicability variants
(`context_dependency_variant`), not automatically different processes. Scalar
value changes are separately reported as `value_status='different'` and do not
create dependency conflicts. Missing revisions, repeated keys, imported context,
capability invocations outside the mapping, structured value equality, nested
context dependencies, or more than 64 direct dependencies/capabilities remain
unknown. Cached contexts use the actual cached dependency/capability metadata.

Each common region carries `relationships.bindings` for incident bindings, with
`boundary_dependency=true` when a binding extends beyond that region. Its branch
and context comparisons are explicitly labelled `control_context_scope='trace_pair'`:
the adapter does not invent exact source-region localization from event order.
Compiler consumers must retain those boundaries and unknowns. Work remains
bounded by the existing trace/event/occurrence limits and the 64-entry direct
context-dependency cap; no recursive dependency traversal is performed.
