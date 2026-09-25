# boggart × LLM Station: first-class ZeroMQ integration

Status: plan of record (2026-09-05). Tracker: BSTAT.

## What this is

An opt-in, C-implemented native client for LLM Station's ZeroMQ daemon protocol,
so boggart can use a running station *properly* — LSP-quality queries,
as-you-type completions, deep tool access, streamed events, and local-host LLMs
via station's provider layer — instead of only through the MCP stdio adapter.

The MCP mount (`lua/llmstation.lua`, ~116 tools as `mcp__llm-station__*`) stays
— its purpose is MCP-friendliness and exercising the MCP path, and that purpose
survives. But the transport rule is absolute, not a preference: **when the ZMQ
client is built and a daemon is reachable, everything that uses LLM Station
uses ZMQ. It never connects over MCP.** There is no mixed mode and no
silent MCP fallback; if the daemon goes away, station-backed tools degrade to
boggart's native tiers (bm25, grep, no-completion), exactly as if no station
existed. Forcing MCP remains possible explicitly (config/env) for testing the
MCP path — that is a test switch, not a runtime fallback.

Principles, in priority order:

1. **Strictly optional.** No ZMQ dependency in the default build; no runtime
   behaviour change when absent. `BOGGART_STATION=OFF` is the default and CI
   never fetches libzmq. The stub module is always compiled (the
   `BOGGART_VOICE` doctrine): `station.built()==false` and every front end
   hides the affordance. boggart must run identically with no llm-station
   binary installed, none running, and — hardest — one that **crashes at any
   moment**: mid-request, mid-stream, mid-connect. Daemon death is a normal
   state, not an error path.
2. **Lua keeps primacy.** C moves bytes; Lua decides. The module is transport +
   enforcement per docs/control-surfaces.md §1 — framing, msgpack, fd
   integration, correlation. Policy (which tool, when, fallbacks, UI) is Lua.
3. **One loop.** The socket rides the interpreter's uv loop via `ZMQ_FD` +
   `uv_poll` (the lhttp.c pattern). No second reactor, no dedicated receive
   thread in the default design.
4. **Boundary, not fabric.** docs/actors-and-bus.md:65 rejects ZeroMQ *as
   boggart's own messaging fabric*; that decision stands. Here ZMQ is a peer's
   native wire protocol spoken at the process boundary — the same sense in
   which lhttp.c "adopts" HTTP. actors-and-bus.md gets one clarifying sentence
   to that effect.
5. **Bolt transport: out of scope.** Grinning, but no.

## Why not just MCP

The MCP path is stdio JSON-RPC through a spawned gateway process. The ZMQ path
is a direct DEALER to the already-warm daemon:

- No child process, no stdio framing, no JSON-RPC translation layer.
- Access to the **query channel** (inline on the daemon's poll thread —
  microseconds of work, no thread spawn, no outbound-queue hop), which MCP
  cannot reach. This is what makes as-you-type viable.
- **Topic pub/sub** (`sub "chat.*"` → `token` events) for streaming, which the
  MCP tool surface flattens into one-shot results.
- Access to protocol features the MCP surface doesn't expose (chat sessions,
  confirm flows, model_load, goal/context events) — the "reach in and do cool
  stuff" layer, e.g. station's heavy C++ planning/indexing machinery.

This also positions the commercial story: boggart stays a lean single binary;
a running station is the bolt-on power pack it attaches to.

Relationship to docs/ds4-abi.md: complementary, not competing. The ds4 ABI is
in-process model inference; this is cross-process access to station's tools,
indexes and providers. A local model served *through* station arrives via this
transport; a model linked *into* boggart arrives via the ds4 ABI.

## The protocol (already exists — reuse, don't invent)

Spec: llm-station `src/daemon/DaemonProtocol.h` (193 lines). One ROUTER per
workspace bound by the daemon; clients are DEALERs with a distinct
`routing_id`. Many clients per daemon is native (CLI, TUI, MCP gateway, tray
already attach concurrently).

Frames (DEALER side — libzmq handles the identity frame):

```
[empty] [channel] [correlation_id | topic] [payload]
```

Channels: `cmd` (fire-and-forget + later result), `query` (inline, fast),
`sub`/`unsub` (topics), and inbound `result`/`event`/`error`. Payload is a
msgpack map `{msg_type, tool, payload}` where `payload` is a **flat
map<string,string>** — no ints, no floats, no nesting on the wire. A C encoder
needs three msgpack primitives (fixmap, str, nothing else). Unknown keys are
ignored, missing keys default: forward/backward compatible by construction.

