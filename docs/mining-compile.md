# Compiling observed processes

`mining.compile.candidate(alignment, options)` is a privileged host analysis API.
It returns `{source, source_hash, manifest, source_map, required_context,
verifiers, unknowns}`, or `nil, {code=...}`. It never executes supplied Lua,
providers, models, or capabilities and does not register or activate a workflow.
Its output is ordinary Lua accepted by `workflow.register{source=...}`. With no
`ast_indexes`, it crystallizes an observed native call sequence into initial Lua.
With `ast_indexes`, it preserves and parameterizes source-bound control logic. A host
must evaluate the candidate, revalidate source access and revisions, and apply
its activation policy before registration or promotion.

```lua
local ast = require('mining.ast')
local align = require('mining.align')
local compile = require('mining.compile')
local indexes = {assert(ast.index(source_a, '1')),
                 assert(ast.index(source_b, '1'))}
-- Each trace must carry its authoritative exact code_hash association.
local alignment = assert(align.compare({trace_a, trace_b}, indexes))
local candidate, err = compile.candidate(alignment, {
  ast_indexes = indexes, -- positional, matching align.compare's trace order
  parameters = {
    [1] = {[historical_literal_node_a] = 'query'},
    [2] = {[historical_literal_node_b] = 'query'},
  },
  -- Optional correspondence assertion; if supplied it must match every source
  -- ctx:call node in lexical order and every observed invocation occurrence.
  call_sites = {call_nodes_a, call_nodes_b},
  residual_capabilities = {['model.interpret'] = true},
})
```

For source-backed lowering, `ast_indexes` must contain actual source and exact source hashes/versions matching
alignment's source associations. The compiler reparses source rather than trusting
caller-provided nodes. `parameters` maps literal node IDs to current context keys;
it cannot replace capability IDs, context keys, observation identities, operators,
or arbitrary AST nodes. Node IDs refer to the supplied source's fresh index.
Parameter values are never inferred from equal historical values. Optional
`residual_capabilities` classifies existing calls for review; it creates neither
calls nor authority. Unknown options are refused.

The compiler requires 2–8 fully aligned traces with unique observed invocation
mapping and matching known capability ID/version/target/effect descriptors. Every
emitted capability call must have an observed successful occurrence in every trace,
in lexical order, with start and terminal evidence references. Missing effect
observations, incomplete capture, truncation, and imported unverified effects are
refused. This is deliberately stricter than recognition: a promising fragment is
not automatically a compilable complete workflow.

## Initial Lua from native invocation history

A workflow does not need to exist first. Record admitted native capability calls
and their explicit dataflow annotations, load the bounded native evidence through
`mining.recognize.native`, and pass actual `align.compare(traces)` output without
AST indexes:

```lua
local candidate = assert(compile.candidate(assert(align.compare(traces)), {
  residual_capabilities = {['model.report'] = true},
}))
-- Candidate is still inactive. After the host's evaluation/approval gates:
-- workflow.register{ id=..., version=..., source=candidate.source,
--                    capabilities=candidate.manifest.capabilities }
-- workflow.start(..., {context={
--   call_1_args={query=current_query},
--   call_2_args={style=current_style},
-- }})
```

The generated context keys are deterministic: `call_1_args`, `call_2_args`, and so
on in invocation order. Each resolves a current argument table, using the same
value/function/provider injection contract as an authored workflow. The compiler
never copies historical argument or result values into Lua. It copies each current
argument table, then overlays explicitly bound top-level input fields with the
fresh producer result or field. A stale injected value cannot override that
binding, and the injected table is not mutated. Every bound path is checked
against the current producer output before resolving consumer argument providers
or dispatching the consumer: intermediate containers must be tables, and the final
value must be non-nil. False and zero remain valid, and leaf types are not inferred
from historical examples. Whole-input bindings must produce an argument table.
Current argument tables are limited
to 1,024 top-level entries. A whole-input binding (`input=''` or `/`) uses the
producer result as the argument object and needs no corresponding current-context
key. Other partially or fully field-bound inputs still accept a current argument
table, which may be empty.

