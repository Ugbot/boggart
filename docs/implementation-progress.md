# Process-learning implementation progress

The active programme is [the full implementation plan](superpowers/plans/2026-09-21-boggart-process-learning.md),
tracked in devtools as **BRAIN-1**. This record contains verified implementation
work, not future promises. Tracker criteria and commit links are the execution
status authority.

## Completed on 21 September 2026

| Ticket | Change | Verification | Commit |
|---|---|---|---|
| BRAIN-11 | Restrictive immutable policy scopes and corrected legacy override precedence | Fresh native build; policy 36 checks, perm 81 checks, front suite; independent review approved | `8d38645` |
| BRAIN-12 | Shared SQLite quota reservation, reconciliation, restart and clock protection | Rebuilt-binary quota 52 checks and policy 36 checks; real writer and commit lock contention; independent review approved | `3623844` |
| BRAIN-13 | Common invocation gate across nested tools, CLI/cTUI, Studio and child agents; coroutine authority/budgets, structured results and single accounting | Full rebuilt-binary Lua suite 59/59; invoke 87 checks; CTest invoke repeated twice; independent review approved | `15198f9` |
| BRAIN-14 | Verifier failures propagate, cleanup remains visible, and nested tool/event budgets survive resets and caught errors | Rebuilt-binary callable 35, skills 95, luatool 42 and events 128 checks; independent review approved | `2c79885` |
| BRAIN-17 | Immutable exact-version capabilities, structured outcomes, conservative effect uncertainty, and bounded usage reconciliation | Full rebuilt-binary Lua suite 60/60; capability 73, invoke 87, quota 54 and luatool 42 checks; deterministic native code-search fixture; CTest capability repeated twice; independent review approved | `d1e6c1a` |
| BRAIN-15 | Failed reload restores worker/module bindings and event registrations; session listing uses the actual store API and exposes errors | Rebuilt-binary lifecycle 114 checks, sessions 39 checks, real HTTP control 33 checks; independent review approved | `1470254` |
| BRAIN-41 | Injected concrete values, functions and composable providers; exact capability pins, revision-aware caches, provenance and restrictive authority | Rebuilt-binary context 78, capability 73, invoke 87, events 128, policy 36 and quota 54 checks; CTest context repeated twice; independent review approved | `6407221` |
| BRAIN-42 | Source-backed versioned Lua workflows with dependency pins, nested steps, cancellation and local Slack fixture | Native full62/62 before review fixes; final covering workflow65/context80/capability73/invoke87/luatool42/events128 pass; CTest workflow and context each repeated twice; independent re-review approved | `6a3588c` |
| BRAIN-18 | Durable correlated invocation/workflow/context evidence, bounded redaction and explicit incomplete coverage | Final native full63/63; evidence132 checks; CTest evidence/workflow/context/invoke each repeated twice; independent re-review approved | `cf3bda3` |
| BRAIN-43 | Opted-in durable Lua replay, operation reconciliation, ownership fencing and explicit result cache under current authority | Final native full64/64; runstore77/capability74; CTest runstore/capability/invoke each twice; real subprocess recovery with quotas; independent re-review approved | `3201e56` |
| BRAIN-19 | Scoped Boggart/Claude/OpenAI JSONL imports, durable checkpoints/provenance, mirror dedup and explicit missing observations | Final native imports632/evidence132/sessions39/workflow65; CTest imports twice; independent re-review approved | `7b1ee37` |
| BRAIN-20 | Scoped retention/deletion, redacted export, lineage invalidation, durable failure gaps and bounded recovery | Retention154 twice; final native and Linux seven affected suites each repeated twice; independent re-review approved | `e0a1900` |
| BRAIN-16 | Authenticated local control, explicit unattended admission, canonical effect paths and bounded generated execution | Final native66/66 and Linux65/65; native17 and Linux8 affected suites each twice; independent re-review approved | `2b81ea4` |
| BRAIN-21 | Station discovery, host-qualified capabilities and faithful ZMQ/MCP outcomes without unsafe retry | Final six affected suites each twice on native/Linux; real native MCP stdio and ZMQ ROUTER fixtures; independent re-review approved | `ce2e651` |
| BRAIN-22 | Faithful typed Station capture/bindings, bounded capture redaction, legacy export/import and terminal uncertain-state protection | Station forge203/catalog74/Ralph124/VerifyCode9; Boggart imports704, native/Linux repeated imports and actual current/redacted/legacy export bridges; independent re-review approved | Boggart `8b062dd`; Station `7e9e1b8f` |

