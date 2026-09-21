# Boggart process learning implementation plan

> **For agentic workers:** Execute this plan task by task using the executing-plans skill. Steps use checkbox syntax. The user has authorized building; do not restart the design interview or request the same authorization again. Use subagents only when the user or applicable instructions explicitly authorize them.

**Goal:** Make repeated LLM-driven work progressively cheaper by recognizing its structure, producing inspectable Lua, and reusing verified steps with current context.

**Architecture:** Boggart owns local Lua control flow, workflow selection, policy, evidence and the learning loop. LLM Station supplies specialist tools and code intelligence; AIbyWire supplies delegated computation and durable execution; Gestalt supplies memory and advanced retrieval. All remain optional to running a local Lua workflow.

**Tech stack:** Existing embedded Lua/C host, SQLite, existing ZMQ and MCP adapters, Gestalt client, and versioned source packages. Native libraries are an optional extension route, not a replacement execution language.

**Status:** Approved direction from the design interview; implementation is in progress. Completed foundations are recorded in [implementation progress](../../implementation-progress.md) and checked below. This document specifies planned interfaces, not APIs already implemented. Existing audit results are baseline evidence, not acceptance results for new work.

## 1. Settled requirements

- Always Lua: every workflow and logical step is Lua, including a step delegating to a model, service, worker or DLL.
- Use ordinary functions, conditions, loops and composition. Do not invent a mandatory workflow DSL or enforce functional purity.
- Most context is injected. Concrete values, functions that retrieve context and composable providers are all valid; code may supply defaults.
- Long-running or computationally intensive work may be delegated. Lua retains the surrounding decision logic.
- Learn from previous steps/calls and available Claude/OpenAI log context, with provenance and explicit missing information.
- Use Gestalt for advanced memory/search and recognition where available. Local execution must remain useful without it.
- Mining supports both bounded background operation and explicit, directed jobs.
- Automatic activation is the default after evaluation gates; users can require review or disable it. Running workflows keep their starting version.
- Recognize workflows from ordinary requests; also support named invocation, buttons and scheduled triggers.
- Policy composition is restrictive: overrides can narrow, never exceed the applicable inherited limits. Include capabilities, resources, rate limits and budgets.
- Reuse existing ZMQ and MCP infrastructure. A transport is not itself the capability contract.
- Slack follow-up/reporting and novel character/timeline/cleanup/wordcount are the acceptance domains. No real Slack sends or edits to an actual novel are authorized by those examples.

## 2. Proposed implementation defaults and unresolved product choices

These are practical initial choices, not statements that the user specified every detail. Implement them as documented, configurable contracts:
- Shared SQLite quota buckets are scoped to policy identity across runs and agents. Fixed windows first; stricter token-bucket algorithms can replace this behind the same ledger interface when measured need justifies them.
- Provider cache lifetime is explicit; no implicit permanent caching. Injected values override defaults. Provider results carry revisions/provenance.
- Promotion needs held-out successful verification and no known effect-safety regression. Minimum sample counts, confidence thresholds and cost limits are configuration with visible defaults; do not invent a universal success-rate guarantee.
- Restrict generated/mined code through mediated capabilities. Trusted host Lua/native code has a different trust boundary. Instruction hooks and path globs are not an OS sandbox.
- Exact native ABI and Lua parser selection are bounded implementation decisions with experiments and acceptance tests in their tickets.
- Novel canon authority has NOT been settled. Initial timeline/cleanup workflows produce evidence and proposed changes, not autonomous canon mutation.
- The first useful release is local. Distributed workers, native plugins and full platform parity each have explicit qualification; they are not prerequisites for proving local process learning.

## 3. Current evidence and why the order matters

The audit documents are the source of current-state findings:
- [Boggart audit](../../audit-roadmap-2026-09-21.md)
- [Reproductions and verification](../../audit-evidence-2026-09-21.md)
- [Ecosystem review](../../ecosystem-brain-roadmap-2026-09-21.md)
- [Extension investigation](../../extension-research-2026-09-21.md)

On the existing macOS executable, 56 Lua suites passed, yet targeted probes reproduced nested permission bypass, an explicit allow overriding stronger restrictions, swallowed verifier failure, lost enclosing instruction limits, incomplete reload rollback, broken session listing and duplicate pre-call events. Source review also identified unbounded event callbacks, local control trust gaps and incomplete effect coverage. Therefore new regression tests must target those guarantees rather than treat the old suite as proof of safety.

Station source review found lossy capture, missing parameter/dataflow materialization and fail-open preconditions. AIbyWire has useful durable execution contracts but its Python idempotency path needs an atomic-claim check under concurrency. Sibling suites and a fresh native Boggart build were not run in that audit. Do not present source findings as reproduced sibling bugs or support claims.

Pre-existing changes include CMake, boot, complete, model/native files and TypeSafe/judge work. Preserve them. Scope commits to new work and review interactions explicitly.

## 4. Vocabulary and module ownership

| Concept | Meaning and owner |
|---|---|
| Workflow version | Immutable Lua source and dependency manifest; Boggart registry owns activation |
| Run | One invocation with current inputs and pinned versions |
| Step | Lua logical unit with stable source site and occurrence identity |
| Capability | Versioned effect/computation contract implemented locally or remotely |
| Context provider | Value-producing function/object evaluated under run policy |
| Invocation | One attempt to use a capability; has correlation and outcome |
| Evidence | Observed events, artifacts and provenance; not private model reasoning |
| Candidate | Generated/refined Lua awaiting evaluation |
| Applicability | Whether current context satisfies a workflow's actual assumptions |
| Promotion | Atomic change of active version after evidence gates |
| Fresh execution | New run against current inputs; effects execute anew |
| Resume | Continue the same logical run, reconciling uncertain effects |
| Cache reuse | Return eligible previous results after dependency/freshness checks |
| Delegated job | Bounded external execution with its own durable ID and retry owner |

New modules are split by responsibility rather than a single brain.lua: policy/quota/invoke, capability/context/workflow/runstore, evidence/imports/retention, memory/adapters, mining, learning, and extensions. Existing tools, callables, skills, routes, triggers and Studio surfaces adapt to those contracts rather than being rewritten wholesale. File ownership and exact planned paths are listed per ticket below.

## 5. Execution and context contract

Lua source is the canonical executable and searchable representation. AST indexes and metadata support analysis; they never replace source semantics. Record code hashes and dependency versions, including provider/capability identities. A pinned workflow is not a frozen external world: current data must still be resolved with explicit freshness and provenance.

Planned authoring shape (illustrative, not an already shipped API):

```lua
workflow.register {
  id = "follow_up",
  version = "1",
  defaults = { report_style = "concise" },
  run = function(ctx)
    local expected = ctx:resolve("expected_people")
    local replies = ctx:step("gather", function()
      return ctx:call("messages.list", ctx:resolve("message_query"))
    end)
    local missing = ctx:step("compare", function()
      return find_missing(expected, replies) -- ordinary local Lua
    end)
    return ctx:step("report", function()
      return ctx:call("model.report", {
        missing = missing,
        style = ctx:resolve("report_style"),
      })
    end)
  end,
}
```

The workflow package defines find_missing as a normal Lua helper. Messaging is an additional explicitly gated step in the full example; constructing a report does not imply permission to send. A function provider can retrieve current participants through ctx:call. Its resolved value is evidenced, while the closure itself remains executable Lua and is never pretended to be JSON.

Errors must distinguish failed, cancelled, denied, unavailable and uncertain effects. A timeout after dispatch is not proof that the effect did not happen. Each invocation has one terminal observation or an explicit incomplete record after a crash.

## 6. Policy and quota contract

