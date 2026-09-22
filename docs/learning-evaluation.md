# Held-out candidate evaluation

`require('learning.evaluate').run(candidate, dataset, policy)` is a **privileged
host API**. It evaluates the actual `mining.compile.candidate` Lua source and
returns `{schema_version, outcomes, coverage, costs, regressions, eligibility,
reasons, evidence_refs, measurements}`. Invalid inputs and failed gates produce
`eligibility=false` with machine-readable `reasons`; they do not activate a
workflow or modify the input candidate. There is no execution callback that can
substitute a success transcript for running the source.

The module uses an isolated compiler-subset interpreter environment and adapter
map, without registering workflows or replacing process-global capabilities.
`coverage.production_runtime_qualified=false` is intentional. Eligibility means
this particular isolated evaluation passed; it does not certify a production
backend, authorize effects, prove every unobserved path, or activate a version.
A promotion consumer must check report identity, source authority, freshness,
coverage, runtime compatibility, and its own policy before activation.

## Dataset and separation

A dataset has `id`, `revision`, `examples` (a dense array, at most 1,024 entries),
and `costs`. Every example has nonempty string `id`, `task`, `session`, `variant`,
`trace`, `scope`, and `split='train'|'validation'|'heldout'`. IDs must be unique.
No task, session, variant, or `(scope,trace)` identity may cross splits. Here
`variant` identifies a related example family, not a broad domain such as
“follow-up”; related paraphrases stay in one split.

Every candidate `manifest.sources` entry must map to a training trace and scope.
Missing, duplicate, or held-out synthesis provenance fails before source
execution. The evaluator consumes compiler output; it never supplies validation
or held-out examples to synthesis. Origin labels and corpus membership are host
assertions, so callers must derive them from authoritative corpus lineage rather
than invent independent labels for copied examples. The source-authority checker
must verify retained source access and current revisions. The report preserves
the complete compiler manifest and unresolved compiler unknowns.

Training rows are never executed. Both validation and held-out splits are
required. Evaluation rows additionally contain:

```lua
{
  id='heldout-7', task='task-7', session='session-7', variant='family-7',
  trace='trace-7', scope='project-fixture', split='heldout',
  mode='fresh', applicable=true, evidence_ref='fixture:input-7',
  context={args={recipient='current-person'}, supported=true},
  expected={recipient='current-person'},
  costs={
    candidate={execution=2, failed_runs=0, fallback=0, repairs=0},
    baseline={execution=10, failed_runs=0, fallback=0, repairs=0},
  },
  baseline_verified=true, baseline_evidence_ref='fixture:baseline-7',
  -- Optional independently collected auxiliary measurements:
  measurements={fallback=0, user_correction_ms=0},
}
```

`expected` is only passed to host verifiers. Applicability receives current
context and `{id,task,session,variant}` metadata, never expected labels, costs,
or recorded outcomes. It returns a strict boolean. Selection is compared with
`applicable`; both false positives and false negatives reject eligibility.
Unselected examples do not resolve providers or execute source.

A `mode='fresh'` selected example runs the exact candidate source against its
current injected inputs and adapter map. “Fresh” means new execution, including
mock services; it does not imply live production data. Evidence references and
provider revisions must identify the input snapshot/freshness externally.

A `mode='recorded'` selected example instead supplies
`recorded={source_hash=..., observation={status=...,result=...,calls=...}}`.
Verifiers inspect this saved observation, but adapters and source are not run.
Recorded rows are always marked separately and make this report ineligible;
a matching source hash does not turn saved output into fresh proof. At least one
selected, applicable, fresh held-out execution is required.

## Trusted host policy