| BRAIN-23 | Durable AIbyWire MCP delegation with retained SQLite claims, input-bound reconnect, backend-owned retries and privacy-aware receipts | Backend92 tests; Lua23 checks; native/Linux five affected suites each twice; actual MCP1.30 typed/restart/privacy/lost-ack/readonly checks; independent re-review approved | Boggart `3fc1412`; AIbyWire `4e8127e` |
| BRAIN-24 | Scoped Gestalt memory, current authority, stable IDs, tombstones and durable recovery | Memory54; five suites twice on native/Linux; fresh25ES tests; actual client/daemon restart, deletion, retention and outage; independent review approved | `dcf1e8d` + isolated Gestalt `f741ea7` |
| BRAIN-25 | Lua 5.5 ASTs with exact provenance, lexical normalization and conservative unknowns | 95 final checks twice on native/Linux; affected workflow/worker suites; real worker parser; 154-module corpus plus 3 bounded refusals; independent review approved | `c0f2e8f` |

Build: `cmake --build build --target boggart -j 6` with `CCACHE_DIR` and
`CCACHE_TEMPDIR` pointing inside `build/ccache`, because the default cache
directory is outside the workspace sandbox. Tests ran through `./boggart
--eval tests/<suite>.lua`, each with an isolated temporary profile. No paid
model requests or real messaging workflows were used.

The existing user changes to judge/TypeSafe, models and completion were
preserved outside these commits. The local runtime workstream BRAIN-3 is complete, including BRAIN-43 recovery.
BRAIN-19 historical Boggart, Claude and OpenAI log imports are complete. BRAIN-20 retention, redacted export and deletion are complete; the evidence workstream BRAIN-4 is complete. Local control authentication and unattended-default hardening are complete as BRAIN-16; the composition/policy workstream BRAIN-2 is complete.

The broader 57-suite run passed 53 suites on its first pass. MCP and control
needed loopback permission for their mock servers; permitted reruns passed
72 and 33 checks. Events and luatool were rerun after the reviewed sticky-budget
fix was embedded and passed 128 and 42 checks. The subsequently registered quota
suite passed another 52 checks. This is combined suite evidence, not a claim
that one uninterrupted 58-suite command ran green. GUI interaction and other
platform qualification remain open programme work.

The final BRAIN-13 build passed all 59 registered Lua suites in one uninterrupted
run using isolated profiles and permitted loopback mock servers. `invoke` then
passed twice under CTest's reused test profile after its quota fixture changed
to a unique temporary database. Voice transcription was skipped because its
model was absent; the suite verified the clean missing-model behavior. Studio
coverage uses the existing stub-window harness, not a real GUI session. This
build includes the preserved user work and is not a clean-checkout release
qualification.

BRAIN-17 final integration passed all 60 registered Lua suites in one uninterrupted
run. The initial run exposed a code-search ranking test whose corpus was the
changing repository; a fixed temporary corpus now checks real native relevance
ordering and incremental updates. Review also found sparse-array validation and
throwing output-validator accounting gaps; both are repaired with direct regressions
and demonstrated failing mutations. The same voice, GUI and platform limits above
apply. Provider adapters must actually enforce the ceilings they declare; concrete
remote-provider qualification remains in the integration tickets.

BRAIN-41 native verification covered all six affected suites. Mutation regressions
proved that adjacent 64-bit request integers stay distinct, stale suspended-provider
results cannot repopulate an invalidated cache, benign instrumentation does not
leak raw provider errors, and short resolution loops cannot evade the enclosing
instruction budget. Counter charging is conservative, not exact VM instruction
measurement. Context emits metadata/provenance; BRAIN-18 subsequently added separate redacted
evaluated-value persistence. This ticket did not rerun the full platform/release matrix.