Compute effective authority from all applicable root/user/project/workflow/run/agent/call scopes; the specific scope list can be sparse. Allows intersect, denies accumulate, mandatory approvals accumulate, hard ceilings take the minimum and every applicable rate bucket remains enforced. A child cannot rename a bucket to evade the parent. Capability hosts derive resource attributes; untrusted Lua cannot authorize itself by inventing a label.

Policy changes that revoke authority apply at subsequent effect admission even for a code-version-pinned run. Pins preserve program semantics, not irrevocable permission grants. Each invocation records the policy revision actually evaluated. A narrower child context may be returned to a caller without mutating the parent's context.

The quota transaction checks/reserves all applicable counters atomically. Count attempts before dispatch; reconcile bounded usage afterward. Database failure or ambiguous accounting refuses new effects. Reserve model/token/monetary limits conservatively; prevent spend beyond reserved limits via provider ceilings where supported. An overrun is recorded, stops further work and must not be hidden as a negative remaining estimate. Global limits across machines require a shared authority or apportioned leases; local SQLite alone does not provide distributed quotas.

## 7. Evidence, imports and memory contract

Events include schema version; source/provenance; run, step, parent, attempt and correlation IDs; code/capability revisions; arguments and results or artifact references; context resolution; observed branch outcome; monotonic elapsed duration and wall-clock time; policy decision; usage; verifier outcome; failure classification. Dataflow links identify which observed output supplied which input when known.

Use redaction before persistence, artifact size limits and explicit unavailable/redacted/truncated markers. Logs are evidence, never instructions to execute. Import available conversation messages/tool calls/results for context; do not require hidden chain-of-thought. Imported histories lack some observations and must retain that uncertainty.

Import adapters are selected for real format variants, with sanitized fixtures, checkpoints and content-derived deduplication. Source deletion invalidates or removes dependent index material. Gestalt indexes scoped references and features; local storage retains authoritative source evidence. Search hits always include source references and coverage. Index lag is visible.

## 8. Mining, evaluation and promotion contract

The loop is:
1. Snapshot a selected evidence corpus.
2. Retrieve candidates by semantics, AST features, capability/effect sequence and context.
3. Align multiple runs, retaining dataflow, branches, loops, corrections and variants.
4. Identify stable fragments and parameters; leave unresolved behavior as explicit model steps.
5. Generate inspectable Lua with source maps and applicability guards.
6. Evaluate on held-out tasks and independent invariants under isolated effects.
7. Promote automatically if configured gates pass, or queue for review/keep disabled.
8. Observe fresh runs, detect drift, quarantine or roll back, and remine failures as failures.

Retrieval similarity is not execution permission or proof of equivalence. Parameter binding uses current inputs. Unobserved branches remain unknown. Model synthesis is itself a traced, budgeted capability call. Historical success alone cannot validate a new parameter binding.

Measure total cost per independently verified outcome, model decisions per task, applicability precision, false success, duplicated effects, fallback, user correction time, latency and amortized break-even. Include failed attempts, mining, evaluation and model judgment costs. A workflow with fewer prompts but more expensive failures is not an improvement.

## 9. Integration and extension contract

Station adapter: reuse stationlink/llmstation and BSTAT; preserve ZMQ/MCP capability parity only where actually tested. Repair capture/forge in its own checkout and changeset. No blind transport fallback after an uncertain effect.

AIbyWire adapter: one delegated job ID, one retry/compensation owner, status/cancel/reconnect receipts. Do not try to serialize arbitrary Lua closures into a DAG. Delegate bounded jobs from Lua and interpret results in Lua.

Gestalt: extend the existing client; validate real capabilities before designing requests. Retrieval must enforce scope before ranking; post-filtering a leaked cross-project result is inadequate.

Lua packs: immutable versions, explicit host compatibility and capabilities, staged registration and atomic activation, no partial load. Native extensions: versioned C ABI, clear allocation ownership and thread affinity; untrusted or blocking modules run in a separate process. Native code in-process is privileged regardless of Lua policy. Keep old library generations loaded while pinned runs use them.

## 10. Milestones and release gates

| Milestone | Working result | Exit gate |
|---|---|---|
| M0: trustworthy composition | policy, quotas, gate and audit repairs | targeted bypass/verifier/budget/reload regressions pass |
| M1: local vertical slice | ordinary Lua with injected context, model-capable steps, pinned versions and evidence | two different Slack-shaped fixture inputs run correctly, no daemon needed |
| M2: recoverable evidence | imports, provenance, recovery, retention and scoped memory | repeat imports deduplicate; crash/uncertain-effect tests avoid duplicate effects |
| M3: learning proof | structural recognition, compilation and held-out evaluation | a new input runs verified with fewer model decisions and measured total cost |
| M4: usable automation | promotion/rollback, request routing, drift, buttons/schedules and product examples | user can inspect, disable and recover; effect failures are visible |
| M5: modular ecosystem | versioned Lua packs and qualified adapters | dependency pinning and transport/recovery contracts pass |
| M6: release qualification | clean install, migration and product benchmark | full cycle passes on fresh build; support claims match actual evidence |
| Native expansion | measured native use case and versioned ABI | each claimed platform and crash/isolation contract tested independently |

M1's Slack-shaped fixture lives with the workflow-runtime task. The full messaging/reporting product ticket adds recognition and recovery later. M3 can use local imported fixtures without Station forge repairs or AIbyWire; those are parallel integration branches. Native expansion is optional to M6.

No calendar promises are attached before M1 measures integration effort. Execute the resolver's ready tasks in dependency order, prioritizing M0 then the shortest local learning loop. Each ticket is an independently reviewable deliverable, not an estimate of a single sitting.

## 11. Existing tracker relationship

BRAIN is the implementation programme for this interview. BCALL-1 covers spawned skill lifecycle; BRAIN's composition fix supplies the common verification guarantee but does not silently claim all spawn wiring complete. BCALL-3 covers cost ledger/compile trigger; BRAIN evidence/evaluation/mining implement the expanded process-learning contract and should link completion evidence back when scope is genuinely satisfied. BCALL-2/-4 remain related skill capability work.

BSTAT is existing Station transport work; BTEAM covers principals, shared scope and memory work; BPROJ covers project contexts; BSTUD covers Studio improvements; NERVE covers AIbyWire foundations. Keep those projects' status intact. Tracker dependency edges only support one project, so cross-project relationships are explicit references, not fake blocking edges.

## 12. Execution and verification protocol

For each code ticket:
- [ ] Read the named files and applicable repository instructions; preserve unrelated dirty work.
- [ ] Add the specified failing regression/scenario using fixtures and deterministic clocks/services where appropriate.
- [ ] Implement the contract and error paths in that ticket; register new Lua suites in CMake.
- [ ] Build and run its targeted suite; attach real test references and logs to tracker acceptance criteria.
- [ ] Run affected existing suites and integration checks, inspect the diff, and document public contract changes.
- [ ] Record acceptance results only after actual runs. Close only when all criteria pass; commit only scoped files when committing work.

Boggart's existing CMake test harness invokes ./boggart --eval tests/<suite>.lua with per-suite temporary profiles. New suite names below are planned and become runnable after their ticket registers them. Configure/build through the existing build tree when dependencies permit:

```sh
cmake -S . -B build
cmake --build build --target boggart
env -u NO_COLOR ctest --test-dir build --output-on-failure -R '^(policy|quota|invoke)$'
```

Use the appropriate per-ticket regular expression. The full qualification run is env -u NO_COLOR ctest --test-dir build --output-on-failure after a fresh build and required test isolation. Socket tests need loopback permission; report sandbox failures separately from code failures. Do not run unreviewed fixtures against real accounts or the normal user state. For new native/Studio/sibling tests use their verified repository build recipes, record exact commands in the ticket before marking pass, and do not claim unrun platforms supported.

