# Durable process evidence

`require('evidence')` captures native runtime observations in the local SQLite
store by default. This is an observation log, not authorization, a workflow
runner, crash resume, or a complete recording of arbitrary Lua computation.
Existing session tables, record envelopes and bus journals remain compatible.

Trusted host configuration is explicit:

```lua
local evidence = require('evidence')
evidence.configure {
  enabled = true,                 -- false explicitly disables capture
  secrets = {'fixture-secret'},   -- literal credentials also redacted in free text
  inline_bytes = 16384,
  max_bytes = 1048576,
}
```

`db` overrides the default `bog.db` connection; `db=false` restores that default.
Tests may inject `wall` (Unix seconds) and `monotonic` (nanoseconds) functions.
Production durations use native `uv.hrtime`, which advances during CPU-only Lua;
wall timestamps use `os.time`. There is no wall-clock duration fallback.

An enabled invocation must durably record its start and admission before
calling the adapter. Storage failure refuses dispatch with `evidence_unavailable`.
After an effect has run, a dropped terminal cannot undo it: the ordinary capability
outcome remains authoritative, while `receipt.evidence.coverage='incomplete'`
and `error` expose the capture failure. `evidence.status()` reports enabled state,
a process-local failure count, redaction saturation status, learned-secret count/bytes
and conservative coverage. Failures also print a
fixed stderr diagnostic containing no raw payload or database error. Disabled
capture appears as `evidence_disabled` in receipts and permits normal execution.
Workflow snapshots expose `state.evidence`; any capture failure during the run's
lifetime conservatively makes its coverage incomplete, including failures from
concurrently running work. `observed` means the relevant boundaries were saved,
not that arbitrary control flow or every value was observed.

## Interface and schema

- `append(event) -> event_id | nil,error` appends schema v1.
- `read_run(run_id) -> ordered_events | nil,error` reads persisted append order
  and then deterministic derived incomplete-coverage records for unmatched starts.
- `artifact(id) -> value | nil` reads a decoded durable JSON artifact.
- `id(prefix)` generates a 128-bit OS-random ID; workflow, invocation and context
  resolution identifiers no longer depend on a process-local sequence.
- `begin(kind, correlation, payload)` and `finish(span,payload)` are host runtime
  helpers; a span carries its start event/error and monotonic start time.
- `redact(value)` produces a bounded serializable snapshot without inspecting
  metatables, opaque handles, userdata, threads or closures.

The envelope contains `schema_version=1`, `event_id`, `origin='native'`,
`provenance`, `run_id`, optional `step_id`/`parent_id`/`correlation_id`,
`attempt_id` (default `'1'`), `kind`, wall `timestamp`, and `payload` or
`artifact_refs`. Correlation labels must be nonsecret finite scalar labels;
labels changed by configured literal redaction are refused rather than rewritten
into ambiguous identities. Structural field names and native lifecycle kinds are
preserved. Only trusted hosts call the append API; it is not a historical importer.

The additive, idempotent module-owned schema consists of `evidence_events`
(sequence primary key, unique event ID, run ID and JSON body), a run/sequence
index, and `evidence_artifacts` (artifact ID and JSON body). It does not change
`store.SCHEMA_VERSION`. Artifact and event inserts commit in one SQLite transaction;
a failure rolls back both. Existing legacy records remain readable.

`*.start` and `*.terminal` join by correlation ID. An unmatched start produces
`coverage.incomplete`, `origin='derived'`, and
`payload.reason='terminal_not_observed'`. This means no terminal has been observed;
it does **not** declare a running process dead or its effect failed. Derived
records are never written back, so repeated readers, two live connections and
reopening after a crash cannot manufacture duplicate terminals. A later observed
terminal removes the derived incomplete record. No process takeover or resume is
performed. Read failures return an error, never a silently empty history.

## Runtime observations

Capture happens directly at the emitter before asynchronous observer delivery:

- Common invocation start: full redacted arguments, invocation/run/step parent IDs.
  Nested invocations and safe child coroutines inherit both the actual parent
  invocation ID and its run ID, including outside workflows.
  Admission: pinned descriptor identity, effect, target, policy revisions and
  enforced ceilings. Terminal: result and result type, error, authoritative receipt,
  status, usage, admitted/not-dispatched decision and duration.
- Context start/terminal: request, key, observed concrete value and source/provider
  resolution provenance, including cache and dependency/invocation IDs. Abrupt
  exits may leave an explicitly incomplete start. Providers remain executable
  closures, represented as unavailable rather than serialized code.
- Workflow start/terminal: pinned source hashes and versions, manifest, redacted
  injected context, source revisions, result, status and local verifier result.
  Explicit steps get parent IDs, return values and durations. Context entry on a
  child thread records its inherited parent. Safe generated-code coroutines inherit
  the emitter's workflow association; `ctx:call`/`ctx:resolve` establish the actual
  thread occurrence. Arbitrary host-created raw coroutines must explicitly enter a
  workflow context; no global “last run” is guessed.