BRAIN-42 has a real source-backed Slack-shaped fixture using only local capabilities;
the two inputs take different branches while retaining the same Lua source hash.
Trusted host closures are explicitly distinguished from portable source. Review
repairs preserve uncertain provider outcomes through optional, failure and cached
paths; source packages reject unversioned effects; and provider provenance uses
separate occurrence-scoped namespaces. Abrupt provider exits retain explicit
incomplete-effect evidence. Persistence and supported durable restart/resume were subsequently implemented
by BRAIN-18 and BRAIN-43. Historical imports were subsequently delivered in BRAIN-19; promotion evaluation remains open.
Normal live coroutine suspension and an in-process verifier do not imply them.


BRAIN-18 final integration passed all 63 registered Lua suites. The evidence suite
has 132 checks, including durable redaction of aliased credential tables, bounded
secret tracking, explicit omitted-key markers and interleaved nested invocation
correlation. A separate process-kill/restart fixture proved that committed starts
without observed terminals remain explicitly incomplete. Independent review found
and verified fixes for four gaps missed by the initial suite. Evidence is enabled
by default; capture failure refuses new effects and terminal-write failure remains
visible. Secret capacity exhaustion is sticky and operationally significant; see
[the evidence recovery limits](evidence.md). Capture does not provide crash resume,
historical imports or proof that every arbitrary Lua branch was observed.


BRAIN-43 final native verification passed all 64 registered Lua suites after review
repairs. Recovery reconstructs explicitly opted-in deterministic source, validates
exact per-workflow dependency bindings, and fences previous owners. A two-process
fixture reopens the standard SQLite quota ledger, reconciles a lost acknowledgement
by its original operation ID, and continues ordinary loop/branch code with one
remote write. Original pending reservations remain held and visible; effect
reconciliation does not claim accounting settlement. Cached bounded reads record
zero new provider usage while retaining historical usage and artifact references.
Review repaired per-workflow pin substitution and nil-vararg formatting gaps;
a separate regression also fixed explicit false capability arguments becoming
empty tables. See [durable recovery](runstore.md) for supported value semantics,
source restrictions, attempt limits, cancellation and accounting boundaries.

BRAIN-19 final verification used the rebuilt embedded binary without a source
overlay. Independent review found six gaps in the initial passing implementation;
fixes now cover escaped JSON credentials, batch-wide secret discovery, mixed-ID
mirror aliases across reopen/batch boundaries, omitted content, source metadata
and portable temporary paths. Imports remain explicitly selected bounded JSONL
exports (16 MiB maximum), imported observations are never verified successes, and
unknown formats retain coverage gaps. Identity without stable IDs remains inferred;
independently sliced repeated text is documented as ambiguous. Redaction learns
within each bounded batch; it cannot retroactively discover unknown credentials
in earlier committed batches. Known literal rules remain important. Linux/Windows
execution and overall product qualification remain open BRAIN-39 work.


BRAIN-20 final verification passed invoke, context, workflow, evidence, runstore,
imports and evidence_retention twice each under persistent CTest profiles on both
macOS and Linux ARM64 Clang19. Retention has 154 checks. Earlier full native66/66
and Linux65/65 runs preceded the final registry fix; final verification targeted
its affected suites. Independent review found and verified repairs for capture
failures surviving restart, nested ownership, repeatable tombstone fixtures and
pending gaps surviving garbage collection. Queues have per-store and aggregate
bounds; verified opaque store identity permits reconnection without guessing paths.
External deletion remains pending until an actual adapter acknowledges its job;
Gestalt integration is BRAIN-24. Logical deletion does not promise physical erasure
of WAL/free pages, returned values, exports or backups. Unavailable storage cannot
promise to persist an observation gap before a crash. See [retention controls](evidence-retention.md).