```lua
local policy={
  id='followup-evaluation', revision='1',
  applicability={id='followup-selection', revision='1',
    check=function(context) return context.supported==true end},
  source_authority={id='retained-sources', revision='1',
    check=function(sources, capability_pins, candidate_source_hash)
      -- Revalidate retained scope/access, exact source and dependency revisions.
      return true, 'fixture:source-authority-check'
    end},
  adapters={
    ['messages.send']={id='send-fixture', revision='1', version='3',
      isolation='mock', effect='write', model=false,
      call=function(args, metadata)
        -- Capture/simulate only; no real messages.
        return {status='succeeded', result={text='Done'}, usage={}}
      end},
  },
  verifiers={{id='recipient-and-task-invariant', revision='1',
    verify=function(observed, expected, metadata)
      local wrong=false
      for _,call in ipairs(observed.calls) do
        if call.id=='messages.send' and call.args.recipient~=expected.recipient then
          wrong=true
        end
      end
      return {passed=not wrong and observed.result.text=='Done',
              wrong_recipient=wrong, duplicated_effects=0}
    end}},
}
```

Adapters, injected providers, applicability, source-authority checks, and
verifiers are trusted host code. Their declared `mock` or `isolated` mode is an
integration contract, **not a sandbox for malicious host closures**. Supply
fixtures or independently isolated test services; never connect these callbacks
to paid models, real messaging, or private logs for an ordinary benchmark.
Verifiers must assert the actual task/effect invariants (including expected
number/type of effects), not model self-ratings or plausible output text.
The illustrative verifier above needs domain-specific completeness checks before
use outside its fixture.

Adapter `version` must exactly match the candidate capability pin. Every pinned
capability needs an adapter with `id`, `revision`, `call`, `version`,
`isolation='mock'|'isolated'`, and `effect='pure'|'read'|'write'`. Optional `model`
classifies model calls for measurement. The callback receives copied arguments
and `{example_id,mode,step}`; it returns a structured outcome with one of
`succeeded`, `failed`, `cancelled`, `denied`, `unavailable`, or `uncertain`.
Failures cannot be replaced by strings. Required-call failure remains sticky
even if candidate Lua ignores it; uncertain outcomes remain terminal uncertainty.

The evaluator captures arguments before dispatch and outcomes before exposing
them to source. It creates `receipt.invocation_id` values beginning `evaluation:`
for retained compiler dataflow annotations, with `evaluation_only=true` and an
isolation label. These IDs describe test observations, not production effects.
Each verifier receives separate plain-data copies, so a verifier or candidate
cannot rewrite captured intentions. Verifier exceptions, malformed verdicts,
wrong recipients, duplicate effects, and failed invariants reject eligibility.
Compiler-provided verifier checklist records never count as executable proof.

## Execution contract and limits

Source initialization and execution run together under a native allocator limit
and instruction hook. Defaults are 1,000,000 instructions, 8 MiB allocated
memory, and 256 calls/resolutions/steps/observations. Policy can set positive
integer `instructions`, `memory_bytes`, and `max_calls`, capped at 10,000,000,
64 MiB, and 1,024 respectively. Data is bounded plain acyclic data, with no
metatables, userdata, or executable return values. Lua source is at most
262,144 bytes. Failure to provide the native restricted allocator fails closed.

Source can use ordinary Lua control flow and the compiler's primitive helpers
(`assert`, `error`, `type`, `ipairs`, `pairs`, `next`, `tonumber`, `tostring`,
`select`). It receives `ctx:call`, `ctx:resolve`, `ctx:step`, and `ctx:observe`.
It receives no registries, `require`, loaders, `debug`, `coroutine`, protected
calls, filesystem, network, or process functions. The source must return a
function or a table containing only `run`. Source defaults, verification hooks,
nested workflows, and other source contract fields are refused. Yielding
adapters are refused. This is intentionally narrower than the general workflow
runtime; unsupported constructs cannot establish eligibility.

Context supports plain values, host functions with a matching
`example.context_revisions[key]`, and descriptors
`{revision='1', resolve=function(ctx,request) ... end}`. Resolution is lazy and
composable. Providers receive a resolver-only facade with `resolve` and `call`;
workflow methods such as `step`, `observe`, and `workflow` are unavailable.
A root workflow resolution copies a table request (or creates one for nil) and
injects the current synthetic evaluation `step_id`, overriding any supplied
value. Scalar requests are unchanged. Nested provider `resolve` calls pass their
request through unchanged, including nil and table identity; no new `step_id` is
injected. Returned data and recorded request snapshots are copied.

