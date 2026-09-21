# Explicit local history imports

`require('imports').ingest{source={path=...,root=...,session=...},format='claude',
scope='project:example',redaction={literals={'known credential'}}}` imports one
explicitly selected regular JSONL file beneath its realpath-resolved root. Formats
are `claude`, `openai` (observed Codex rollout variants), `boggart`, and `station` (versioned forge exports). An empty
literal list is an explicit policy choice; labelled credentials and bearer values
are still redacted by the evidence sanitizer. Paths are opened directly, never
passed to a shell. No discovery, directory sweep, upload, tool execution or model
call occurs. File content, permission metadata and claimed project paths grant no
authority. Select scope from the caller's authority, not from imported content.

Return: `{added,duplicates,quarantined,checkpoint}` or `nil, fixed_error_code`.
`max_records` defaults to 500 (maximum 2,000); `max_bytes` defaults to 1 MiB
(maximum 4 MiB) per batch. Repeat until the checkpoint reaches the source size,
or `partial`/`blocked_record` indicates waiting for a complete line/a larger batch
limit. This first adapter version accepts exports no larger than 16 MiB; each
call reads and hashes at most 16 MiB plus one sentinel byte. Split larger exports
explicitly; include their session metadata or set `source.session`. Records above
256 KiB are individually quarantined, including a single oversized record beyond
the batch byte target, so later records remain reachable. A final line without a
newline is held, even if syntactically valid JSON. Append its newline to finalize.

`read(scope)` returns normalized observations and every duplicate's source
reference. `quarantine(scope)` returns fixed diagnostic reasons, source IDs,
SHA-256 record/file hashes and zero-based byte offsets/one-based record offsets;
it never returns or persists malformed raw text. Unsupported record types appear
there as `unsupported_record`; unsupported Claude conversation blocks become explicit
`coverage.omitted` observations. OpenAI message blocks retain `content_omissions`
and missing/partial value provenance. Source selection failures return fixed codes
without payload/path diagnostics. `configure{db=connection}` selects a trusted
SQLite connection; otherwise storage uses `bog.db`.

## Identity, coverage and retention

All normalized records have `origin='imported'`, `verified=false`, explicit scope,
provider/session identity, schema/adapter versions and observations-only coverage.
Original timestamps remain original (and explicitly missing when unavailable).
Boggart legacy `ts` is retained; native step/attempt, source provenance, origin
and artifact references live under `source_observation` without changing trust.
Missing outputs have `output.provenance='missing'`; observed tool outputs do not
prove execution success or a verifier outcome. `read` joins requests and outputs
by provider/session/scope-qualified operation identity. It makes no temporal or
value-equality inference about branches or effects. Codex completion summaries
are `context.summary`, never additional tool operations or billable usage. Usage
records are currently quarantined rather than added into native cost accounting.
Valid function-call JSON strings are decoded, sanitized structurally and serialized
back to JSON. `representation.kind='canonical_sanitized_json'`,
`original_bytes_preserved=false` and inferred representation provenance make clear
that the original escaped bytes are not retained; changed values also carry
redacted value provenance. This prevents Unicode/quote/backslash spellings from
preserving recoverable credentials. Invalid JSON remains observed text under the
explicit literal policy. Unsupported conversation blocks have content omission
counts and missing/partial value provenance, including image-only and mixed
text/private-reasoning messages.

Explicit provider event/call IDs supply logical identity. OpenAI response/completed
message lanes also maintain durable, scope-owned mirror aliases using unredacted
content hashes and lane occurrence counts. A missing-ID representation can join
its corresponding explicit-ID mirror in either order across batches/restarts;
`observed_ids` and source references retain provider IDs. Existing differing
explicit IDs never merge through a missing-ID alias. Repeated identical messages
have separate occurrence slots. Alias matching is inferred correlation, not a
claim of provider-certified equivalence. Otherwise canonical
content plus occurrence number supplies an **inferred** identity. Boggart legacy,
native transcript and session-checkpoint lanes count occurrences separately, so
three representations of a transcript join one logical message while repeated
messages within a lane remain separate. Fallback identity cannot distinguish
unidentified, identical repeated messages in independently sliced overlapping
exports; import whole session exports when stable IDs are absent. Session IDs
must be observed or supplied; records without one quarantine as `session_missing`.
No session authority is inferred from filenames or log project paths. Separate
scopes/providers/sessions never share a payload row. Provider IDs are retained in
observations; sensitive session IDs are refused, rather than ambiguously rewritten.

A duplicate retains source provenance. If the same logical ID has differing
normalized content, the source reference includes `observed_variant`; the initial
observation is not silently replaced. Consumers must inspect variants before
assuming a single unambiguous value. Boggart artifact markers are unresolved
missing values; partial/redacted/truncated snapshots remain markers and are never
reconstructed from prose. Native lifecycle kinds are prefixed `historical.`;
imported gaps never produce native `coverage.incomplete` terminals. Imports do not
write `evidence_events` or merge with native runs. Native and historical views are
separate datasets; downstream union readers must deliberately handle their overlap.

