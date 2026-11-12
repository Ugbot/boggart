# Boggart in the software factory and the Gestalt vision

2026-11-12. A note, not a plan: what the two Gestalt2 vision documents written today say about
this repo. Read-only against `origin/main` `a777c2e`; nothing in this repo changed. Full documents
in §4.

Which checkout is which: `~/boggart` is the main repo (`origin` = `github.com/Ugbot/boggart`).
`~/boggart-fabric` is a second checkout of the same remote on the local branch
`feature/fabric-console` (112 commits ahead of `origin/main`, not on the remote); that is where the
fabric worker lives (`lua/fabric/worker.lua`, `src/lzmq.c`, `src/bmsgpack.c`,
`tests/fixtures/aibywire/`). `~/boggart-console` has no remote. This note is on `origin/main`'s
lineage because that is what ships; it names the fabric branch where it matters.

## 1. The two visions in short

**The software factory** (Gestalt2 `docs/plans/2026-11-12-software-factory-vision.md`, branch
`docs/software-factory`): engineering and operations as one loop, one component per verb: Gestalt
observes, records and learns; **Boggart decides**; Task Engine acts (typed effects, exactly once,
approved when it must be); EDP says what is allowed; LLM Station knows the code; the control panel
is the floor. The rule: the model never touches systems; text in, text out; deterministic code
checks the proposal; Task Engine executes it; a human approves until history says otherwise.
Decisions run in three tiers: type 0 reflex, type 1 fast, type 2 thinking. Two planes: the 0MQ
fabric for control, chukonu streams + MarbleDB WAL for bulk data.

**The Gestalt vision** (Gestalt2 `docs/VISION.md`, branch `docs/vision`): one store and one engine
for everything an organisation knows and everything that happens to it; a proper agentic data plane
(agents as first-class users: context bundles with provenance, typed recorded effects, memory that
compounds); a proper agentic memory engine (convergent indexing on any table or field, a KB with
provenance at exact commits, lineage on every derived number); the warehouse and stream house as
they were supposed to be on day one.

## 2. What concerns this repo

### 2.1 Role: decide

Boggart is the harness, not a framework: "a tiny coding agent with a C core and an embedded Lua
runtime that the agent can rewrite at runtime"; the loop, tools, memory and prompt are Lua
(`lua/api.lua` `M.run_on` at 1750 and `M.run_turn` at 2103, `lua/loop.lua`, `lua/prompt.lua`). The
vision keeps it that way: small on purpose, able to run with none of the rest (local dev); factory
mode is a profile, not a fork (software factory §10 "stays separate").

### 2.2 Ownership matrix rows (software factory §3.2)

| Capability | Boggart | Notes |
|---|---|---|
| Agent turn (model, tools, permission mode) | **owner** | the only component that runs a model turn on the factory path |
| Durable execution, approval gate, typed effects | consumer | in factory mode every side-effecting tool is a `submit_task` with an effect class; `perm.lua` `smart` becomes "ask TE" |
| Policy evaluation on an effect class | consumer (pre-check) | EDP is the oracle; the proposal is shaped by what is allowed |
| Model routing, API keys, metering | consumer | Boggart's endpoint is EDP's AI gateway: "no component calls LLM providers directly" |
| Code intelligence | consumer | Station over MCP (`lua/llmstation.lua`) or the native ZMQ link (`src/lstation.c`, `lua/stationlink.lua`) |
| Knowledge base | consumer | `lua/story/kb.lua`, the read-only shared KB client (newest commit) reads the same KB the context worker does |
| Agent memory (recall, episodic) | (own copy) SQLite today → consumer | `lua/store.lua` (SQLite, FTS5) and `lua/memory.lua` move to Gestalt `storage.memory.*` (decided for the 0rail demo) |
| Identity | consumer | session principal from TE, mapped to Gestalt's principal model |
| Secrets | consumer | none held in factory mode; tools are `submit_task` |
| UI | (own copy) the console | the panel is the floor; `~/boggart-console` speaks its own BCP v1 |

### 2.3 Where it stands today (software factory §2.2, checked against `origin/main`)

- Tools: `lua/tools.lua` `M.register(name, def)` with JSON Schema `input_schema`; model-written tools
  via `define_tool` persist with provenance; the sandbox "is an application capability boundary,
  not an OS sandbox" (`lua/tools.lua:270`). `lua/perm.lua` modes auto / smart / manual / chat, glob
  rules, outside-workspace guard, headless decision path. `lua/policy.lua` compiles scopes and
  constraints. MCP hosting in `lua/mcphost.lua` + `src/lmcp.c`.
- Gestalt tools `gestalt_query`, `gestalt_graph`, `gestalt_lineage` against `POST /api/v1/<domain>`
  (`lua/gestalt.lua`, opt-in). `docs/aibywire.md`: `adapters.aibywire` delegates bounded jobs over
  the attached MCP connection (`submit_workflow_dag`, `get_dag`, `get_dag_status`, `cancel_dag`,
  `list_tools`) and checks capability and effect before registering a job.
- Fabric (on `feature/fabric-console` only): REGISTER / HEARTBEAT / TASK with acks, outbox,
  re-register on "Node state lost", failover across controller addresses; task types `boggart.run`,
  `boggart.tool.<allow-listed>`, `boggart.console.send`; `fabric.spawn_remote` places agents by
  `placement require/prefer`; golden protocol fixtures. So Boggart **is** a Task Engine worker, on
  a branch that is three weeks old and not merged.

### 2.4 Gaps the vision found here (software factory §2.2 "Missing", §11)

1. No panel integration: the console speaks BCP v1 over WS/ZMQ/aibywire streams, not the floor.
2. `bash` runs on the host behind the approval gate; the sandbox is Lua-level. In factory mode this
   does not matter (tools are `submit_task`); in local mode it does.