## 13. Task catalogue

The catalogue below is also published verbatim as task descriptions and acceptance criteria in the devtools tracker. Dependencies reference actual BRAIN keys. All implementation criteria start unrun. Assertions are required test scenarios expressed against each task's proposed interface/fixture variables; they are not a claim that the tests already exist.

**Tracker:** BRAIN project, root epic BRAIN-1. Strict close policy. 9 stories and 33 implementation tasks.

### BRAIN-2 — Restore composition guarantees and define policy

Nested execution, verification, budgets and reload must remain trustworthy before automatic reuse amplifies them.

#### BRAIN-11 — Implement restrictive policy composition

**Dependencies:** Ready now (no prerequisites).

**Files:** Create lua/policy.lua and tests/policy.lua; integrate lua/perm.lua; update CMakeLists.txt and docs/policy.md.

**Implementation:** Define immutable policy scopes with IDs and revisions. Intersect capability/resource allow constraints, union denies, retain every applicable quota, take minimum hard ceilings, and let approval requirements accumulate. A child override can narrow but never widen an ancestor. Unknown capability/resource evaluators deny. Preserve legacy modes through an explicit adapter; no early explicit-allow return may bypass chat or agent restrictions.

**Interface:** policy.compile(scopes) -> compiled|nil,error; policy.decide(compiled, descriptor, args, usage) -> {verdict, reasons, obligations, policy_revision}. Host descriptors derive canonical resource attributes; caller-supplied resource labels confer no authority.

**Acceptance criteria:**

- [x] Parent deny defeats child/tool allow; chat restrictions and agent restrictions survive explicit overrides and scope reordering.
- [x] Unknown evaluators and malformed limits fail closed; disjoint resource allows produce no access; policy inputs cannot be mutated through a compiled result.

**Test scenario:**

```lua
assert(policy.decide(policy.compile({parent_deny, child_allow}), write_cap, args, {}).verdict == "deny")
```

**Verification:** Planned suite: `policy`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-12 — Reserve shared quotas atomically in SQLite

**Dependencies:** BRAIN-11

**Files:** Create lua/quota.lua and tests/quota.lua; use src/ldb.c existing connection API; add tests to CMakeLists.txt.

**Implementation:** Persist buckets keyed by policy scope, rule ID, subject and time window, not run ID. Enforce all applicable buckets in one BEGIN IMMEDIATE transaction with rollback on any failure. Reserve count and bounded estimated usage before dispatch; reconcile actual usage after completion. Fixed windows first, explicit reset semantics, injectable clock for tests. A failed or uncertain call consumes its attempt count; release only unused cost reservation with durable reconciliation. No coroutine yield inside a transaction. SQLite lock contention must return retryable refusal, never execute unmetered.

**Interface:** quota.open(conn, clock) -> ledger; ledger:reserve(compiled, invocation_id, estimate) -> reservation|nil,error; ledger:settle(reservation_id, actual, outcome) -> receipt|nil,error. Reservation IDs are idempotent.

**Acceptance criteria:**

- [x] Two independent database connections competing for the last shared token permit exactly one invocation; restart retains quota consumption.
- [x] Failure in one bucket changes none of the others; repeated settle does not double charge; backward clock changes cannot replenish a bucket.

**Test scenario:**

```lua
assert(granted_by_connection_a + granted_by_connection_b == 1)
```

**Verification:** Planned suite: `quota`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-13 — Route nested and surface calls through one invocation gate

**Dependencies:** BRAIN-11, BRAIN-12

**Files:** Create lua/invoke.lua and tests/invoke.lua; modify lua/tools.lua, lua/perm.lua, lua/thread.lua, lua/events.lua, lua/tui/gate.lua and studio/data/core/agentview.lua; update related tests and invocation documentation.

**Implementation:** Make invocation gating common to CLI, Studio, spawned agents, tools.call, fallback and capability adapters. Carry run policy in coroutine-local invocation context with protected cleanup; nested calls derive narrower context. Separate trusted host raw dispatch from policy-enforced public dispatch. Audit tool_env raw sys/db/require exposure: generated/mined code receives only mediated effects, while trusted installed modules are explicitly privileged. Emit before/after once, including denial and runner errors. Do not label in-process native code sandboxed.

**Interface:** invoke.call(exec_context, capability_id, args, options) -> result|nil,structured_error. Internal raw runners are not exported to generated workflow environments.

**Acceptance criteria:**

- [x] Reproduced denied nested write cannot execute through tools.call, fallback, child agents or either UI/CLI surface; no side-effect marker is created.
- [x] Exactly one start/terminal pair per attempted invocation; coroutine context is restored after error and unrelated concurrent runs never borrow permissions.

**Test scenario:**

```lua
assert(not fake_files["forbidden.txt"]); assert(terminal_events_for(call_id) == 1)
```

**Verification:** Planned suite: `invoke`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-14 — Repair verifier propagation and nested execution limits

**Dependencies:** Ready now (no prerequisites).

**Files:** Modify lua/callable.lua, lua/skills.lua, lua/tools.lua and lua/events.lua; extend tests/callable.lua, tests/skills.lua, tests/luatool.lua and tests/events.lua.

**Implementation:** Propagate false/throwing verification into failed outcomes while preserving cleanup execution and both primary/cleanup error details. Save/restore debug hooks across nested tools, enforce enclosing and child budgets, and bound event handler execution. Distinguish cleanup hooks from verifiers. Relate lifecycle changes to BCALL-1; do not silently close that existing ticket.

**Interface:** Callable result preserves {status, value, error, verification, cleanup_error}; existing successful return compatibility is retained through adapters.

**Acceptance criteria:**

- [x] A false or throwing skill verifier never reports success or becomes eligible training success; finalizers still run once.
- [x] The outer instruction limit survives an inner call; runaway event handlers terminate without removing the surrounding execution budget.

**Test scenario:**

```lua
assert(outcome.status == "failed"); assert(outcome.verification.ok == false)
```

**Verification:** Planned suite: `callable|skills|luatool|events`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-15 — Make reload rollback and session discovery reliable

**Dependencies:** Ready now (no prerequisites).

**Files:** Modify lua/boot.lua and lua/control.lua; extend tests/lifecycle.lua, tests/sessions.lua and tests/control.lua.

**Implementation:** Stage reload state and registrations, reconcile workers/worker aliasing, and restore module bindings plus callback registrations when wiring fails. Correct /sessions store API call; expose actual store failures rather than returning an empty result. Preserve current user edits in boot.lua.

**Interface:** Reload either publishes one complete generation or leaves the previous generation usable; sessions command returns stored sessions or a visible error.

**Acceptance criteria:**

- [x] An injected wiring failure preserves bog.worker identity, previous registrations and subsequent execution without duplicate handlers.
- [x] A populated store appears in /sessions; a simulated store error is distinguishable from zero sessions.

**Test scenario:**

```lua
assert(bog.worker == prior_worker); assert(#listed_sessions == 1)
```

**Verification:** Planned suite: `lifecycle|sessions`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-16 — Harden local control access and unattended authorization

**Dependencies:** BRAIN-13

**Files:** Modify lua/control.lua, src/lserve.c and tests/control.lua; document local access and headless profiles in docs/policy.md.

**Implementation:** Authenticate local control mutations by default, support explicit trusted local profiles, validate Host/Origin for browser-accessible routes and scope tokens to capabilities. Resolve ask in unattended mode through an explicit profile; missing approval must not silently become allow. Check canonical paths, symlink traversal, shell/raw sys escape routes and shared environment mutation at the actual effect boundary. Distinguish application policy from OS containment. Bound generated execution memory/native calls using supported host controls or isolated workers; unknown/unbounded native execution is not admitted as restricted code.