Source-free compilation requires successful native admission/outcome evidence,
known descriptors, unique non-overlapping invocation order, and no observed
branches or repeated step sites. Observed model calls remain explicit capability
calls with ordinary status guards. No source-free branch predicate, loop or local
transformation is invented. Repeated capability signatures remain subject to
alignment's ambiguity refusal. Unknown imported effects are refused.

Independent calls are allowed: for example, read current replies, independently
read the expected-person roster, then join both outputs in a later call. Unbound
later calls use their injected current arguments and retain
`input_lineage_unobserved`. Equal historical values never create a binding. Every
binding that is synthesized must have compatible explicit annotations across the
selected traces; the compiler validates producer/consumer order, existing native
annotation references, pointer shape and equality of the specifically annotated
observed values. Missing, contradictory, duplicate, redacted, unavailable or
unsupported binding evidence is refused. This comparison validates an asserted
link; it does not infer a link from equal values.

Input pointers support an empty root or one top-level identifier field. Output
pointers additionally support simple nested identifier fields. Slash and dotted
field paths normalize to the same structure; JSON Pointer escapes and numeric
array indexes are unsupported. The selected values must be available in bounded
inline evidence. Artifact resolution is not performed by the compiler.

Every emitted step is labelled `synthesized=true` and links to its native start and
terminal evidence. `manifest.compiler='trace-sequence-v1'` distinguishes this route
from `source-subset-v1`. Trace identities, scopes and source references are retained;
there is no invented original code hash. The generated function returns the last
invocation's result, explicitly marked by `last_invocation_result_synthesized`.
`surrounding_control_flow_unobserved` and `current_argument_bindings_synthesized`
remain unresolved. This is an inactive candidate for one observed sequence, not a
claim that all original task logic has been recovered. The parameter metadata is
compiler input/output; generated execution remains ordinary Lua, with no mandatory
workflow DSL.

The native fixture in `tests/mining_compile.lua` records real direct
`capability.call` invocations under `invoke.with_correlation`, without registering
any historical workflow. It then compiles and executes current inputs/providers,
including independent reads feeding a later join and whole-object binding.

## Supported source lowering

Source must return either `function(ctx) ... end` or `{run=function(ctx) ... end}`.
The supported subset preserves local declarations, table constructors, field and
index reads, scalar operators, conditions, returns, and `assert`/`type` guards.
It supports `for ... in ipairs(value) do ... end` with local table mutations, such
as a replied-person set and a missing-person list. Each loop gets a synthesized
1,024-iteration guard; nested loops also remain subject to the existing workflow
instruction budget. Provider resolutions, capability calls, and explicit
observations inside these loops are refused, so repetition cannot conceal effects.
Literal parameter substitutions inside loop bodies or iterators are also refused: a
substitution emits a provider resolution and obeys the same effect boundary. Resolve
a current collection before entering a loop instead.

Capability calls must be direct `local outcome=ctx:call('capability', args)`
declarations. They may be conditional, but every source call must have been
observed in the selected traces. Each is wrapped in a generated `ctx:step` that
checks the actual structured outcome's `status` and returns the outcome intact.
This preserves `.result`, `.receipt`, and current policy mediation. Failures stop
execution rather than trying another model or transport. The existing runtime's
permission-error classification is retained; it can be `failed` with
`permission_error` and `receipt.dispatched=false`.

Each source condition becomes an ordinary Lua expression inside a `ctx:step`.
Its source hash, node and span are retained; an observed outcome is never invented.
The same compiled condition can take a new branch on fresh inputs. Loops and
branch bodies are source-derived code, not a domain-specific template. Context is
resolved with the shipped `ctx:resolve` contract, including values, functions, and
provider descriptors injected through `workflow.start(..., {context=...})`.
`required_context` means required when the corresponding path executes, not an
eager requirement to resolve unused branch inputs.

Source `ctx:observe('branch', value, links)` and
`ctx:observe('dataflow', nil, links)` calls are retained in the supported bounded
annotation form. Structural string fields in links are limited to `producer`,
`consumer`, `output`, `input`, and `site`; pointer strings are simple field paths.
These annotations remain observations, not verifier claims.

