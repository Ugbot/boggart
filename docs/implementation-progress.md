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