**Interface:** Control requests become authenticated invocation contexts; policy profiles explicitly choose deny/queue for unattended approval. Document trusted host, restricted Lua and isolated worker boundaries.

**Acceptance criteria:**

- [ ] Unauthenticated or wrong-origin control mutations fail; explicit configured clients still work and tokens never appear in evidence.
- [ ] A headless ask without a configured decision cannot execute; symlink/path and shared-environment attack fixtures cannot bypass the mediated capability boundary.

**Test scenario:**

```lua
assert(headless_ask.executed == false); assert(unauthenticated.status == 401)
```

**Verification:** Planned suite: `control|invoke|sandbox`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

### BRAIN-3 — Ship a local always-Lua workflow runtime

Ordinary Lua controls every step, including delegation; injected values and functions remain practical and expressive.

#### BRAIN-17 — Define versioned capabilities and structured invocation outcomes

**Dependencies:** BRAIN-13

**Files:** Create lua/capability.lua, tests/capability.lua and docs/capabilities.md; adapt lua/tools.lua.

**Implementation:** Register capability identity/version, input/output validation, effect class, resource extraction, usage estimator, execution target and cancellation/reconciliation support. Reuse AIbyWire ToolSchema concepts and map existing Boggart/Station names rather than rename their registries. Distinguish pure, read, write and unknown effects. Missing effect metadata is unknown and receives conservative policy. Preserve structured data instead of forcing stringification.

**Interface:** capability.register(descriptor, runner); capability.resolve(id, version) -> descriptor|nil,error. Outcome status is succeeded/failed/cancelled/uncertain with result or artifact references, usage and execution receipt.

**Acceptance criteria:**

- [x] Legacy tools register through an adapter without losing arguments or structured results; incompatible descriptor versions reject before dispatch.
- [x] Effectful timeout reports uncertain when execution cannot be disproved, rather than declaring failed and authorizing blind retry.

**Test scenario:**

```lua
assert(timeout_outcome.status == "uncertain")
```

**Verification:** Planned suite: `capability`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-41 — Implement injected context values and providers

**Dependencies:** BRAIN-17

**Files:** Create lua/context.lua and tests/context.lua; document contracts in docs/workflows.md.

**Implementation:** Accept concrete context, Lua provider functions and composable provider objects. Resolve explicit injection before workflow defaults; do not silently serialize closures. A provider may call mediated capabilities through ctx. Make cache lifetime explicit (none/step/run), record evaluated value provenance and source revisions, and treat missing context as a typed result/error. Reject accidental cycles. Credentials remain opaque handles. Context is flexible; a mandatory fixed input schema is not the only supported modelling form.

**Interface:** context.new(injected, defaults, exec_context) -> resolver; resolver:resolve(key, request) -> value,provenance|nil,error. Provider function signature is function(ctx, request); provider object is {resolve=function, cache=...}.

**Acceptance criteria:**

- [x] The same workflow works with a concrete character record and a provider function; injection wins over defaults and missing values are explicit.
- [x] Provider calls are traced and policy-gated; run caching does not leak across runs; cyclic providers fail with the resolution path.

**Test scenario:**

```lua
assert(ctx:resolve("character", {id="fixture"}) .name == "Fixture Character")
```

**Verification:** Planned suite: `context`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-42 — Execute versioned Lua workflows with pinned run state

**Dependencies:** BRAIN-41, BRAIN-14, BRAIN-15

**Files:** Create lua/workflow.lua, tests/workflow.lua and examples/workflows/slack_followup.lua; update CMakeLists.txt.

**Implementation:** Register immutable workflow source versions plus content hashes; choose an active version only at run start. Run normal Lua functions and explicit ctx:step/ctx:call boundaries without imposing a DAG language. Support nested workflows, cancellation, structured errors and context injection. Step IDs combine stable source site with occurrence path for loops/branches. Provider and capability versions form a run dependency manifest. Ordinary Lua computation remains available inside a step.

**Interface:** workflow.register({id,version,run,defaults,verify,metadata}); workflow.start(id, {context,policy,version}) -> run_handle; ctx:step(site_id, fn); ctx:call(capability_id,args,options); ctx:resolve(key,request).

**Acceptance criteria:**

- [x] A Slack-shaped fixture gathers, checks, branches, optionally calls a model and reports; a different input follows the other branch using the same Lua version.
- [x] Activating v2 during a suspended v1 run leaves that run and its resolved dependencies pinned; new runs select v2; cancellation preserves a terminal state.

**Test scenario:**

```lua
assert(old_run.version == "v1"); assert(new_run.version == "v2")
```

**Verification:** Planned suite: `workflow`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-43 — Separate fresh runs, resumption and cached-result reuse

**Dependencies:** BRAIN-42, BRAIN-18

**Files:** Create lua/runstore.lua and tests/runstore.lua; integrate lua/workflow.lua and existing store module.

**Implementation:** Persist start/terminal step receipts and workflow/dependency pins. Resume at explicit durable step boundaries; replay prior pure control flow using recorded results only where supported, never serialize arbitrary Lua stacks. Non-resumable workflows state that limitation. Reconcile uncertain effects by operation ID before retry. Cache only declared eligible capabilities with input, code, dependency and freshness keys. Bound retries, cancellation and compensation; compensation itself is an observable effect.

**Interface:** runstore.resume(run_id) -> resumable_state|nil,error; runstore.reconcile(invocation_id) -> known_outcome|uncertain; cache.lookup(descriptor,args,dependency_manifest,freshness).

**Acceptance criteria:**

- [ ] A crash after remote write acknowledgement loss does not duplicate the effect on resume; unsupported continuation returns a clear non-resumable state.
- [ ] Changing source revision, provider revision or expired freshness invalidates a cached read; writes are never served from a generic result cache.

**Test scenario:**

```lua
assert(fake_remote.message_count == 1)
```

**Verification:** Planned suite: `runstore`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

### BRAIN-4 — Capture and import complete process evidence

Make all learning claims traceable to observed steps, calls, context and verified outcomes.

#### BRAIN-18 — Persist correlated step and invocation evidence

**Dependencies:** BRAIN-42

**Files:** Create lua/evidence.lua and tests/evidence.lua; integrate lua/trace.lua, lua/sessionlog.lua, lua/invoke.lua and lua/workflow.lua.

**Implementation:** Use an append-only versioned event schema and durable artifact references. Record run/step/parent/attempt/correlation IDs, code/version, capability inputs/results, context resolutions, branch observations, timing, usage, policy decision and verifier result. Redact before persistence, not merely display. Preserve full mining-relevant values or explicit truncation/redaction/artifact markers; existing 180-character live previews are not source evidence. Survive interleaved runs and record incomplete starts after crash.

**Interface:** evidence.append(event) -> event_id|nil,error; evidence.read_run(run_id) -> ordered_events. Schema v1 includes schema_version, event_id, origin, provenance, run_id, step_id, parent_id, attempt_id, kind, timestamp, payload/artifact_refs.

**Acceptance criteria:**

- [ ] Quoted strings, newlines and nested results round-trip; interleaved workflows reconstruct their own parent/dataflow chains.
- [ ] Every invocation has an observed terminal or explicit incomplete state after restart; secrets are absent from records and artifacts under a credential fixture.

**Test scenario:**

```lua
assert(roundtrip.payload.args.text == "quoted \"value\"\nnext line")
```

**Verification:** Planned suite: `evidence`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-19 — Import historical Boggart, Claude and OpenAI logs