BRAIN-16 final qualification passed all 66 native Lua suites and all 65 Linux
ARM64 Clang19 CTest entries, followed by 17 native and 8 Linux affected suites
each repeated twice against reused profiles. Independent review found and
verified repairs for tail-called provider native admission, protected-close
authority narrowing and oversized-result spill compatibility. Generated source
has protected allocator ceilings and bounded native primitives; unsupported
worker allocators refuse restricted execution. This is application containment,
not an OS sandbox or attribution of arbitrary native memory. Trusted host modules
and explicitly injected host callables remain privileged. Existing duplicate
mbedTLS linker warnings are inherited; voice/real-GUI/Windows limitations above
remain. The known native worker C-hook interoperability repair is mandatory in
BRAIN-39, and narrowed deferred control authority remains required in BRAIN-35.

The same-profile durable replay suite now takes about 3.6 seconds on macOS;
BRAIN-16's first intermediate shared-string guard implementation took about
108 seconds. The repair avoids redundant replay hook scans when private VM
metadata proves the callee cannot expose identity, retaining the conservative
scan when provenance is unknown. This measurement is a regression check, not a
product-wide latency promise.


BRAIN-21 preserves the existing default ZMQ/native-tier degradation policy and
explicit MCP selection. Host-qualified versions snapshot schema/tool/transport
identity; they do not pin a remote daemon's code. Generic remote cancellation,
operation status, reconciliation, usage ceilings and policy enforcement remain
explicitly unsupported. Both transports share a proven integer range of
±999999999999999; larger values require strings permitted by the tool schema.
Malformed MCP outcomes stay uncertain, including empty content where the JSON
decoder cannot distinguish an empty object from an empty array; a valid empty
text block succeeds. No opaque raw JSON response is added to evidence.

The pre-review broad native run passed66/66. After the two MCP-boundary repairs,
the final six affected suites each passed twice on macOS and Linux, including
82 Station assertions and the actual native MCP client's stdio serialization.
A separate macOS STATION=ON build from a clean tracked-source snapshot plus the
final adapter files passed a local ROUTER fixture: discovery/schema, Unicode and
exact integer strings, maximum accepted numeric input, two-phase acknowledgement,
parameter immutability, invocation/operation correlation, pre-send refusal, lost
write reply and late-reply isolation. It observed11 unique correlated frames and
each intentional lost write exactly once. This is real native socket/client
qualification against synthetic fixtures, not a claim about a live Station
daemon's durable execution or remote writes. The fixture used temporary profiles
and local pinned dependency sources; no paid models or real external messages.


BRAIN-22 repairs both repositories. Station changes are on
`feature/boggart-process-evidence` in the isolated checkout
`.superpowers/station-forge`; the original dirty Station checkout was used only
for read-only build recipes/dependencies. The focused builds recompiled every
project translation unit from isolated source. This does not claim a full daemon
build, live MCP/ZMQ exporter parity or byte equality against an uncaptured
original-worktree snapshot. Existing macOS deployment-target/compiler/linker
warnings remain disclosed; no dependencies were downloaded or modernized.

Station now stores typed bindings/results with versioned JSON fields and tested
legacy reads. Unknown preconditions and missing checkers cannot establish
eligibility. Actual Ralph dispatch supplies current inputs; possibly effectful
failure cannot fall through to a model or another template. Actual VerifyCode
cannot erase the resulting terminal FAILED state. Its new registered standalone
CMake/CTest target compiled18 real support sources and passed9 assertions; the
prior unguarded implementation failed6 of those assertions. The target was
qualified using its exact CMake block with existing dependency properties, without
configuring the entire uninitialized sibling tree.

Bounded host redaction runs before new Station trace/execution persistence;
redacted traces cannot crystallize into executable literals. Unknown unlabelled
secrets cannot be universally detected. Boggart applies its own import policy and
retains redacted/truncated/missing coverage. Old callbacks without correlation
remain distinct uncorrelated results; inferred call positions and observed output
lengths remain explicit. Imported templates never inherit activation authority.
JSON null is explicitly represented; the current decoder's empty-array/object
ambiguity is disclosed rather than guessed.