Provider capability calls return outcomes for local handling without accepting
workflow `opts`. Once the root resolution returns, its `required` setting applies
to failed calls anywhere in its provider dependencies; uncertainty remains fatal
even for an optional root resolution. Providers may recover nested missing-context
errors. Unhandled required root resolution failures remain sticky. A nil provider
result with an error is distinguished from a missing result; nonnil results ignore
a second return, matching production. Provider caching (`run`, `step`,
`cache_key`) is unsupported and rejected when resolved. Providers and adapters
must be synchronous. The compiler routes use single-result steps; multi-result
step composition and general authored workflow extensions are not qualified by
this evaluator. No worker effect boundary is used or certified.

## Reports, costs, and unknowns

`outcomes` records example identity, selection, mode, observation, verifier
versions/verdicts, and independently verified status. Observations include
captured calls, resolutions, steps, branch/dataflow annotations, status, error,
result, and measured monotonic `latency_ms` for fresh execution.

`regressions` counts wrong recipients, false success (execution reported success
but independent verification failed), wrong applicability, applicability false
positives/negatives, and failed selected examples. Counts are per example, not
per verifier. Applicability precision is defined only when selection is nonzero.
Duplicate effects use independently supplied verifier `duplicated_effects`;
multiple verifiers are combined by maximum per example, avoiding double counting.

`evidence_refs` binds dataset ID/revision and content hash, exact candidate source
hash, full candidate contract hash (including pins, source map, provenance and
unknowns), policy contract hash, adapter/verifier identities, source-authority
check, and example references. Host functions are represented by an opaque
function marker in content hashing: their code cannot be authenticated this way.
Hosts must change callback/provider revisions when implementations change and
persist the report with their trusted evidence system. This API does not sign
reports, persist them, or automatically prove that a host callback is independent.

All monetary/resource cost values use the one declared `dataset.costs.unit`.
Costs are **host-supplied accounting evidence**, distinct from observed adapter
usage and latency. Provide measured or explicitly synthetic values and their
provenance; do not interpret synthetic credits as billing estimates.

```lua
dataset.costs={unit='fixture-credit', horizon=10,
  candidate={discovery=1,imports=1,mining=2,synthesis=3,evaluation=1},
  baseline={discovery=0,imports=0,mining=0,synthesis=0,evaluation=0},
}
```

Both sides require every startup component and every evaluated row's recurring
`execution`, `failed_runs`, `fallback`, and `repairs` component. Missing, negative,
NaN, and infinite values remain explicit unknowns; they are not silently zero.
Baseline verification needs a boolean and an evidence reference per row. A failed
baseline outcome still incurs its costs, but does not enter the successful-outcome
denominator. All evaluated rows, including declined and failed examples, enter
cost totals: the host should supply zero execution only when actually appropriate.
Keep startup evaluation expenditure distinct from the recurring operating sample
to avoid double charging the same observation.

Costs report component breakdowns, known startup/recurring/total sums, unknown
paths, total cost per independently verified applicable outcome (undefined if
none), mean recurring cost per evaluated task, and amortized cost/total at the
requested positive integer horizon. With complete costs and positive recurring
savings, break-even tasks are
`max(0,ceil((candidate_learning-baseline_learning)/savings_per_task))`.
Zero/negative savings and incomplete evidence have an explicit reason and no
numeric break-even. These projections assume the evaluation task mix and costs
remain representative. `policy.require_savings=true` additionally requires
positive savings and total candidate cost no greater than baseline at the horizon.
Complete lifecycle costs are always required for eligibility.

`measurements` separately records known values and completeness for model
call counts, duplicate effects, observed adapter usage, latency, fallback count,
and user correction time. Unclassified adapters, absent usage, unmeasured
corrections, and absent duplicate-effect verification stay unknown. These auxiliary
unknowns are exposed for downstream gates; they do not invent zero measurements
or silently introduce additional eligibility policy.

Deterministic compiler and regression fixtures live in
`tests/fixtures/process_bench/followup.lua` and `tests/learning_evaluate.lua`.
Run the registered suite with
`env -u NO_COLOR ctest --test-dir build --output-on-failure -R '^learning_evaluate$'`
after the repository build recipe. Current-source developer checks may use the
isolated-profile test runner described in the ticket's verification report.