**Dependencies:** BRAIN-18

**Files:** Create lua/imports/{init,boggart,claude,openai}.lua and tests/imports.lua; add sanitized fixtures under tests/fixtures/process_logs/.

**Implementation:** Discover format variants from explicitly selected local exports/log paths. Implement versioned adapters with source hash, byte/event offsets, original timestamps, tool-call IDs, session links and import confidence. Import available messages, tool results and context without inventing absent arguments, branches or private reasoning. Incremental checkpoints and dedup keys survive reimport; malformed records quarantine individually. Require selected roots and redaction rules; do not sweep unrelated home directories.

**Interface:** imports.ingest({source,format,scope,redaction}) -> {added,duplicates,quarantined,checkpoint}; normalized records distinguish observed, inferred and missing fields.

**Acceptance criteria:**

- [ ] Repeat and overlapping import add no duplicate logical events; interrupted import resumes without loss; malformed entries retain diagnostic provenance.
- [ ] Claude/OpenAI fixtures correlate tool requests/results and available surrounding context; absent outputs remain marked missing and cannot qualify as verified successes.

**Test scenario:**

```lua
assert(second_import.added == 0); assert(missing_result.provenance == "missing")
```

**Verification:** Planned suite: `imports`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

**Format evidence (21 September 2026):** Bounded structure-only sampling of local logs confirmed Claude message text/tool_use/tool_result records with parent/session identifiers, and Codex response_item function_call/function_call_output plus custom_tool_call/custom_tool_call_output records. Codex event_msg.item_completed may provide an alternate representation of the same action. Synthetic fixtures must cover these variants and avoid duplicate operation/cost counting; unknown records retain explicit coverage gaps. No private transcript contents were copied into the repository, and this sampling is not exhaustive format qualification. Exclude private/raw/encrypted reasoning from required context; available conversation text and tool observations suffice.

#### BRAIN-20 — Add evidence retention, export and deletion controls

**Dependencies:** BRAIN-19

**Files:** Create lua/evidence_retention.lua and tests/evidence_retention.lua; document docs/evidence.md.

**Implementation:** Separate source evidence, derived indexes, reusable code and credentials. Add retention by scope, encrypted-store deployment guidance where supported, redacted export and deletion tombstones that propagate to Gestalt indexing. Code remains inspectable while deleted examples lose their private payload; mark evaluation lineage invalid where evidence is required. Surface trace capture failures and apply configured stop/degraded policy before effects.

**Interface:** evidence_retention.delete_scope(scope) -> deletion_manifest; export_run(run_id,profile) -> artifact; retention sweep returns counts and unresolved external deletions.

**Acceptance criteria:**

- [ ] Deleting a project removes its payloads and derived retrieval entries after reconciliation without deleting unrelated scopes.
- [ ] A replay/export cannot recover redacted credentials; missing evidence or storage failure is visible and excluded from promotion qualification.

**Test scenario:**

```lua
assert(search_deleted_scope.total == 0)
```

**Verification:** Planned suite: `evidence_retention`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

### BRAIN-5 — Reuse Station, AIbyWire and Gestalt through bounded adapters

Boggart owns Lua decisions; specialist systems own their existing computational capabilities and delegated execution.

#### BRAIN-21 — Adapt Station capabilities over existing ZMQ and MCP

**Dependencies:** BRAIN-17, BRAIN-18

**Files:** Modify lua/stationlink.lua, lua/llmstation.lua and tests/station.lua; create lua/adapters/station.lua.

**Implementation:** Map Station tools to capability descriptors and correlated outcomes. Preserve existing BSTAT work. Negotiate protocol/capability versions, cancellation and structured errors. Carry run/call IDs and narrowed policy where supported; treat remote enforcement as a separately verified capability. Fallback may switch transport only when the original request is known not executed; uncertain effectful requests require reconciliation.

**Interface:** Station adapter provides descriptor discovery and invoke/status/cancel where the server supports them; unsupported operations return explicit unsupported.

**Acceptance criteria:**

- [ ] Equivalent fixture requests via ZMQ and MCP preserve values and correlation; a missing native transport produces the documented supported fallback.
- [ ] A lost reply to a write does not trigger a duplicate MCP request; unsupported cancellation is represented accurately.

**Test scenario:**

```lua
assert(fake_station.write_count == 1)
```

**Verification:** Planned suite: `station`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-22 — Repair Station capture and faithful parameter binding

**Dependencies:** BRAIN-21, BRAIN-19

**Files:** Sibling ~/llm-station/src/forge/{ActionCapture.cpp,Forger.cpp,ForgeExecutor.cpp,ForgeTypes.h}, src/ralph/RalphExecutionActions.cpp and relevant forge tests; read its AGENTS.md and project_map.md before edits.

**Implementation:** Use a JSON encoder, preserve results/artifact refs, populate fixed/template arguments and result bindings, and bind current task inputs in template-first execution. Unknown or unavailable precondition checks are ineligible. Expose repaired evidence/templates for Lua compilation; do not make Station a competing top-level learning owner. Run sibling tests in its own change set.

**Interface:** Versioned ActionTrace/ActionTemplate exchange preserves typed bindings and evidence provenance; Boggart adapter imports it into normalized evidence and candidate Lua generation.

**Acceptance criteria:**

- [ ] A trace containing quotes/newlines and nested results produces a faithful template that executes with distinct held-out parameter values.
- [ ] Missing checker and unknown precondition cannot pass eligibility; Ralph supplies current arguments instead of historical literals.

**Test scenario:**

```lua
assert(replayed_target == held_out_target); assert(unknown_precondition_eligible == false)
```

**Verification:** Planned suite: `Station forge and Ralph suites (select exact commands from repository instructions)`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-23 — Delegate durable jobs to AIbyWire with one retry owner

**Dependencies:** BRAIN-21, BRAIN-43

**Files:** Create lua/adapters/aibywire.lua and tests/aibywire.lua; use ~/aibywire/taskengine/tools/schema.py, dag/model.py and durable/runtime.py contracts; sibling changes isolated.

**Implementation:** Implement capability discovery plus submit/status/cancel/reconnect and durable execution receipts through available ZMQ/MCP endpoints. Boggart Lua remains logical control flow; AIbyWire owns retries within its delegated job. Persist remote operation ID before waiting. Validate atomic claim/idempotency behavior instead of relying on the known Python read-then-write check. Document per-backend differences; unsupported claims stay disabled.

**Interface:** Delegated job receipt includes backend, remote_run_id, operation_id, state, result/artifacts and policy/usage acknowledgement.

**Acceptance criteria:**

- [ ] Client restart reconnects to the same job and concurrent duplicate submission creates one claimed effect under the chosen backend.
- [ ] Timeout/cancel races yield succeeded/cancelled/uncertain accurately; Boggart does not independently retry a job while AIbyWire owns its retry loop.

**Test scenario:**

```lua
assert(resumed.remote_run_id == original.remote_run_id)
```

**Verification:** Planned suite: `aibywire`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-24 — Index scoped memory and process evidence in Gestalt

**Dependencies:** BRAIN-19, BRAIN-20

**Files:** Extend lua/gestalt.lua and the existing lua/memory.lua compatibly; create lua/adapters/gestalt.lua and tests/memory.lua. Preserve memory.list/index_text/remember/recall/forget/promote and their existing project scopes.

**Implementation:** Build a memory port for scoped text/structured/graph retrieval using existing Gestalt HTTP CQRS support and advertised advanced search. Index source spans, code versions, AST features, steps, dependencies and context references with stable IDs and tombstones. Preserve local storage as authoritative; indexing is retryable. Offer a small local lookup fallback and explicit advanced-search unavailable state. No fabricated Gestalt endpoint or assumed cross-tenant isolation.