Final verification includes Station203/74/124 assertions plus actual VerifyCode9,
Boggart imports704 and repeated native/Linux import tests. Evidence/retention
passed twice on both platforms before the final additive legacy provenance fields;
only imports changed afterward. Actual current, redacted and legacy C++ exporter
outputs passed Boggart SQLite ingestion on both macOS and Linux ARM64. All fixtures
were synthetic; no private history, paid models or real external messages were
used. The independent re-review approved all23 product files. BRAIN-23 durable
AIbyWire delegation was subsequently completed; BRAIN-24 Gestalt memory is now active.


BRAIN-23 qualifies the Python native SQLite backend through real MCP controller
wrappers. Boggart retains Lua control flow and a local binding from operation ID
to target, capability version, input hash and retained evidence. AIbyWire owns
retries and permanent atomic submission claims. A reserved `boggart:` ID
namespace excludes ordinary admissions before dispatch, including controller
trigger/external routes and startup recovery. In-flight ownership uncertainty
never authorizes client resubmission or automatic controller takeover.

Review found and reproduced an escaped-secret evidence leak and a mixed-profile
admission race; both now have RED/GREEN regressions and independent approval.
Exact public JSON is retained only after inspection of the full parsed response.
Sanitization removes the raw bytes and marks exact source unavailable; projected
Lua results explicitly disclose empty-array/object ambiguity.

The AIbyWire changes are committed on isolated branch
`feature/boggart-durable-jobs`; the original checkout and Python environment
remain unmodified. A disposable SDK environment qualified the resolver-selected
MCP1.30.0. Dependency acquisition used network access; the final lock consistency
check passed offline. Existing Pydantic/linker warning noise remains disclosed.
Remote policy/usage ceilings, compensation, Rust/external backends and arbitrary
worker exactly-once delivery remain unqualified. Tests used synthetic workers
and temporary profiles, with no paid models or real external messages.


BRAIN-24 completes the integration workstream BRAIN-5. The repaired Gestalt daemon is built from an isolated sibling worktree; the original installed binary remains unchanged and does not qualify restart recovery. Recovery refuses above 65,536 total DocStore records or duplicate ES identities. Actual search supports whole-document BM25 and scalar relationships, with advanced graph/vector modes explicitly unavailable. Two current-authority gaps found in review now have regressions. Existing dependency/header and duplicate-link warnings are disclosed; platform/release qualification remains BRAIN-39. BRAIN-25 Lua AST indexing is next and in progress.


BRAIN-25 pins unmodified tree-sitter v0.26.6 and tree-sitter-lua v0.5.0 with MIT/Unicode licenses and verified archive/file hashes. Native syntax validation never executes source; Lua owns lexical normalization and indexing. Input/work/tree limits are explicit; upstream allocation failure can abort the process, so this is not hard OS memory isolation. Three large repository modules were explicitly refused by resource bounds. Original vendor whitespace and existing compiler/link warnings are retained. BRAIN-26 process and fragment recognition is in progress.

BRAIN-26 remains in progress. Recognition now compares explicit dataflow,
identified branch outcomes and context dependencies, following an independent
review finding. The corrected 48-check suite passed twice on macOS and Linux;
actual recorded Lua workflow and producer-binding fixtures also passed. Re-review
found that cached children could conceal unsupported nested context dependencies.
The worker added a failing regression and reports 49 checks passing after the
focused fix. That final correction still requires parent re-embedding, covering
platform qualification and re-review before acceptance or ticket closure.

BRAIN-26 is complete in `8c4717d`. The final cached-dependency correction passed fresh native/Linux builds and the 49-check suite twice on both platforms, plus both recorded Lua integration fixtures. Independent review approved spec compliance and quality. BRAIN-27 parameterized Lua candidate compilation is now in progress.

BRAIN-27 now includes initial crystallization from native tool histories without an existing Lua workflow, as well as parameterizing source-backed workflows. The expanded implementation passed 80 checks twice on macOS and Linux, plus actual recorded novel, follow-up and source-free invocation fixtures on both platforms. Historical values stay outside emitted code; current context and explicit output bindings drive new runs. Candidate generation remains separate from evaluation and activation. Independent re-review is active. A later output-drift regression found that a missing bound field could reach a dependent capability; this guard is being fixed before acceptance.

