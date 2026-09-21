# Durable AIbyWire delegation

`adapters.aibywire` delegates bounded jobs while the surrounding workflow remains
ordinary Lua. It uses an attached native MCP connection and the Python
controller's existing `submit_workflow_dag`, `get_dag`, `get_dag_status`,
`cancel_dag`, and `list_tools` query contracts. It does not use Station's different
ZMQ envelope or switch transports after a lost reply.

## Host setup

```lua
local jobs = require('adapters.aibywire').new {
  mcp = bog.mcphost.conns.aibywire,
  id = 'local-aibywire', -- stable endpoint identity across client restarts
  db = bog.db,
}
assert(jobs:discover(authority))
local descriptor = assert(jobs:register('format_text', {
  id = 'jobs.format_text', version = '1', effect = 'write',
  resources = derive_resources, -- trusted host extraction from original inputs
  retry_policy = {max_attempts = 1},
}))
```

Discovery itself passes through a read capability named
`aibywire.discovery.<id>`. It checks the live MCP tool list (including profile
restrictions), the actual worker `ToolSchema` catalog, and the qualified backend
contract. Registration requires a host-qualified version and effect class.
Remote GOAP `effects` are not authorization. Unsupported JSON Schema keywords
are refused by the existing capability registry; a transport cannot supply
missing effect or resource authority.

A trusted host can instead use `register_dag {id, version, effect, resources,
input_schema, build}`. `build(args)` returns an ordinary static DAG definition
with `nodes`; node task names must be discovered. This is a bounded remote job
template, not serialized Lua code. The host qualifies the aggregate effect and
resource scope of every node and the template's input schema. Dependencies use
the existing `depends_on` and `{"$ref":"node.result.field"}` representations.

## Lua calls and receipts

```lua
local submitted = jobs:submit(authority, descriptor.id, descriptor.version,
  job_input) -- workflow ctx:call also uses this registered capability
local operation = submitted.receipt.operation_id
local observed = jobs:reconnect(authority, descriptor.id, descriptor.version,
  job_input, operation)
local cancelled = jobs:cancel(authority, descriptor.id, descriptor.version,
  job_input, operation)
```

`status` is an alias for `reconnect`; both read the retained job through
`get_dag`. `invoke` aliases `submit`. For a durable workflow, `ctx:call` uses the
existing runstore operation identity and its reconciliation hook. A workflow
that awaits completion can poll the registered reconciliation operation from
host-injected functions, interpret the receipt in Lua, and choose its next step.
The adapter never adds a polling, submission retry, or compensation loop.

A successful *invocation* means the submission or observation was acknowledged.
`outcome.result.state` describes the job: `running`, `succeeded`, `failed`,
`cancelled`, or `uncertain`. The receipt includes `backend`, `remote_run_id`,
`operation_id`, `result`, `artifacts`, `policy_ack`, `usage_ack`, and
`retry_owner`. Result is the runtime world-state dictionary, including each
node's `result`; artifacts are currently empty. `policy_ack` and `usage_ack`
are explicitly false. Remote monetary/token ceilings and compensation are not
qualified; registration with `bounded` is refused. Local policy/quota admission
still applies and must encompass all delegated attempts and resources.

The remote ID is `boggart:<operation_id>`. Before dispatch, SQLite stores the
endpoint, operation/remote IDs, capability-and-input SHA256, and evidence run
reference. Arguments/results are not duplicated in that identity table.
Evidence records the same identity before waiting for the reply. Persistence or
redaction failure refuses dispatch. Reconnect/cancel require exactly the original
arguments, check the retained evidence run, and re-evaluate current authority.
Cancellation has a separate `<capability>.cancel` write capability. Source/run
deletion invalidates the identity through evidence retention checks.

A lost or malformed submit reply is an uncertain invocation, with its operation
ID in the standard invocation receipt; reconnect using that ID. It is never
proof of failed execution. Reconnecting cannot submit a new job. Repeated
explicit same-ID submissions are checked against the retained input identity
and the backend's permanent atomic claim, including after terminal completion.

## Qualified backend and limits