**Interface:** memory.search(query,{scope,filters,limit}) -> {hits,provenance,backend,coverage}; memory.sync(cursor) -> checkpoint. Hits carry source IDs/spans, permission scope and revisions.

**Acceptance criteria:**

- [ ] Scoped character/process queries return provenance and revisions; forbidden projects cannot enter candidate retrieval even through similarity search.
- [ ] Gestalt outage leaves local Lua execution usable; resumed indexing is idempotent and propagates deletion tombstones.

**Test scenario:**

```lua
assert(hit.scope == requested_scope); assert(hit.source_ref ~= nil)
```

**Verification:** Planned suite: `memory`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

### BRAIN-6 — Recognize recurring processes and compile Lua candidates

Combine context retrieval with structural evidence; similarity proposes matches, execution evidence establishes reusable behavior.

#### BRAIN-25 — Parse and index Lua structure with source provenance

**Dependencies:** BRAIN-42

**Files:** Create lua/mining/ast.lua and tests/mining_ast.lua; add a parser dependency decision to docs/adr/lua-ast.md.

**Implementation:** Evaluate available maintained Lua-version-compatible parsers against actual language syntax and embedding constraints before selecting one. Produce normalized AST features, source spans, call sites and conservative def-use relationships; preserve original source as executable truth. Treat dynamic dispatch/closures/metatables as unknown when not statically resolvable. Do not infer deterministic semantics from function names. Pin parser version and license in the decision.

**Interface:** ast.index(source,version) -> {nodes,sites,features,unknowns,source_hash}|nil,parse_error.

**Acceptance criteria:**

- [ ] Loops, branches, closures and dynamically chosen calls retain correct source spans; parse errors never create eligible executable candidates.
- [ ] Alpha-renamed local variables yield comparable structural features while changed branch predicates remain distinguishable.

**Test scenario:**

```lua
assert(features_a.structure_hash == features_renamed.structure_hash)
```

**Verification:** Planned suite: `mining_ast`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-26 — Retrieve and align workflow and fragment candidates

**Dependencies:** BRAIN-24, BRAIN-25

**Files:** Create lua/mining/recognize.lua, lua/mining/align.lua and tests/mining_recognition.lua.

**Implementation:** Retrieve scoped candidates using Gestalt semantics plus AST/capability/effect features; then align observed sequences/dataflow, loop occurrences, branch outcomes and context dependencies. Separate whole workflows and reusable fragments. Avoid matching on task description alone. Return evidence, coverage, ambiguity and unsupported dynamic regions; require binding/applicability checks before execution. Use a labelled positive/negative fixture corpus including similar wording with different effects.

**Interface:** recognize.find(request,context,scope) -> ranked_candidates; align.compare(traces,ast_indexes) -> {common_regions,variants,bindings,evidence,unknowns}.

**Acceptance criteria:**

- [ ] Equivalent processes with different wording/values group together; near-identical descriptions with incompatible effects remain separate.
- [ ] Branches/fragments across several traces preserve output-to-input bindings and explicitly mark unobserved paths instead of assuming them.

**Test scenario:**

```lua
assert(rank(correct_structure) < rank(similar_words_wrong_effect))
```

**Verification:** Planned suite: `mining_recognition`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-27 — Generate parameterized Lua with residual model steps

**Dependencies:** BRAIN-26

**Files:** Create lua/mining/compile.lua, tests/mining_compile.lua and examples/workflows/compiled_followup.lua.

**Implementation:** Compile observed stable regions into ordinary Lua ctx:step/ctx:call code with injected parameters/providers, clear guards and source mappings. Retain explicit model calls for unresolved decisions. Reject missing required evidence, unsafe literal secrets and unsupported transformations. No mandatory new workflow DSL and no arbitrary Lua-to-DAG translation. Compilation can invoke an LLM through the same policy/evidence contracts; generated code stays a candidate until evaluated.

**Interface:** compile.candidate(alignment,options) -> {source,source_hash,manifest,source_map,required_context,verifiers,unknowns}|nil,error.

**Acceptance criteria:**

- [ ] A candidate executes correctly on distinct inputs without copying prior recipients, filenames or private context constants.
- [ ] Stable checks become Lua while ambiguous response interpretation remains an explicit model step; every emitted step links to source evidence or is labelled synthesized.

**Test scenario:**

```lua
assert(not candidate.source:find("historical-secret", 1, true))
```

**Verification:** Planned suite: `mining_compile`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-28 — Run mining in background and directed modes

**Dependencies:** BRAIN-27, BRAIN-12

**Files:** Create lua/mining/jobs.lua and tests/mining_jobs.lua; integrate existing trigger/supervisor modules.

**Implementation:** Support manually scoped corpus/range/objective jobs and bounded incremental background mining with the same engine. Persist cursor, input snapshot, job version and candidate provenance. Apply resource/LLM budgets, cancellation and scheduling priority so mining cannot starve interactive execution. Deduplicate overlapping work; interrupted jobs resume. Default background behavior is configurable independently from candidate activation.

**Interface:** mining.start({scope,range,objective,mode,budget}) -> job_id; mining.status/cancel(job_id); mining.tick(cursor,budget).

**Acceptance criteria:**

- [ ] Directed and background jobs over the same evidence yield equivalent candidate provenance; overlap does not duplicate active candidates.
- [ ] Cancellation and restart preserve progress; foreground work retains its configured quota and latency budget under mining load.

**Test scenario:**

```lua
assert(background_candidate.source_hash == directed_candidate.source_hash)
```

**Verification:** Planned suite: `mining_jobs`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

### BRAIN-7 — Evaluate, promote and route learned versions

Automatic learning remains reversible and evidence-driven; users can change automation behavior.

#### BRAIN-29 — Evaluate candidates against held-out outcomes and costs

**Dependencies:** BRAIN-27, BRAIN-43, BRAIN-14

**Files:** Create lua/learning/evaluate.lua, tests/learning_evaluate.lua and tests/fixtures/process_bench/.

**Implementation:** Separate training/validation/held-out examples by originating task/session and variant to prevent leakage. Run effect mocks or isolated test adapters for replay; distinguish recorded-result evaluation from fresh real-input evaluation. Independent verifiers check output/task invariants, not just model self-ratings. Account for discovery, imports, mining/model synthesis, evaluation, failed runs, fallback and repairs as well as execution. Add false-success and wrong-applicability measurements.

**Interface:** evaluate.run(candidate,dataset,policy) -> {outcomes,coverage,costs,regressions,eligibility,evidence_refs}. Promotion decisions consume this report, not a pass-looking transcript.

**Acceptance criteria:**

- [ ] A wrong-recipient candidate and a verifier-failure candidate are rejected even if their report text looks plausible.
- [ ] Held-out inputs are absent from synthesis; baseline and candidate costs include amortized learning costs and demonstrate where break-even occurs.

**Test scenario:**

```lua
assert(report.eligibility == false); assert(report.regressions.wrong_recipient == 1)
```

**Verification:** Planned suite: `learning_evaluate`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-30 — Promote automatically with pins, rollback and user controls

**Dependencies:** BRAIN-29, BRAIN-28

**Files:** Create lua/learning/registry.lua, lua/learning/promote.lua and tests/learning_promote.lua.

**Implementation:** Store candidate/evaluated/active/disabled/quarantined versions and atomic active pointers. Default automatic activation only after configured evidence gates pass; expose review-required and off modes at project/workflow scope. Deny promotion on missing evidence, failed verifiers, resource-policy mismatch or unsupported preconditions. Keep run pins, rollback, reason/evidence ledger and staged rollout options. Initial gate proposal: all declared invariants pass and no known effect-safety regression; statistical thresholds remain explicit configuration measured by evaluation.