Additive SQLite tables are `import_sources`, `import_events`, `import_refs`,
`import_quarantine`, `import_checkpoints`, `import_aliases` and `import_tombstones`. Every row carries
scope ownership; aliases store only hashed identities and fixed lane tags, while reference/variant payloads share their event's scope. Checkpoint
transactions commit normalized events, references, quarantine and byte position
atomically. A writer lock or checkpoint race rolls back the whole batch. Prefix
SHA-256 validation detects truncation/replacement and replays through stable dedup;
restarts restore session/occurrence state. Changing a source's redaction policy is
refused pending explicit migration, because earlier rows would otherwise retain
old policy bytes. Redaction or snapshot-limit errors leave its checkpoint intact. Every bounded
pending batch first learns labelled credentials from all normalized observations,
including source metadata, before any event/alternate variant is serialized.
Source path redaction and scope/session checkpoint checks run after that discovery.
This does not retroactively scan older committed batches for newly discovered
unlabelled echoes; supply necessary literals before importing that history.

`tombstone(scope)` persistently blocks further imports into that scope, including
new file paths and provider/session IDs. This is the BRAIN-20 retention seam:
write it **before** deleting scope payloads/checkpoints and `import_aliases` rows. It does not itself delete
rows or hide them from `read`; deletion/export UI and downstream index/cache sweeps
belong to retention work. There is deliberately no automatic tombstone reset.

## Concrete Boggart export route

The adapter reads actual public record/checkpoint shapes. In a trusted host Lua
script, explicitly select a run and session, then serialize existing API results
to your selected export file. For example (replace IDs and path deliberately):

```lua
local json = require('json')
local selected_run = 'your-selected-run'
local selected_session = 123
local out = assert(io.open('/your/selected/export.jsonl', 'wb'))
local function line(value) out:write(json.encode(value), '\n') end
for _,record in ipairs(bog.store.records_for(selected_run) or {}) do
  if record.kind == 'entry' then line(record) end
end
for _,event in ipairs(assert(require('evidence').read_run(selected_run))) do
  if event.origin == 'native' then line(event) end
end
local checkpoint = bog.store.sess_load(selected_session)
if checkpoint then
  -- Explicit caller association; selected_run must be this checkpoint's run.
  line{session_id=selected_run, messages=checkpoint.messages}
end
out:close()
```

The export may contain sensitive history: select/redact it according to your
policy and do not check it into a repository. Import does not open arbitrary
historical SQLite databases or resolve exported artifact IDs against the current
native database. Use separate exports/scopes for unrelated sessions. Exported
legacy `payload` and checkpoint `messages` may be JSON strings or decoded values.
Synthetic examples and regression cases are in `tests/fixtures/process_logs` and
`tests/imports.lua`; none were copied from private transcripts.


## Station forge exports

`format='station'` accepts `schema='station.forge'`, `schema_version=1` envelopes
with `kind='ActionTrace'` or `kind='ActionTemplate'`. Station's existing
`forge_manage` tool exposes `action='export'` with exactly one `trace_id` or
`template_id`; save its successful structured data as a JSONL record. Select an
export file per session; templates use the session `station-template:<template_id>`.
A trace without a source session uses `station-trace:<trace_id>`. These derived
names scope observations and never grant authority. Unknown schema versions,
malformed containers and duplicate step/result orders are quarantined.

Trace headers retain task/model metadata and count missing and orphan results.
Requests/results correlate by a hash of trace ID, step order and tool name within
the selected scope/session. Both identity and call correlation are explicitly
inferred. A result with a different tool name cannot satisfy the request merely
because its order matches. Legacy results with `step_order=-1` remain separate,
positionally identified observations without call/operation IDs; repeated ambiguous
results never satisfy an outstanding request. Legacy sequence-order provenance
and observed output lengths are retained without inventing output content. Trace-level timestamps do not invent per-call timing.
Missing outputs stay missing; truncated outputs carry partial provenance.
Station source-redaction flags and redacted output states retain redacted
provenance; import does not replace these gaps with complete-value claims. Artifact
references remain observed data; importing does not fetch their content.

Typed arguments, nested outputs and explicit producer/result JSON pointers remain
searchable data. Imported templates are `historical.station.template` observations
with `activation_eligible=false`, even if Station reports an active status. Lua
compilation/evaluation/promotion must independently establish applicability and
permission. Imports always declare unavailable native policy, usage, verifier,
context-resolution, code-revision and redaction evidence; source metadata does
not supply those guarantees.

The current Lua JSON decoder does not distinguish empty arrays from empty
objects. `representation.ambiguous_empty_container_paths` records every such
location rather than inventing a type. JSON null becomes an
`{import_value_type='json_null'}` value and is disambiguated from literal objects
by `representation.null_paths`; paths use JSON Pointer escaping and zero-based
array indices. Consumers must consult the paths when reconstructing values.
`original_bytes_preserved=false` is explicit, and normal redaction may further
remove data. These are observations suitable for analysis, not a byte-identical
round-trip format. Changed content for the same trace/template identity retains
an `observed_variant` through the normal import mechanism.