3. Memory is a local SQLite file, not in Gestalt.
4. The fabric is a fork; recent commits on main are BMUX terminal work, not agent intelligence;
   remote/team use pointed at a separate "Boggart Backbone".
5. The harness's own permission prompt is a second approval surface; the factory wants one.

### 2.5 Build-order items assigned to Boggart (software factory §7 #6, §3.7)

Four things, in order, to become a participant rather than a callee:

1. **Subscribe to streams.** The fabric worker handles TASK only. Add `SUBSCRIBE {stream, from}` on
   the same DEALER link so a session is driven by `alerts.<service>` or `factory.approvals` rather
   than polled. Backpressure: bounded inbox, drop-oldest with a counter, never block the heartbeat.
2. **Emit actions as effects, not tool calls.** Factory mode registers every side-effecting tool as a
   thin `submit_task` with a declared effect class; `perm.lua` `smart` = ask TE, and TE parks the
   node. Keep the harness's own prompt for local dev only. The Temporal rule, the Palantir rule and
   the talk's rule at once: the model can only ask.
3. **Be scheduled and placed by capability.** An agent is a worker with `capabilities = {"agent.sre",
   "agent.data"}` and labels (model, cost tier, data residency); `placement.require` pins an EU
   incident to an EU-resident agent on an EU endpoint. The council in `fabric.spawn_remote` already
   uses require/prefer; expose it to DAG authors.
4. **Approvals via the same gate.** `/trust`, `perm.lua` decisions and the console's approve button
   all become `approve_node` calls carrying the principal; no second approval surface.
   `boggart.console.send` already exists for the human side.

Then memory: SQLite becomes a cache over `storage.memory.*`; `lua/story/kb.lua` reads the same KB
as the context worker. Merge the fabric fork into main when (1) and (2) land. Shippable (§8.4): the C
binary + Lua bundle + fabric worker as one image; no host bash in factory mode; `.boggart/project.json`
+ a factory profile; tokens per session via the EDP gateway; the console read-only for support.

### 2.6 Open decisions that touch Boggart (software factory §12)

#3 typed effects mandatory for any task an agent may propose; #4 approvals carry a principal
(Boggart's own decisions are not approvals); #5 shared identity; #8 autonomy is earned per
`(class, resource)` from verified history, never granted per agent; #12 Boggart is type 2 only.

### 2.7 The tiers and the planes, applied here

- Boggart is **type 2**: investigation and proposal with the full context bundle, seconds to
  minutes, proposals only. A session never starts cold on something type 0 or 1 could answer and
  never without the lower tiers' records as the first line of the bundle. Every side effect is a
  `submit_task` with an effect class and the gate that class carries.
- The bundle (software factory §3.6) is built by a context worker, not by the agent free-wheeling:
  KB (`eng_kb.context`), telemetry (PromQL/LogQL/SQL scoped to the alert), code (Station
  `analyze_error` → `find_references` / `call_hierarchy` → `goal_plan`, plus the commit index once it
  exists), policy (EDP classification and the gates available). Bounded, content-addressed, stored
  as a Gestalt doc; the digest goes into `factory.proposals` with the prompt as sent and no tools
  field. The talk's shape to keep: whole graph ~110 KB, the map the model sees ~3 KB.
- Rule of Two per session: the proposer (Boggart) reads prod telemetry and has no credentials; the
  executor (a TE worker) has credentials and no model; the approver is a person with a phone.
- Boggart sits on the **control fabric** only; nothing bulky crosses it. Results that are rows go to
  MarbleDB through the ordinary CQRS/Flight door and come back as references.

### 2.8 Scale (software factory §8)

Single box: 1-4 sessions in-process with the panel. Cluster: pools by capability and label, placed
by TE, model endpoints via the EDP gateway. SaaS: shared pools, per-tenant labels and budgets,
residency by `placement.require`. Per-node Boggart SQLite is one of the things that breaks at the
first node loss; hence memory in Gestalt. Budgets everywhere (calls/min, calls/day, jobs,
wall-clock, tokens, dollars): a runaway loop hits a budget, not a credit card. The harness is a
versioned, measured artifact (§5.2): the harness moves scores 5-10 points at fixed model; the
Gestalt corpus of landed and failed attempts is the training set for a house critic.

## 3. Where the Gestalt side meets this repo

- Gestalt is Boggart's memory, KB, telemetry and code graph; what the agent recalled, proposed and
  learned is written back as memory, so the next incident starts with the last one.
- The 0rail medical demo (`memory/project_0rail_demo`): an agent harness using all of Gestalt2 as its
  memory engine, LOKF-native; Boggart over `storage.memory.*` is the harness.
- The fabric worker and the Gestalt tools already exist here; the vision's step is to make them the
  only door in factory mode.

## 4. Links

- Gestalt vision: https://github.com/Ugbot/Gestalt2/blob/docs/vision/docs/VISION.md
- Software factory: https://github.com/Ugbot/Gestalt2/blob/docs/software-factory/docs/plans/2026-11-12-software-factory-vision.md
- Observability product vision: https://github.com/Ugbot/Gestalt2/blob/docs/observability-vision/docs/plans/2026-11-12-observability-product-vision.md
- Distributed compute grid: https://github.com/Ugbot/Gestalt2/blob/plan/distributed-partitioning/docs/plans/2026-11-11-distributed-partitioning-plan.md
- This repo: `README.md`, `docs/aibywire.md`, `docs/capabilities.md`, `docs/control-surfaces.md`, `lua/gestalt.lua`, `lua/story/kb.lua`; the fabric on `feature/fabric-console` (`~/boggart-fabric`).