**Interface:** registry.activate(id,version,report,mode) -> activation_record|nil,reason; registry.rollback(id,target); registry.resolve(id,run_context) -> pinned_version.

**Acceptance criteria:**

- [ ] Passing candidates activate automatically in auto mode; review mode queues them and off mode leaves active pointer unchanged.
- [ ] Activation and rollback do not alter in-flight versions; concurrent promotions use compare-and-swap or transaction conflict detection and leave an auditable winner.

**Test scenario:**

```lua
assert(inflight.version == "v1"); assert(registry.resolve(id,new_context).version == "v2")
```

**Verification:** Planned suite: `learning_promote`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-31 — Recognize ordinary requests and bind current context

**Dependencies:** BRAIN-30, BRAIN-26

**Files:** Create lua/learning/route.lua and tests/learning_route.lua; integrate lua/skillrouter.lua and lua/route.lua.

**Implementation:** Separate candidate retrieval, concrete context binding, applicability evaluation and execution. Prefer eligible learned workflow/fragments on normal requests; reject ambiguous/wrong-scope/stale matches and use an explicit model planning Lua step. Bound retrieval/judgment cost so recognition cannot cost more than it saves unnoticed. Never substitute historical arguments for missing current inputs. Log selected/rejected alternatives and reasons.

**Interface:** route.select(request,context,policy) -> {workflow,version,binding,evidence}|{fallback,reason}; invocation always enters workflow.start.

**Acceptance criteria:**

- [ ] A paraphrased known task uses its workflow with current recipients; a subtly different task fails applicability and falls back visibly.
- [ ] Missing context cannot trigger historical side effects; policy denial remains denial even when a candidate has high similarity.

**Test scenario:**

```lua
assert(selected.binding.recipient == current_recipient)
```

**Verification:** Planned suite: `learning_route`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-32 — Detect regressions and quarantine degraded procedures

**Dependencies:** BRAIN-31

**Files:** Create lua/learning/monitor.lua and tests/learning_monitor.lua.

**Implementation:** Track outcomes by workflow/capability/provider version and task variant. Detect verifier failures, cost regressions, stale applicability and unknown outcomes; automatically suspend unsafe candidate activation and quarantine active versions according to policy. Preserve failed examples for targeted remining, without treating failure as a successful exemplar. Compare canary and baseline cohorts with minimum sample/confidence controls.

**Interface:** monitor.observe(run_outcome) -> actions; monitor.explain(workflow_id) -> evidence-backed health state.

**Acceptance criteria:**

- [ ] A changed tool schema or repeated verification failure prevents further automatic selection of the affected version and preserves rollback.
- [ ] One noisy latency observation does not cause unbounded promotion/rollback oscillation; thresholds, sample counts and evidence are inspectable.

**Test scenario:**

```lua
assert(registry.status(broken_version) == "quarantined")
```

**Verification:** Planned suite: `learning_monitor`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

### BRAIN-8 — Deliver user-visible workflows, triggers and learning controls

Make cheaper repeatable work usable without prompting, and make its behavior inspectable.

#### BRAIN-33 — Deliver the Slack follow-up workflow with fixture-first validation

**Dependencies:** BRAIN-31, BRAIN-43

**Files:** Create examples/workflows/slack_followup.lua, tests/workflow_slack.lua and docs/examples/slack-followup.md.

**Implementation:** Implement gather, compare expected list, interpret ambiguous replies with bounded model calls, compute missing responders, send through a capability, track progress and generate report. Inject channel/list/time window/provider/policy. Recheck response state immediately before sending, use run-recipient-campaign operation IDs, reconcile uncertain sends and record opt-outs. All development tests use fakes; enabling real sends requires the user's actual workflow configuration/authorization.

**Interface:** Workflow context supplies response source, expected participants, reporting target, current time and model capability; outputs report artifact, progress record and effect receipts.

**Acceptance criteria:**

- [ ] Late replies and duplicate triggers do not produce duplicate or obsolete reminders; ignored/ambiguous replies follow declared policy.
- [ ] Two distinct cohorts and periods produce independently checked reports, with measured model-call reduction against the baseline.

**Test scenario:**

```lua
assert(reminder_count("late_responder") == 0); assert(reminder_count("missing_person") == 1)
```

**Verification:** Planned suite: `workflow_slack`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-34 — Deliver novel context, timeline and text-maintenance workflows

**Dependencies:** BRAIN-31, BRAIN-24

**Files:** Create examples/workflows/novel_{character,timeline,cleanup,wordcount}.lua and tests/workflow_novel.lua.

**Implementation:** Use synthetic novel fixtures to retrieve detailed character evidence, assemble timeline constraints, propose cleanup diffs and compute word count under an explicit documented counting rule. Inject novel/corpus/revision and provider functions. Preserve provenance and distinguish inconsistent statements from missing facts. Default creative/canon changes to proposed artifacts; canon authority semantics were not settled in the interview. Cleaning must not silently rewrite narrative facts.

**Interface:** Each workflow returns evidence-backed artifacts; cleanup returns diff plus checks; timeline returns ordered/partial constraints and conflicts, not invented dates.

**Acceptance criteria:**

- [ ] Same character name in different novels stays scoped; contradictions and unavailable evidence are shown rather than merged into fabricated facts.
- [ ] Cleanup preserves fixture facts and supports diff review; word counts follow the declared Unicode/apostrophe/hyphen convention with edge fixtures.

**Test scenario:**

```lua
assert(timeline.conflicts[1].source_refs ~= nil); assert(cleanup.changed_facts == 0)
```

**Verification:** Planned suite: `workflow_novel`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-35 — Expose named runs, buttons and scheduled execution

**Dependencies:** BRAIN-31, BRAIN-43

**Files:** Extend lua/triggers.lua, lua/control.lua and studio/data/core/workflows.lua; create tests/workflow_triggers.lua.

**Implementation:** Route explicit workflow names, UI buttons and cron-equivalent schedules through the same version/policy/context binding path. Persist schedule identity, timezone, missed-run behavior, concurrency limit and deduplication key. Support pause/cancel, dry-run preview and visible last/next run. A schedule is not additional authorization; policy changes affect future admissions.

**Interface:** triggers.bind({workflow,context_provider,schedule,timezone,overlap,misfire,policy_scope}); all trigger kinds call workflow.start with an auditable origin.

**Acceptance criteria:**

- [ ] Button, named call and timer select the same pinned version and policy; overlapping/restarted schedulers do not duplicate one occurrence.
- [ ] DST changes, missed runs, paused schedules and revoked permissions follow explicit tested behavior and show a clear status.

**Test scenario:**

```lua
assert(runs_for_occurrence(schedule_id, occurrence_id) == 1)
```

**Verification:** Planned suite: `workflow_triggers`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-36 — Show workflow code, evidence, savings and automation controls

**Dependencies:** BRAIN-32, BRAIN-35, BRAIN-33, BRAIN-34

**Files:** Create studio/data/core/workflows.lua; integrate studio/data/core/agentview.lua and existing Studio panels; extend lua/control.lua and tests/control.lua; document docs/workflow-ui.md.

**Implementation:** Present source/AST navigation, run steps, context provenance, delegated job state, applicability reasons, cost breakdown, candidate comparison, active version and rollback. Expose auto/review/off mining and promotion controls separately. Show actual savings with learning cost and uncertainty; never count failed or unverified outcomes as saved work. Build on existing Studio review surfaces in BSTUD.

**Interface:** Read models use registry/evidence/evaluation APIs; UI actions call existing policy-enforced service methods rather than raw tools.