Footguns to encode in the C client, not in reviewers' memories:
- ROUTER sees 5 frames, DEALER sends/receives 4. Off-by-one = silent drops.
- Two error keys: protocol errors in `payload["error"]`, tool errors in
  `payload["err"]` + `ok="false"`. Check both.
- `ZMQ_FD` is edge-triggered: after every wake, drain `ZMQ_EVENTS` in a loop
  until empty; readiness does not imply a message. Getting this wrong presents
  as intermittent hangs — the exact bug class docs/async.md exists to prevent.

Endpoint discovery: canonicalize the workspace root (never a `build/`
subdir — a stale `('/Users/…/boggart/build', 7703)` row already exists in the
wild), then `SELECT port FROM projects WHERE path=?` against
`~/.llm-station/config.db` (resolution order: `$LLM_STATION_HOME` →
`$XDG_DATA_HOME/llm-station` → `~/.llm-station`). A miss means "no station" —
do **not** reimplement the C++ `std::hash` port fallback; it is
implementation-defined. boggart already vendors SQLite.

**One daemon, one store — the workspace collapse.** The intended model is a
single station daemon (they are heavy; one can serve everything) with one
MarbleDB store partitioned by workspace. The code is not there yet: today is
one daemon + one marble tree per workspace, ports allocated per path in
`config.db`, and llm-station's ADR-019 §6 names the migration ("workspace
collapse") and defers it to a follow-up ADR that does not exist. This plan
includes writing that ADR and landing the collapse (epic P6). The boggart
client is built forward-compatible from day one: discovery is a function
(`path → endpoint`) so today it returns the per-workspace port and tomorrow a
single well-known endpoint; every request site is prepared to carry a
`workspace` payload key once the protocol grows one. Never reimplement the
port hash fallback (implementation-defined *and* a collision hazard — an
unregistered path can hash onto another workspace's live port): a missing
`projects` row means "register first or no station". Ignore the `port+1`
events endpoint in `CLIEndpoint.h` — vestigial, and it overlaps the next
workspace's command port.

Liveness: the daemon's port bind is the real mutex; PID files are advisory.
boggart only ever *connects* — it never binds, so the historic studio
bind-race (studio/data/core/studio.lua:76) cannot recur from this client.
Attach-don't-spawn is the default; autostart stays where it already lives
(`lua/llmstation.lua`) and stays single-start.

## Architecture in boggart

New C module `src/lstation.c` (global `station`), one ledger row in
docs/control-surfaces.md §2. Follows the established patterns exactly:

- **Build**: `option(BOGGART_STATION … OFF)`, libzmq static (pinned tarball +
  SHA256, per the one-file rule — no system lib). libzmq is C++, so the option
  does `enable_language(CXX)` exactly as `BOGGART_VOICE` already does. Stub
  compiled unconditionally; `station.built()` / `station.available()` always
  present. A `build-station/` scratch tree per the build-* habit.
- **Loop integration**: per-interpreter context in the state registry
  (lhttp.c `get_ctx`), `uv_poll` on `ZMQ_FD` with edge-triggered `ZMQ_EVENTS`
  drain, `uv_unref` so an idle connection never holds the loop open.
  Mandatory exit-safety hook `boggart_station_shutdown(L)` called before
  `lua_close` in both `src/boggart.c` and `studio/src/main.c` (the raw-handle
  `luv_close_cb` type-confusion trap).
- **Handles**: `"boggart.station"` connection userdata + `"boggart.stationcall"`
  request userdata (child pins parent in a uservalue; `close` and `__gc` the
  same idempotent fn). Requests yield `("io", handle)` via `lua_yieldk` — the
  lmcp.c pattern — so `conn:query(...)` reads synchronously and stays
  cooperative. Studio needs no new pump: `uv.run("nowait")` in core.step
  already covers loop-resident handles.
- **Events**: `sub` topics are delivered as bus events
  (`bus_emit("station.<topic>", json)`) so both the CLI scheduler and the
  studio (which already calls `bus.attach_main`) consume pushes the same way.
  Streamed chat tokens ride this.
- **Workers**: sockets are per-loop like `http`, not process-global like
  `mcp` — a `zmq_ctx` is thread-safe, sockets are not; each interpreter that
  wants one makes its own. (Decision recorded here so lworker.c's
  `deny_in_worker` line doesn't need to grow.)
- **Non-blocking connect**: a `pumpConnect`-style async connect+ping handshake,
  rate-limited; a down daemon never hitches a keystroke or a frame.
- **Crash tolerance is the contract, not a feature**: boggart runs its own
  liveness — a periodic `query`/`ping` (~5 s) with a missed pong meaning
  *down* — because the audit showed station's own clients cannot be trusted
  here (their `isConnected()` never leaves Connected on daemon death; the MCP
  gateway just eats a 30 s timeout per call against a corpse). Every
  outstanding request carries a deadline; a dead daemon (send fails, ping
  times out, socket errors) fails all in-flight handles with a clean
  `nil, err`, emits one `station.down` bus event, and flips the module to a
  reconnect state with jittered backoff. ZMQ's DEALER reconnects transparently at the socket level
  (`linger=0`), but *correlation state does not survive* — pending corr_ids are
  garbage after a daemon restart and must be failed, never re-awaited.
  Subscriptions are re-issued after a successful re-ping (`station.up` event).
  While down, station-backed tools degrade to native tiers instantly — no
  queueing, no retry storms, no MCP fallback.

Lua surface (sketch — final shape decided in the Lua tickets):

```lua
local st = station.connect()            -- nil, err when not built/available
local r  = st:query("smart_complete", {file=f, line="42", column="7", prefix=p})
local h  = st:cmd("tool_exec", {…})     -- ack now, result later via h / bus
st:subscribe("chat.*")                  -- events -> bus "station.chat.*"
```

Selection policy lives in `lua/station.lua` and is binary: ZMQ built + daemon
reachable → all station traffic is ZMQ and the MCP mount is not connected;
otherwise no station (native tiers). The explicit force-MCP switch exists only
to test the MCP path. Doctor surfaces the state next to the existing
code-search backend chain line. `tools.register_fallback` gains the ZMQ tier
for `code_search` and friends — same logical tool names, and the chain below
it is the *native* floor (bm25, grep), not MCP.

## Search goes to the station (`lua/searchroute.lua`)

When the ZMQ link is up, code search is answered by the daemon. The model
searches through `bash` (grep -rn / rg / find -name account for almost every
lookup; the dedicated `code_search` tool was chosen zero times in a sample of
recent sessions), so routing happens at the `bash` tool:

- A bash command that is a *plain search* becomes `grep_search` or
  `glob_search`. Fidelity decides what is plain: one path, a filename glob,
  context lines, `| head -n N`, and a pattern that means the same in
  ECMAScript. Anything else (`-i`, `-v`, `-l`, several paths, shell globs,
  BRE operators, pipes into other tools, redirects) runs in the shell as
  typed. `tests/searchroute.lua` pins the mapping.
- A daemon failure is never an answer: the shell runs the command instead.
  A station "nothing found" is a miss too (its parsers do not index every
  language; Lua symbols are absent), so the next tier looks.
- First-class tools: `symbol_search` and `find_references` (AST-aware via the
  daemon, word-grep floor), plus `code_search` (now `active()`-driven and
  passing `top_k`, which station reads; `limit` was ignored). These are
  read-only and run their grep floor directly, so they never trip the bash
  approval gate. While the link is up the system prompt names them.
- `BOGGART_STATION_SEARCH=0` turns routing off, for comparisons.

### Starting the daemon from boggart

`/station [status|start|stop|restart|autostart on|off]`. `start` launches
`llm-station start --workspace <cwd>` fully detached and waits for the
socket (a cold daemon indexes before binding: ~40-90s on this repository).
`autostart on` (kv `config.station.autostart`) launches it the first time
anything wants the link and never waits. The binary is the NEWEST match
among the known locations, not the first glob hit (an old build-mcp binary
launched but did not speak the current protocol).

Measured on this repository, daemon warm: scoped searches (`lua/`) answer in
50-170ms vs 10-50ms for local grep; `grep_search` is a single-threaded
`std::regex` walk, so a search over `src/` (vendored libs) took ~6s and a
repo-root search hit the 30s call timeout. It walks `build*/` (2.7GB here) --
it skips only dot-directories. **Station-side follow-up:** make grep_search
skip gitignored paths (or answer from the index) so unscoped search is cheap.

## Station-side work (llm-station repo)

Narrow, well-scoped upgrades the survey identified; each is its own ticket:

1. **Completions over `query`** — today `smart_complete` (sub-ms of work) rides
   `cmd`: ack round-trip + a detached `std::thread` per request + outbound
   queue + ≤100 ms poll tick. Adding `smart_complete`/`lsp_query` to
   `handleQuerySync` makes the round trip ~1 ms. Highest-leverage change in
   the whole plan.
2. **Unsaved-buffer support** — `lsp_query` re-reads from disk per call;
   `smart_complete` reads the index. Neither sees the live buffer. Add a
   `text`/buffer-overlay param. The real blocker for as-you-type.
3. **Structured output** — tools return prose ("Line 42: Error: …") that
   clients regex-parse, losing columns. Add `format=json`.
4. **Local OpenAI-wire providers** — `OpenAIProvider.cpp` hardcodes
   api.openai.com and nothing plumbs `base_url`; Ollama/vLLM/llama-server are
   unreachable today. Honor and plumb `base_url`. This is the "local-host LLM
   via station" piece.
5. **Cancellation** (stretch) — no cancel msg_type exists; stale in-flight
   completions can only be ignored client-side via request_id.

## Borrowing from the station GUI

Borrow **algorithms and interaction design**, restyled to boggart. The NED-fork
editor (`src/editor_app`, ~91k LOC ImGui) was surveyed in full; the render
layer is the antithesis of studio's dirty-rect rencache (one AddText per
character, an ImVec4 per byte of file) and must not be ported — but the
algorithms are mostly pure and port directly. What this milestone takes:

- **Ghost text as real buffer bytes painted with a ghost color**
  (`ai/ai_tab.cpp`): the completion is spliced into the buffer for real and
  dimmed via color, so all layout/cursor/scroll math just works; accept =
  recolor, word-at-a-time accept (Cmd+Right) is pure index arithmetic. This
  supersedes a literal port of the unwired `EditorProtocol` ghost overlay —
  keep its *protocol* logic (300 ms debounce, live-buffer prefix extraction,
  the prefix-guard rule: only insert a suffix when the top label
  case-insensitively starts with the typed prefix, request_id staleness,
  smart_complete → llm_query → completion_extract fallback), use ai_tab's
  *representation*.
- **The Cmd+K inline-edit flow** (`ai/inline_prompt.cpp`, ~400 lines,
  complete): no selection → expand to current line so it always has something
  to act on; ±40-line surrounding context; async request; strip code fences
  (models fence even when told not to); prefix/suffix line diff (deliberately
  not Myers — LLM edits are one contiguous region); Accept/Reject splice with
  a forced discrete undo step. Station-powered in boggart via `ai_edit`.
- **The pure @-mention parser** (`ai/mention_parser.cpp` + `chat_grounding.h`):
  conservative preceded-by rule (kills user@host), 9-kind classification,
  resolver-callback expansion, and the contract that *expansion rides the
  outgoing payload, never the visible bubble*. Ready to transliterate to Lua
  for the composer.
- Studio seams already exist: `autocomplete.add{}` for DocView completions
  (items already carry a second `info` column), `agentcomplete`/`bog.complete`
  for the composer. Hard rule preserved: the completer runs inside a keystroke
  and must never block or raise — fire-and-forget, bus delivery,
  `core.redraw = true`.

General editor steals not tied to this integration (fold display-row
indirection, debounced coalescing undo with prefix/suffix diff ops,
merge-conflict CodeLens, the one-rect-per-line minimap, adaptive event-timeout
frame pacing, 9-slot cross-file bookmarks, find-all → multi-cursor) are filed
under BSTUD, not here.

## Doc changes shipped with the code

- `docs/actors-and-bus.md` — one sentence distinguishing fabric (still not
  ZMQ) from boundary interop (this).
- `docs/control-surfaces.md` §2 — ledger row for lstation.c with the
  "what breaks if the agent rewrites this" answer.
- `docs/runtime-plan.md` / `docs/comparisons.md` — station is no longer
  MCP-only; note the transport tiering.

## Testing and acceptance

- `tests/station.lua` in the CMake suite: the not-built and daemon-absent
  paths never raise and return booleans (model: tests/llmstation.lua).
- With a live daemon (manual/opt-in CI): ping over query, smart_complete
  round-trip, sub + token event onto the bus, kill-daemon mid-request →
  clean error, reconnect works.
- Studio: ui-discover requires a menu entry; ui-check/ui-bench must show no
  frame regression with the feature off *and* on-but-daemon-down.
- Doctor shows: built yes/no, daemon found/port, transport in use per tool
  tier.

## Phasing

- **P1 Transport core** — build option, msgpack codec, DEALER client,
  discovery, uv_poll integration, handles, shutdown hook.
- **P2 Station upgrades** — query-channel completions, buffer overlay,
  format=json, base_url. (Parallel with P1; different repo.)
- **P3 Lua policy** — station.lua selection policy, fallback-chain tier,
  doctor, subscribe→bus.
- **P4 Studio as-you-type** — autocomplete provider, composer ghost text,
  menu entry.
- **P5 Hardening & docs** — tests, exit-safety audit, doc updates, ledger row.

## Capability adapter (BRAIN-21)

Trusted host Lua can use `require("adapters.station").new{workspace=path}`.
Call `:discover()` to read the current tool descriptions and schemas, then
`:register(tool_name, {id="station.my_tool", version="host-qualified-1",
effect="read", resources=host_resource_function})`. Invoke through
`:invoke(context, id, version, arguments, {operation_id=stable_id})` to use the
normal capability admission, quota and evidence boundary. Do not expose adapter
construction or registration to generated Lua. Unclassified effects default to
`unknown` and require approval; effect/resource qualification belongs to the
host, not the remote description.

Versions are explicit host-qualified identities, **not** negotiated Station
capability versions. The immutable descriptor records the discovered schema,
remote tool, selected transport and workspace. A host must qualify a new version
when that contract changes; Station cannot pin the daemon implementation or prove
that a restarted daemon runs the same code. ZMQ schemas are the daemon's actual
`tool_schema` text (types and required fields), which omits enums/defaults that
standalone MCP may advertise. MCP discovery retains its JSON schema; unsupported
schema keywords fail registration instead of being silently removed.

The adapter selects ZMQ by default. Missing/dead native transport reports
`transport_unavailable` with `receipt.execution.fallback="native"`, meaning the
existing local code-search tiers remain usable; it does not dispatch another
capability automatically. `BOGGART_STATION_FORCE_MCP=1` selects MCP explicitly
before constructing an adapter, using an already attached MCP connection.
`llmstation.autostart()` also requires that setting to mount MCP. Neither path
switches transport or retries an uncertain invocation.

Both paths support string-keyed flat arguments containing strings and Lua
integers in [-999999999999999, 999999999999999] (at most 15 decimal digits).
The native MCP client reserializes numbers through cJSON using `%.15g`; larger
integers can become exponent-form JSON, which Station treats as a floating
number and formats differently from ZMQ. Pass larger values as explicit strings.
Booleans, nested objects/arrays,
fractional/nonfinite numbers, out-of-range integers and non-string keys are refused
before transport dispatch. This conservative common subset avoids the native
encoder's silent omissions and the MCP bridges' differing float formatting.
The discovered schema is still validated by the capability layer. Workspace
routing is injected into a copy, leaving caller arguments untouched.

`stationlink.request(tool, args, options)` is the structured transport entry
point; `stationlink.call()` retains its legacy value/protocol-map or nil/error
shape. Outcomes retain protocol maps or MCP result objects and structured error
codes. Local run/invocation/operation IDs are recorded in execution receipts;
remote tool metadata (including a tool's own `run_id`) remains under `remote`.
MCP execution receipts also retain `content_shape`, distinguishing null and
malformed shapes even when JSON sentinel objects lose identity while copied.
Raw JSON is not duplicated into receipts or malformed-response error messages;
structured fields remain available to normal evidence redaction. Content must be
a nonempty dense array of text blocks; malformed shapes remain uncertain.
Because the JSON decoder cannot distinguish empty objects from empty arrays,
both empty content forms are refused. Station's valid empty text block succeeds.
The native request correlation is verified internally by `lstation.c` but is not
exposed by its Lua API. Neither transport exposes a durable operation identity.
The adapter therefore marks remote correlation unavailable and does not insert
unsupported correlation/policy fields into tool arguments.

`:features()` reports the MCP client's actually negotiated protocol version when
available. ZMQ protocol negotiation, remote capability versions, generic tool
cancellation, per-operation status, reconciliation and remote policy enforcement
are unsupported. `:cancel()`, `:status()` and `:reconcile()` return explicit
`unsupported` errors; daemon health `status` and chat-specific `chat_stop` do not
provide these guarantees. Local admission remains enforced, but remote policy
and usage ceilings are not claimed.

A missing connection or native nil request handle proves pre-send refusal. A
request exception, failed send, timeout, malformed reply or remote tool error
does not prove that a write had no effects. Such outcomes remain uncertain and
must be reconciled externally before another effectful attempt. Disposing a
native handle is not cancellation of server work.

`tests/station.lua` uses synthetic ZMQ/MCP responses, the real native msgpack
codec and the existing local Python stdio MCP fixture. Actual native MCP wire
traces verify numeric type/representation at the accepted boundaries and prove
refused values generate no tools/call frames. No live writes, daemon, paid model
or external MCP service is required. It
covers discovery, parity, correlation, refusals, uncertain writes and explicit
transport selection. The optional native socket qualification is separate.
