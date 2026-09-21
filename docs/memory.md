# Scoped memory and evidence indexing

The existing `memory.list`, `index_text`, `remember`, `recall`, `forget`, and
`promote` APIs retain their SQLite project/global behavior. They do not upload
stored notes or private histories. The scoped index is a separate, explicit
host-installed port over the same local database; local rows remain authoritative.

## Host integration

```lua
local memory = require('memory')
local port = memory.open {
  db = bog.db,
  scope = project_scope,                    -- host-derived ownership
  authorize = function(scope, operation)    -- current local source authority
    return host_source_policy(scope, operation)
  end,
  context = invocation_context,             -- existing invoke/policy/quota gates
  export = true,                           -- omit for entirely local operation
  base_url = 'http://127.0.0.1:8080',         -- explicit, trusted deployment
  confirm_stopped = host_proves_owner_stopped,
}
memory.install(port)
port:put {
  source_id = 'character:ada', source_ref = 'novel:chapter:3',
  source_span = {start=12, finish=45}, text = 'Ada meets Bo.',
  kind = 'character', relation = 'knows', target = 'Bo',
  code_version = 'sha256:...', step = 'scene', context_ref = 'cast@4',
  ast_features = {calls={'scene'}},
  source_refs = {'novel:chapter:3', 'process:scene@2'},
}
local hits = memory.search('Ada', {
  scope=project_scope, filters={kind='character', relation='knows'}, limit=10,
})
local checkpoint = memory.sync()
```

`open`, `install`, adapter construction, and recovery are privileged host APIs.
Do not expose these modules, the database, authority callbacks, or a capability
registry to generated Lua. Inject only the narrow port functions it needs.
A caller-supplied scope can only match the bound host scope; it grants no access.
An inherited invocation scope must also match, even for entirely local lookup.
The required `authorize(scope,operation)` checks current source authority for
`read`, `write`, `sync`, and `recover`; it must incorporate applicable current
local restrictions. It is additional admission, not a replacement for invoke.
Remote calls always pass through versioned capabilities and invoke's current
policy, approvals, quotas and evidence gates. Denied remote permission can leave
an independently authorized local lookup available. Denied local source access
never becomes fallback access.

Construct one adapter per endpoint/store/scope per host process; duplicate
capability registration is rejected. Separate stores get random persistent
namespaces. A complete SHA-256 namespace/scope identity encoded as base64url gives
a 46-byte index name, within Gestalt's actual 48-byte limit. This partitions
candidate retrieval before ranking. It is not server tenant authorization:
only deploy to an endpoint whose administrators/credentials are authorized for
all explicitly exported data. No public-service or cross-tenant security claim
is made.

## Local source contract

`put(document)` returns a monotonically increasing local revision. Repeating
identical canonical content does not create a revision. `source_id`, `source_ref`
and `text` are required; `source_span`, code versions, AST features, steps,
context references and relationship metadata remain attached to returned hits.
`run_id`, if present, must already belong to the bound retention scope. Unknown
observations must remain explicit in supplied metadata; indexing does not infer
unobserved branches, missing evidence, or promotion qualification.

Evidence redaction runs before local persistence or transmission. Sensitive
identity fields are rejected, not silently relabelled. Text is bounded to 64KiB,
serialized documents to 128KiB, metadata nesting to 16, additional source
references to 64. Persisting a row does not export it until `sync` is called with
export enabled. There is no automatic history importer.

`remove(source_id)` writes an idempotent local deletion tombstone.
`remove_source(source_ref)` invalidates every indexed document whose primary or
additional source reference names that source, and prevents re-importing it.
A host must call this when a source is removed independently of scope retention.
Scope deletion/import tombstones clear indexed payloads transactionally via
SQLite triggers, deny later admission, and preserve dirty deletion work.
These are logical deletion guarantees; physical disk erasure is not claimed.

## Retrieval and coverage

`search(query,{scope,filters,limit})` returns
`{hits,provenance,backend,coverage}`. Hits are hydrated from current local rows,
with source IDs/references/spans, scope and revision; remote text is never trusted.
The adapter rejects foreign-index/scope replies before they reach invocation
evidence and passes only validated identity/revision/score metadata upward.
Stale revisions and tombstones are rejected again against authoritative rows.
Data-bearing remote invocation evidence belongs to the source retention scope.

Supported filters are exact scalar `kind`, `code_version`, `step`, `dependency`,
`context_ref`, `relation`, `target`, and `source_ref`. Relationship lookup is
one-hop metadata filtering; it is useful for steps/dependencies/character links,
not an arbitrary graph language. Gestalt's actual ES compatibility implementation
supports named-index BM25 and boolean term predicates. BM25 analyzes the whole
JSON document, not just the `text` field, with the current engine's 4,096-token
per-document and 64-byte per-token bounds. This port does not claim vector search,
semantic similarity, multi-hop traversal, field-specific BM25, or automatic
embedding generation. Unsupported search modes return empty hits and explicit
coverage rather than invented advanced results.

A successful validated search response establishes live availability; no
fictional discovery endpoint or Elasticsearch engine version is inferred.
Outage, denied transport, or disabled export leaves bounded local literal
substring lookup plus scalar filters (at most 256 local candidates). Coverage
reports pending rows, rejected stale hits, backend/mode, fallback truncation and
advanced availability. Results never claim complete recall. The ranked remote
page can shrink when local revision checks reject stale candidates; index lag
is visible rather than hidden by an unbounded refill.

## Sync and recovery

`sync(cursor)` returns `{scope,namespace,status,pending,acknowledged,...}` and
processes at most 32 dirty rows. A checkpoint is advisory: local revision/ack
state determines work, so a fabricated or stale cursor cannot skip deletions.
Calls use real `PUT /{index}/_doc/{stable_id}`, `DELETE` on that path, and
`POST /{index}/_search`. IDs are full SHA-256 of source IDs. No expiring HTTP
idempotency cache or fictional conditional-version support is assumed.

Only one synchronizer owns a scope at a time. Ownership is durable and has no
unsafe TTL. Database transactions stay short; none spans invoke/network work.
Updates made during a remote request remain dirty unless the exact revision
was acknowledged. Lost replies are uncertain and retain ownership: a late remote request must
not race a newer revision or deletion. After quiescence is proven, retry sends
current local state with the stable ID. A crashed synchronizer leaves `status='busy'` and an
owner token. After the trusted host proves that process/worker has stopped **and all its remote requests are
quiescent** (for example, both client and daemon have been stopped/restarted),
`port:recover_sync(owner)` releases it through the configured `confirm_stopped`
predicate. Then ordinary `sync` resumes from newest rows/tombstones. A caller's token, local PID exit, or elapsed time alone does not prove ownership is abandoned.

Deletion invocation evidence uses opaque document IDs in a separate maintenance
scope so source deletion can complete without recreating source payload. Run
cleanup outside an incompatible active source-scoped invocation; inherited
scope restrictions are never widened for cleanup.

Gestalt deployment qualification must include restart identity reconstruction.
The originally installed daemon forgets its ES projection on restart despite
keeping durable source rows, so it does **not** satisfy permanent dedup/deletion.
BRAIN-24 qualifies an isolated sibling repair with fresh native daemon restart,
client restart, lost-ack recovery, current-revision replacement, deletion,
retention cleanup and outage fallback. Use that repaired Gestalt source; the
previously installed binary remains unmodified. Recovery explicitly refuses
more than 65,536 total shared DocStore rows or duplicate durable ES identities.
Explicit mapping definitions and empty index persistence are outside this repair;
inferred mappings reconstruct from durable documents.