**Acceptance criteria:**

- [ ] A user can inspect why a workflow ran, locate the Lua source step, compare versions, disable it and roll back without editing SQLite.
- [ ] CLI and Studio show consistent status/costs for an uncertain remote effect and an amortized-negative candidate; UI interaction tests cover core controls.

**Test scenario:**

```lua
assert(displayed_total_cost == evaluation.total_cost)
```

**Verification:** Planned suite: `Studio workflow interaction suite and CLI workflow inspection tests`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

### BRAIN-9 — Package Lua modules and isolate native extensions

Make capability packs modular without weakening the always-Lua execution or policy model.

#### BRAIN-37 — Version and load Lua workflow/capability packs

**Dependencies:** BRAIN-30, BRAIN-15

**Files:** Create lua/extensions/loader.lua, tests/extensions.lua and docs/extensions.md; extend existing callable/skill loading hooks.

**Implementation:** Define manifests for package ID/version, host API range, Lua modules, workflows, capability requirements, context providers and source hashes. Resolve dependency versions and namespace collisions; reject cycles/incompatible APIs. Stage registrations before atomic activation, retain old versions while runs reference them, and support removal/deactivation. Reuse skills/callables where compatible; BCALL and BTEAM remain related work, not replaced.

**Interface:** extensions.install(path) -> package_version; extensions.activate(id,version); extensions.disable(id); manifest format version is explicit.

**Acceptance criteria:**

- [ ] A pack installs, upgrades and rolls back while an old workflow run completes on its pinned dependency set.
- [ ] Conflicting names, dependency cycles and unsupported host versions reject without partially registered tools or leaked event handlers.

**Test scenario:**

```lua
assert(old_run.dependencies.pack_version == "1.0.0")
```

**Verification:** Planned suite: `extensions`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-38 — Define a versioned native ABI and out-of-process extension host

**Dependencies:** BRAIN-37, BRAIN-23

**Files:** Create include/boggart_extension.h, src/lextension.c, lua/extensions/native.lua, native test fixtures and docs/native-extensions.md; update CMakeLists.txt.

**Implementation:** First choose one measured native use case. Specify a narrow C ABI with version/size negotiation, ownership, buffer/error rules, thread affinity, cancellation and lifecycle. Prefer out-of-process hosting for untrusted/crash-prone or blocking plugins; only explicitly trusted plugins may run in process. DLL/.so/.dylib naming and loader behavior are platform-specific. Lua remains the caller/orchestrator. Pin libraries for active runs; do not unload executing code.

**Interface:** Versioned host function table and plugin descriptor exchange opaque handles and length-delimited bytes; no C++ STL types or Lua ABI exposure across the stable boundary.

**Acceptance criteria:**

- [ ] Small fixture plugins load and execute on macOS/Linux/Windows with ABI mismatch and allocation ownership tests; platform claims only after actual runs.
- [ ] A crashing/blocking isolated plugin does not terminate or stall Boggart; policy applies before dispatch and in-process plugin trust is visibly declared.

**Test scenario:**

```lua
assert(abi_mismatch_rejected_before_init == true)
```

**Verification:** Planned suite: `Native ABI fixture matrix plus extensions Lua suite`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

### BRAIN-10 — Prove the learning product and ship incrementally

Validate outcomes and migration, not merely the existence of modules or generated code.

#### BRAIN-39 — Run end-to-end product, failure and cost qualification

**Dependencies:** BRAIN-36, BRAIN-37, BRAIN-16

**Files:** Create tools/process_bench.lua, tests/process_e2e.lua and docs/process-benchmark.md; extend CI configuration using repository conventions.

**Implementation:** Run Slack and novel fixtures plus held-out variants through observe→mine→evaluate→promote→recognize→execute→rollback. Include policy bypass probes, concurrency quotas, missing context, transport uncertainty, provider drift, import corruption and restart. Fresh native build plus registered Lua tests and relevant Studio/platform checks. Pin fixture seeds and versions; report cost per independently verified outcome, model calls, wrong applicability, false success, human corrections and amortization.

**Interface:** Benchmark produces machine-readable run manifest and report artifact with exact executable/source revision, configuration and per-case evidence IDs.

**Acceptance criteria:**

- [ ] The full cycle succeeds on held-out inputs with no known false-success or duplicate-effect failures; failures remain visible rather than removed from denominators.
- [ ] Published report includes baseline, candidate, learning cost, break-even curve and limitations; fresh build and required platform checks are recorded with actual logs.

**Test scenario:**

```lua
assert(verified_candidate_outcomes == expected_outcomes); assert(duplicate_effects == 0)
```

**Verification:** Planned suite: `process_e2e plus targeted suites and platform matrix`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

#### BRAIN-40 — Document upgrades, operating limits and launch gates

**Dependencies:** BRAIN-39

**Files:** Update README.md, docs/workflows.md, docs/policy.md, docs/extensions.md and release notes; add store migration tests.

**Implementation:** Provide local-only quickstart, fixture demo, optional Station/AIbyWire/Gestalt setup, evidence/import controls, policy recipes, rollback and recovery playbooks. Migrate existing tools/skills/session data additively with backups and schema versions; no automatic historical-data upload. Publish capability/platform support matrix and explicit unresolved limits. Keep the native/plugin expansion optional to the first usable release.

**Interface:** Versioned store migrations are rerunnable; downgrade limitations and backup restoration steps are documented and exercised.

**Acceptance criteria:**

- [ ] A clean local install runs the demonstration without any sibling daemon or model account; optional services enable only advertised features.
- [ ] Upgrade from a representative pre-learning store preserves sessions/skills and can restore a backup; documentation matches executable commands and actual support.

**Test scenario:**

```lua
assert(after_upgrade.session_count == before_upgrade.session_count)
```

**Verification:** Planned suite: `Store migration fixtures and clean-install walkthrough`. Add a failing fixture for the scenario, implement the contract, then rebuild and run the registered suite using the protocol above; run affected existing suites. Native, sibling and Studio commands must come from the applicable repository build recipes. Attach actual test references/results before closure.

## 14. First implementation batch

Start BRAIN-11 (restrictive policy), BRAIN-14 (verifier and nested limits), and BRAIN-15 (rollback/session fixes); they have no mutual dependency. Then BRAIN-12 and BRAIN-13 establish the shared invocation seam. Build BRAIN-17, BRAIN-41, BRAIN-42 and BRAIN-18 to finish the local vertical slice. The first concrete acceptance fixture is the Slack gather/check/branch/report shape, with two distinct input sets, injected provider variants and a fake model capability. No real external sends are part of this batch.

## 15. Audit coverage and tracking discipline

| Audit finding | Planned task |
|---|---|
| A1 nested bypass | BRAIN-13 |
| A2 override precedence | BRAIN-11 |
| A3 swallowed verifier | BRAIN-14 |
| A4 lost parent budget; A5 unbounded events | BRAIN-14 |
| A6 reload rollback; A7 session listing | BRAIN-15 |
| A8 duplicate pre-call events | BRAIN-13 |
| A9 local service trust; A10 incomplete effect/headless boundaries | BRAIN-16, BRAIN-13 |
| A11 timing/outcome measurement | BRAIN-18, BRAIN-29 |
| A12 stale docs/release checks | BRAIN-39, BRAIN-40 |
| Station capture/binding/precondition findings | BRAIN-22 |
| AIbyWire atomic claim/retry ownership | BRAIN-23 |

The companion JSON manifest records task keys, descriptions, acceptance requirements and dependency IDs for reproducible review. Tracker is the execution status authority; this document is the full design/implementation plan. Update both when scope changes. Do not mark code work complete based on this planning pass.