`examples/workflows/compiled_followup.lua` is source to observe and compile. Its
Lua loops compare injected expected people with the current reply list. Only a
nonempty missing list delegates report drafting to a residual model capability.
It returns a report and current filename, with no external send or file write.
`tests/mining_compile.lua` compiles this source through actual `align.compare`,
then executes distinct inputs and a branch that avoids the model entirely.
Another fixture replaces historical recipients, filenames and private query
literals with injected current values and providers.

## Literal and dependency rules

Historical string literals must be parameterized. The only retained strings are
validated capability/context identities, bounded observation metadata, and narrowly
recognized program discriminants (`outcome.status` versus `succeeded`, or `type`
versus a supported Lua type name). Numeric literals other than `0` and `1` must
also be parameterized. Boolean and nil syntax remain program constants. Escaped,
long-bracket or multiline retained string identities are unsupported. Comments
are omitted. A literal cannot be preserved by renaming its context key to the
same literal. This is an allowlist of syntactic roles, not a secret blacklist.

Direct producer-result references in later call arguments require a unique
matching explicit observed binding in every trace. The compiler independently
checks the source local binding, producer occurrence, output field path, consumer
input field path, and annotation event reference. Empty output means the complete
result; `words` and `/words` identify the same simple field. Arbitrary JSON Pointer
escapes, array-pointer semantics, and artifact dereferencing are unsupported.

Derived arguments, such as a missing-person list constructed by loops, are
labelled `source_transformation` in `manifest.bindings`, with a source hash/node/
span. A bounded monotone dependency analysis follows local declarations, table
mutations, loop variables and enclosing branch predicates. These records do not
claim direct output/input equality: `transformed_value_lineage_unobserved` remains
in `unknowns`. Direct lexical-result bindings and derived relationships are
intentionally distinguishable in the manifest.

## Review and execution boundary

Every emitted step has a source mapping. Call steps include invocation evidence;
check steps include AST source evidence. Guard and loop limits are synthesized
compiler behavior. Capability versions are pinned in `manifest.capabilities`. Every occurrence of one
capability ID must agree on version, target and effect; conflicting per-site
descriptors are refused as `capability_pin_conflict` before constructing that map.
The manifest lists the selected trace identities/scopes and code hashes/versions,
and always has `activation_eligible=false` and `evaluated=false`.

The three required verifier records cover distinct-input behavior, effect safety,
and source authority/revisions. They are a review/evaluation checklist, not
executable verifiers or successful results. Source observations and alignment
unknowns are retained, including unobserved paths, missing implementation revisions,
residual model decisions, and the need for held-out evaluation. The compiler does
not prove semantic equivalence, infer source ownership, or freeze external data.
Source authority must be checked by the host again before evaluation/promotion.

Source is limited to 262,144 bytes and 12,000 AST nodes, 256 lexical bindings,
128 capability calls per trace, and bounded plain input data. These are input
ceilings; generated candidates must additionally satisfy the native Lua compiler
and its variable/resource limits, or compilation is refused. Cycles, metatables,
functions in analysis input, oversized data and excessive nesting are rejected.
Source-backed globals are limited to direct `assert`, `type` and iterator `ipairs` calls;
context aliases, extra closures, reassignment of local variables, outcome-table
mutation, arbitrary loops, effectful repetition and arbitrary Lua-to-DAG conversion
are unsupported. Local names beginning `_compiled_` are reserved to avoid collisions.
All selected traces must produce the same generated structural hash in either
route. Source-free binding analysis is capped at 128 annotations per trace.

Principal refusal codes include `unsafe_literal`, `invalid_parameter`,
`source_evidence_required`, `source_hash_mismatch`, `source_correspondence_required`,
`binding_evidence_required`, `binding_value_mismatch`, `binding_value_unavailable`,
`unsupported_binding_pointer`, `trace_control_flow_unsupported`,
`capability_evidence_required`, `capability_pin_conflict`, `incomplete_evidence`,
`incomplete_alignment`, `ambiguous_alignment`, `source_structure_difference`,
`unsupported_syntax`, `unsupported_call`, `effectful_loop_unsupported`,
`unsupported_option`, `resource_limit`, and `invalid_input`.

This first compiler uses deterministic trace-sequence emission and source lowering. It does not invoke an LLM
for compilation or implement candidate evaluation/activation. Source-bound checks
are useful despite their retained uncertainty; unknown observations alone never
supply executable decisions.