| Backend | Qualification |
| --- | --- |
| Python native runtime + actual `SqliteStore` | Atomic retained submission claims, static worker DAGs, status/reconnect, conservative cancellation, backend-owned retries. |
| Python memory/Redis/other stores | No claimed atomic durable delegation support. |
| Rust native / LittleHorse / Restate / EDP | Not qualified by this adapter; discovery refuses them. |

The opt-in backend marker is `definition.context.boggart_delegation =
"boggart-durable-v1"`. It accepts 1–128 static nodes, at most 128 concurrent
nodes, and 1–10 attempts per node. Normal worker-reported failures may use the
AIbyWire retry loop. The simple `register` helper defaults to one attempt; a
host must qualify repeat safety before enabling more. Worker results must follow
the backend protocol (one terminal report per attempt); arbitrary duplicate or
stale worker reports are not an exactly-once worker guarantee.

The `boggart:` DAG-ID namespace is permanently reserved: qualified jobs must
use it, and ordinary jobs cannot use it. Controller admission checks this before
trigger/external-runtime handling, native registry admission checks it before
any storage await, and restart refuses ordinary reserved-ID checkpoints while
continuing to resume other ordinary jobs. Thus mixed-profile admissions cannot
race for a shared checkpoint identity.

Claims use SQLite `INSERT OR IGNORE`, are committed before executor creation,
and have no TTL. Running state is committed before each worker dispatch. SQLite
must remain on a suitable local filesystem and retained claims must not be
manually deleted while clients may reconnect. This is one claimed submission,
not a distributed exactly-once effect guarantee. Client restart reconnects to
the same remote job. Controller restart retains nonterminal observations as
uncertain and never takes over or redispatches an opted-in job: there is no
worker fencing/ownership-takeover protocol. Terminal observations remain usable.

An in-flight cancellation or dispatch exception remains uncertain; late
successful completion can resolve it to succeeded. Cancellation before dispatch
can be confirmed. Cancellation does not undo completed effects. Worker deadlines,
inbound trigger nodes, Airflow payloads, approvals, node idempotency keys,
dynamic injection, and compensation are unqualified in this profile. These
features use other ownership/replay mechanisms; the profile rejects relevant
definitions and never executes dynamically returned extra nodes.

The Lua/native JSON boundary qualifies strings, booleans, dense arrays, objects,
and finite numbers within ±999999999999999. Decimals must round-trip through
Lua's 14-significant-digit JSON encoder exactly. Unsupported values are refused
before dispatch; use strings for larger/exact numbers. Empty input arrays are
restored from worker schemas; omit empty `depends_on` to use the server default.
Nested result nulls and unqualified numeric results produce uncertainty rather
than silent projection. Lua tables do not distinguish empty result arrays from
empty objects. Every observed receipt therefore includes `result_representation`
with `format="lua-json-projection"`, `empty_container_kind="unavailable"`, and
`exact_source="response_json"` only when the entire parsed controller response
is unchanged by evidence redaction. The privacy check covers fields outside
`delegation` and decodes escaped secret values before inspecting them. In that
case `source_status="exact"` and `response_json` preserves exact response text,
including `[]` versus `{}`. If sanitization changes any content, the adapter
returns the sanitized delegation, omits the opaque response entirely, and marks
`exact_source="unavailable"`, `source_status="redacted"`. It never labels
sanitized JSON as an exact original. Consumers requiring the container
distinction must respect this coverage instead of inferring it from the
projected `result` table.

## Verification

`tests/aibywire.lua` covers admission, stable identities, lost replies,
reconnection, malformed receipts, cancellation races, numeric refusal, and
explicit unsupported acknowledgements. The sibling real-SQLite suite
`taskengine/tests/dag/test_durable_delegation.py` covers separate connections and
processes, duplicates, ID/input conflicts, terminal retention, crash windows,
pre-dispatch checkpoints, multi-node dependencies, retries, and cancellation.
Native MCP transport qualification uses an isolated Python MCP 1.x SDK; the
controller's `mcp.server.fastmcp` integration is not compatible with SDK 2.x.