- `ctx:observe('branch', value, links)` or `ctx:observe('dataflow', value, links)`
  provides optional author annotations. They are labelled `explicit_annotation`.
  Ordinary Lua remains ordinary Lua: unannotated `if` decisions and exact arbitrary
  value lineage are not inferred. Context dependency and invocation receipt links
  are observed; equal values alone do not create dataflow edges.
- New sessionlog entries use the same redacted snapshot before both evidence and
  legacy entry persistence. The evidence observation and legacy insert are separate
  transactions, not an atomic transcript checkpoint; legacy failures retain their
  existing return behavior. Batch/fork helpers now propagate append failures.
  Historical entries are unchanged. Live trace output is redacted before its
  bounded preview, which remains a preview rather than source evidence.

Storage helper instruction overhead runs outside enclosing Lua hooks so a budget
cannot interrupt a SQLite transaction. Each external helper entry first charges
one enclosing count-hook quantum, preventing short repeated observations from
resetting and starving the workflow instruction budget. This is conservative
accounting, not exact VM-instruction accounting.

## Redaction and coverage limits

Credential-labelled fields (password, secret, API key, token/access-token,
authorization and credential) become explicit redaction markers. Their string
values (and string keys within sensitive tables) are learned before sibling
free-text snapshots. A sensitive visit upgrades an earlier nonsensitive visit
to a shared table, retaining cycle protection; iteration order and aliasing
cannot bypass credential collection. Hosts must provide
additional known literal secrets for unlabelled free text; this module cannot
recognize every arbitrary secret string. Bearer credentials are masked. Numeric
`usage.tokens`, `input_tokens` and `output_tokens` remain available for mining.
Native credential handles remain opaque and are never extracted from the auth
store. This is not a retroactive scrub of the existing database, bus journal,
transcripts, provider logs or arbitrary application writes.

Redaction precedes both record and artifact serialization. Snapshots preserve
quotes, newlines, nested values and long strings within limits. Explicit markers
represent redacted, opaque, cyclic, nonfinite or truncated values; nil results
also have their observed value type. Structural limits are 32 levels and 20,000 visited values, with a configurable
aggregate string/payload byte limit (at most 1 MiB). Unrepresentable, truncated or
colliding keys produce a `partial` wrapper containing the retained `value` and
counted `omissions`; wrapper metadata cannot be overwritten by user keys.
Collisions include distinct keys redacted to one label and numeric/string keys
that JSON would stringify identically. No omitted entry becomes silent `{}`.

Configured and learned credential knowledge is bounded to 256 distinct strings
and 64 KiB combined, at most 8 KiB per credential. Learned knowledge uses a
membership dictionary and is never silently evicted. Replacing configured
literals does not erase learned knowledge. Input string size is checked before
literal scans. A redaction pass permits at most 16,777,216 conservative
input-times-needle byte-work units and 20,000 match occurrences. Exceeding these
limits, credential limits, or the safe credential-collection traversal limit
latches `redaction_blocked` for that module lifetime and refuses capture with
`evidence_capture_failed`; no unsafe partial event or artifact is written.
`configure` cannot clear that latch. Direct `redact` raises the fixed
`evidence_redaction_capacity` error. Enabled invocation start capture consequently
refuses dispatch. For recovery, replace raw credentials with opaque handles or consistently labelled
fields, supply the needed known literals within the limits, and start a fresh
runtime. Restart alone does not establish safe redaction for unlabelled echoes
of credentials absent from the new configuration. There is no automatic reset
or resume that could expose forgotten credentials. A long-running process that
learns more than the stated capacity will refuse subsequent enabled invocations
until this recovery is performed; it does not sacrifice secrecy to keep running.
Plain oversized nonsecret values may instead use explicit truncation markers,
but incomplete credential collection always fails closed. Large bounded JSON payloads use transactional local artifact references;
external adapter references are observations only and are never automatically
fetched, copied or certified durable. No hidden reasoning is captured. No external
send, model request or historical log ingestion is introduced.

Regression suite: [tests/evidence.lua](../tests/evidence.lua), plus workflow,
context, capability, invoke, quota, sessions, trace and luatool suites.

Historical imports use the separate [imports API](imports.md). Its scope-owned
observations are always imported, unverified, and outside `read_run` native
lifecycle coverage. Source references, alternate observations and unresolved
artifact/partial snapshots retain their limitations; historical tool outputs do
not establish invocation admission, complete terminal capture or verified success.
The importer uses the evidence redactor but writes its own atomic source/event/
checkpoint tables. Imported observations are never passed through `append`, which
continues to mean direct native capture.