BRAIN-27 is complete in `e3e5035`. Independent review approved the final bound-output guard; 94 checks passed twice on macOS/Linux, including provider ordering and false/zero preservation. All three recorded integrations passed both platforms, with final no-dispatch drift qualification. BRAIN-28 background and directed mining jobs is now in progress.

## BRAIN-28 complete; evaluation started

BRAIN-28 is complete in `90c7dbd`. Directed/background mining uses one durable, bounded worker engine for native trace crystallization and source-backed refinement. It preserves source authority and restrictive inherited permission state, fences concurrent cursor selection, and retries pending claim cleanup. Candidate identity includes execution contracts. Independent review approved after three regression fixes. Final 67 mining checks plus affected suites passed twice on macOS/Linux; actual separate-process restart/crash/cursor-race and source/authority/identity fixtures passed both. Deadline overruns remain measured/refused, not claimed as hard real-time enforcement.

BRAIN-6 mining milestone is complete. BRAIN-29 held-out evaluation is in progress; candidates remain inactive pending evaluation/promotion.

## BRAIN-29 complete; promotion started

BRAIN-29 is complete in `a235b1b`. The evaluator executes exact compiled Lua against isolated adapters, separates training/validation/held-out lineage, checks independent invariants and applicability, and accounts for learning/execution costs without treating unknowns as zero. Provider request/failure semantics were corrected after independent review. Final85 evaluator checks and affected suites passed twice on macOS/Linux; actual recorded source-free/source-backed, production provider/branch, cost, split-leakage and retention probes passed both. Reports explicitly distinguish isolated evaluation from production-runtime qualification and authorization.

BRAIN-30 automatic promotion, pinned versions and rollback is in progress. No workflows have been promoted by these tests.

BRAIN-30 complete (`ae9c36f`): durable version registry, restrictive auto/review/off promotion, staged rollout, immutable run pins and rollback. Independent review approved. Final 43 promotion checks plus evaluator/workflow/context/invoke passed twice on native macOS and Linux. Real production suspension/revocation/quarantine probes and two-process SQLite CAS/restart passed. Runtime qualification remains an explicit host responsibility. BRAIN-31 request recognition/current-context binding is next; programme 23/33 tasks and 46/66 criteria complete.

BRAIN-31 complete (`42a39fd`): ordinary request routing into eligible Lua workflows with current context, explicit bounded Lua planning fallback and terminal authority denials. Final38/context80/workflow87 twice on native macOS/Linux; prior eight affected suites twice. Actual recorded/compiled/evaluated/promoted request probes, shared metatable-provider reuse and scoped SQLite memory retrieval/deletion passed both. Independent review approved after provider mutation fix. Local retrieval uses declared vocabulary and optional scoped memory; it does not claim semantic equivalence. BRAIN-32 monitoring is next; programme24/33 tasks and48/66 criteria complete.

BRAIN-32 complete (`689bb75`): explicit terminal monitoring, durable pending observation/dedup, monotone quarantine, confidence and cost per independently verified outcome. Final33 monitoring checks and retention suite twice native macOS/Linux; prior6affected suites twice. Actual drift/quarantine/rollback, failed-write gap/reconciliation, fresh-process health/dedup, measured provider-cost cohorts and pending-only deletion probes passed both platforms. Independent review approved after retention guard fix. BRAIN-7 learning workstream done; BRAIN-33 Slack fixtures next. Programme25/33 tasks and50/66 criteria complete.

BRAIN-33 complete (`27f63aa`): authored Lua Slack follow-up with injected context, conditional/idempotent synthetic sends, current reply checks, durable recovery and factual reports. Independent review approved after fixing baseline equivalence. Final235 Slack checks and workflow suite twice native macOS/Linux; initial five affected suites twice after fresh builds. Parent separate-process concurrency/recovery and equivalent report probes passed both. Synthetic model calls11→4; independent parent cohorts10→4. Real Slack adapter and full-source promotion remain separate qualification. BRAIN-34 novel workflows in progress; programme26/33 tasks and52/66 criteria complete.
