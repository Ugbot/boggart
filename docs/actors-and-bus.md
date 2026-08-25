# Actors, the bus, and control — a threaded runtime for boggart

Status: **design, agreed in interview 2026-08-25.** Not yet built. This is the
plan of record for making the agent runtime always-observable, always-
controllable, and unable to hang the whole process.

## The problem, named

boggart today is **one `lua_State` on one uv loop**, fully cooperative. Every
turn, sub-agent, loop iteration, parallel worker, and approval shares that loop.
Its own worker code already states the failure precisely:

> `src/lworker.c`: *"pure Lua compute that never calls recv()/stopped() cannot be
> preempted."*

So:

- **It can hang with no signal.** A `"block"`-parked actor whose wake never comes,
  an `"io"` wait a wedged server never answers, a loop/worker that stalls — all
  freeze the turn, and the *control plane is on the same loop*, so you can't even
  observe or kill it. `watchdog.lua` catches exactly one class (the 151:1
  think:output stall); every wait added since (block-latches, the loop's inline
  sub-turns and parallel pool) has no liveness check.
- **It's hard to observe.** Observability is real but siloed and incomplete: the
  studio's `SwarmView` tails the bus, the TUI has an activity strip, the CLI has
  the dash — three windows, no single structured stream. Worse, the new
  constructs (`loop`, inline sub-turns, parallel workers) run *under the
  coordinator's actor*, so they emit no distinct records — invisible until they
  return.

The honest floor: a CPU-spin in *C* (a stuck syscall) can't be caught in-process
at all — that's the nuclear-teardown / eventual-daemon case. But every class we
actually hit either streams or parks, so it's catchable with the design below.

## The shape (agreed)

- **Agent-free main thread.** The main thread does UI/UX/comms + the message
  broker + supervision only — *no agent work*. It leans on libuv's own thread
  pool (`uv_queue_work`) for its async I/O.
- **A worker-actor pool.** Every agent, loop, and risky tool runs on a worker: an
  OS thread with its **own uv loop** and its **own `lua_State`** (generalize
  `lworker`; borrow venus's actor discipline). A spin in one actor can't freeze
  the others or the control plane.
- **A real messaging fabric, pub/sub everywhere.** MPMC + IPC. Patterns:
  **PUB/SUB** (observe), **PUSH/PULL** (work queue / load-balanced dispatch),
  **REQ/REP** (control/RPC). Transports `inproc://` (rings) and `ipc://` (unix
  sockets → MCP servers, a daemon, llm-station later). Everything — turns, tools,
  loops, the supervisor — is publish/subscribe. Bytes only across the boundary.
- **Out-of-band control.** The supervisor sends pause/kill/steer/inspect over the
  fabric, delivered two ways: the **message** rides the ring (steer/inbox,
  consumed at safepoints) *and* an atomic **control flag** is polled by each
  worker's **`lua_sethook`** (count hook), so pause/kill land even mid-spin
  (kill = a clean unwinding error). Last resort: tear down the worker thread +
  state on a C-level hang.
- **The bus is observability.** Every unit publishes lifecycle / progress /
  wait-state / errors, with lineage + timestamps; anything subscribes (SwarmView,
  a TUI pane, `boggart trace`, the host); the journal persists the stream.
- **State.** Isolated actors share via the fabric, the store (SQLite
  `THREADSAFE=2`, one connection per thread — `lworker` already documents this),
  the blackboard (via messages), and deliverable files. Results return as bytes.

## Don't build it — port your own

This exact architecture already exists across venus, chukonu, and bolt. We port
and adapt, we do not reinvent (and we do not adopt ZeroMQ — "ok until it wasn't").

| Need | Source (exact) | Notes |
|---|---|---|
| **SPSC ring primitive** | `bolt::SPSCChannel<T,N>`; boggart `src/lworker.c` `wk_ring` | boggart's is semaphore-guarded, no atomics, no memory-ordering reasoning (the safe design `jwriter.c` argues for). Keep it; generalize to MPMC where a queue has many producers. |
| **Worker = thread + own uv loop** | venus `src/core/venus_actor.{h,c}` | `venus_actor_create/wait_ready/shutdown/destroy`, `venus_actor_wakeup` (= `uv_async_send`), `venus_actor_register_handle`, `venus_actor_loop`. Struct: `uv_loop_t loop; uv_thread_t thread; uv_async_t wakeup; uv_timer_t tick_timer;` + atomic `ready/shutdown_requested/shutdown_complete` (acquire/release). This is the mature version of `lworker`'s worker; **boggart's actor = `venus_actor` + `lworker`'s `lua_State` + rings.** |
| **Pub/sub bus** | venus `src/core/event_bus.{h,c}` | `event_bus_subscribe(type, cb, ud) -> id`, `event_bus_publish(event) -> bool`, `event_bus_process_events()`, `event_bus_has_subscribers(type)` (= our cheap `events.any()` guard), `event_bus_get_stats()`. Event: `{ type; uint64 timestamp_ns; uint32 source_system; union payload }`. **Generalize the fixed `EventType` enum → string topics + `*` patterns** (as `events.lua` already does). |
| **Thread pool / parallel fan-out** | venus `src/core/jobs.{h,c}` ; chukonu `exec/shared_scheduler.h` | `job_submit(fn,arg)` (fire-and-forget), `job_wait_all()` (barrier), `job_submit_range({fn,user_data,total_count,grain_size})` (parallel-for). Drives the `loop`'s `parallel:true` pool. |
| **PUSH/PULL work channels** | chukonu `exec/morsel_channel.h` | Load-balanced work distribution to the pool (a morsel = a unit of work). |
| **Always-observe rings** | chukonu `obs/thread_local_rings.h` | Per-worker `log` / `metric` / `span` SPSC rings, arena-allocated at startup, `try_push` PODs, a drain task is the sole consumer, **drop-on-full** (tally drops as a metric). The scalable version of `jwriter`'s single journal thread. |
| **Transport addressing (IPC/remote)** | chukonu `transport/channel_uri.h` | Aeron-style `aeron://<addr>:<port>?stream_id=N` → POD `{ipv4, port, is_multicast, stream_id}`. Tiger-Style: no alloc, bounded, ≥2 asserts/fn, never reads past `len`. This is the nng-like transport layer, already done. Adopt the scheme for our `ipc://`/`tcp://` naming when we go cross-process. |
| **Journal (persist the stream)** | boggart `src/jwriter.c` | Already its own thread (`g_thread`), `uv_sem` happens-before, no atomics. Becomes the drain-and-persist consumer of the obs rings. |

Language note: **venus is C on uv → ports directly** into `src/`. **chukonu is
C++ →** we borrow the *designs* (`channel_uri`, `thread_local_rings`,
`morsel_channel`) and re-expose them in C, or wrap a thin C ABI. **bolt's
`SPSCChannel`** is the reference for the ring; boggart already has an equivalent.

## APIs we'll expose

**C (in `src/`):**

```c
/* actor.c -- venus_actor + lworker's lua_State */
Actor *actor_spawn(const char *name, const char *source_or_role);
void   actor_post(Actor *a, const void *bytes, size_t n);   /* -> in-ring, wakes it */
void   actor_control(Actor *a, ActorCtl ctl);                /* PAUSE|KILL|RESUME, sets the sethook flag */
void   actor_join(Actor *a);                                 /* + last-resort teardown */

/* bus.c -- event_bus with string topics */
void   bus_publish(const char *topic, const void *bytes, size_t n);
int    bus_subscribe(const char *pattern, BusFn cb, void *ud);
bool   bus_has_subscribers(const char *pattern);
```

**Lua (each `lua_State`, main and workers):**

```lua
bus.publish(topic, data)              -- pub/sub, fans out via the C broker
bus.subscribe(pattern, fn)            -- "tool:*", "agent/42/*", "*"
bus.request(addr, msg[, timeout])     -- REQ/REP over the fabric
work.push(queue, item) / work.pull(queue)   -- PUSH/PULL

supervisor.pause(id) / .kill(id) / .steer(id, msg) / .inspect(id)  -- main-only
```

`events.lua`, the swarm bus, and `jwriter` all fold onto this — one substrate.

## Per-thread constraints (inherited from `lworker.c`)

These are load-bearing; the pool must respect them:

- **Nothing Lua crosses a thread.** Only bytes (strings/numbers; tables
  serialized). A `lua_State` is single-threaded, full stop.
- **luv binds a state to ONE loop.** A worker opens luv *first* so `require("uv")`
  is its own loop, never the main's. The main loop is touched from a worker by
  `uv_async_send` only (the one thread-safe libuv call).
- **Process globals stay on the main thread.** MCP stdio servers (`lmcp.c`), the
  swarm bus, `bog.db` as a Lua value — a worker touching them is a data race;
  worker states get erroring stubs (as `lworker` already does).
- **SQLite `THREADSAFE=2`, one connection per thread.** curl-on-uv: each worker
  owns a private `curl_multi` on its own loop — N threads, N loops, N multis —
  which is what lets a worker run a model turn.

## Phased build (each phase ships standalone; nothing regresses)

1. **Bus + obs.** Port `event_bus` (string topics) and `thread_local_rings` into
   `src/`; expose `bus.publish/subscribe`; fold `events.lua` / swarm-bus /
   `jwriter` onto it. **Delivers: observe-everywhere. No threads moved.** Prove
   with a `boggart trace` that tails the bus.
   - **Shipped (2026-08-25):** `src/lbus.c` = the pub/sub bus (string topics + `*`
     patterns, `has`/`stats`) **and** named work queues (`push`/`pull`/`qlen`),
     one `uv_mutex`, MPMC-ready; global `bus`; `tests/fabric.lua`. `events.lua`
     folded on (`events.emit` mirrors onto the bus when `bus.has(name)`;
     `events.any` counts a bus subscriber). `lua/trace.lua` + `/trace` +
     `BOGGART_TRACE` tail it live. 40 suites green, core-parity green.
   - **Deferred to Phase 2** (each needs the worker threads to earn its place, so
     it belongs with the pool, not before it): folding the **swarm-bus**
     (`lswarm.c`'s per-actor mailboxes — a working, separately-tested C subsystem
     whose O(1)-middle-removal mailbox semantics differ from pub/sub) and
     **`jwriter`/`thread_local_rings`** (per-worker obs rings have no per-worker to
     live on until the pool exists). `thread_local_rings` is a Phase-2 port.
2. **Actor pool + safepoint control.** Port `venus_actor` + `jobs`; give each
   actor a `lua_State` (from `lworker`); add the `lua_sethook` control flag and
   the supervisor's pause/kill/steer/inspect over the bus.
   - **Shipped (2026-08-25):** the pool already exists as `src/lworker.c` (OS
     thread + own uv loop + own `lua_State` + SPSC rings). Added:
     - **Safepoint kill** — a `LUA_MASKCOUNT` hook on the worker's own thread
       trywaits `kill_sem` every 100k VM instructions and unwinds a runaway
       pure-Lua source (`ok=0`). The main thread only `uv_sem_post`s, never
       touches the worker's state — sidestepping the `lua_close` race the v1
       comment named. `worker.kill()`; status/list report `killed`. Closes the
       "cannot be preempted" gap. Test: a `while true do end` worker is killed
       and joins.
     - **Cross-thread bus** — a worker `bus.publish` enqueues bytes and the main
       loop's drain async dispatches them on the main state (the MPMC/IPC path).
       `bus.attach_main()` from `activate_agents`. subscribe/attach denied in
       workers.
     - **Pool observability** — `lworker` emits `worker:spawned/killed/exited`
       via C `bus_emit`; `BOGGART_TRACE='worker:*'` shows the pool live.
     - **Supervisor control plane** (`lua/supervisor.lua`) — control is now ON
       the bus, using both primitives: the work queue `supervisor.cmd` is the
       ordered MPMC command channel (any thread enqueues; only main executes),
       and pub/sub is the cross-thread wake (`supervisor.wake`) plus the
       observable `ctl:*` stream. `pause/resume/kill/pause_fleet/kill_all/
       kill_worker`; installed from `activate_agents` (and the studio's
       `setup_swarm`). The cTUI and swarm dashboard drive `bog.supervisor.*`
       (direct-sched fallback) instead of poking `sched` — one observable path.
       The studio's SwarmView (stop-all + targeted kill) and AgentView
       (cancel-turn) now route through `bog.supervisor.kill` too (existence guard
       via `sched.alive`; operator kill so a coordinator's `await()` unblocks).
     - **Worker pause/resume** — the same hook parks the worker on `resume_sem`;
       both stop() and kill() also post it, so no teardown path deadlocks on a
       pause. `worker.pause/resume`, status `paused`, `worker:paused/resumed` on
       the bus, `supervisor.pause_worker/resume_worker`. The control set is now
       complete: **stop / kill / pause / resume**.
   - **Remaining:** dressing `lworker` with `venus_actor`'s lifecycle/tick + a
     `jobs` primitive is infra ahead of a consumer (the existing spawn/post/recv/
     onmessage + `workers.map` cover today's needs); revisit when something wants
     periodic ticks or a persistent actor.
3. **Move a workload onto the pool.**
   - **Shipped (2026-08-25):** `bog.worker.map(fn_source, items, opts)` — a real
     parallel-for (N threads, N cores) built entirely on the fabric's work queues
     (items in, workers pull-compute-push, this side drains). Scheduler-aware: it
     parks on a latch + uv timer inside a turn, blocks-with-poll off it. This is
     the pool running real, controllable, observable work — the payoff that makes
     the safepoint kill / lifecycle / cross-thread bus real, not test-only.
   - **Sub-agents on the pool — SHIPPED.** `bog.worker.agents(prompts, opts)`:
     each prompt runs a full model turn on its own worker thread and the
     assistant text comes back. A worker stands up its own scheduler
     (`sched.drive`) and drives `run_on` over its per-loop `curl_multi`. The
     blocker this hit — a worker that did http couldn't cleanly exit, because the
     loop-owned `curl_multi` keeps a completed connection's keep-alive socket poll
     *referenced* (which is what lets the main scheduler sleep on the socket at
     zero CPU) so the worker's teardown `uv_run()` pinned open — is fixed
     properly: `src/lhttp.c` now tracks live socket polls in a list and
     `boggart_http_shutdown` closes them (and flushes the deferred closes), wired
     into `lworker`'s teardown (before the run-out for a plain worker, before
     `lua_close` otherwise). Exposed as `http.shutdown()`. The main scheduler is
     untouched — shutdown runs only at teardown, never during operation, so
     sleep-on-socket keeps working (verified: main streaming unchanged). Verified
     live: 3 sub-agents on 3 threads return distinct answers and the pool drains.
     - Trade-off, recorded: the one-loop scheduler already multiplexes many turns'
       HTTP concurrently, so this mainly wins when sub-agents also do CPU-bound
       work; for pure model calls the cooperative swarm fan-out is as parallel.
   - **Not pursued:** rewiring the `loop`'s `parallel:true` mode onto threads —
     same low value (its items are IO-bound; `map`/`agents` cover the rest).
4. **Agent-free main.** Move the coordinator onto an actor; main becomes pure
   supervisor/UI/comms.
5. **Prove it.** A deterministic bench (mock wire) that reproduces a Lua spin, a
   never-answered wait, and a stalled worker, and **asserts the safepoint kill
   fires** and the bus shows exactly where it stalled.

## Risks / open

- MPMC + IPC is real concurrency work — the exact ARM memory-ordering trap
  `jwriter` and `lworker` deliberately dodge with semaphores. Prefer the
  semaphore-guarded design over lock-free where a queue's producer/consumer count
  allows; reach for atomics (acquire/release, as `venus_actor` does) only where
  measured.
- `lua_sethook` overhead: a count hook every N instructions has a cost; N is
  tunable, and only worker states need it (the main state carries no agent).
- Cross-process (`ipc://`, the Aeron URIs) is Phase-6+; v1 is `inproc://` threads.
- Deciding what a supervisor "kill" does to in-flight work (checkpoint vs discard)
  — reuse the exit-contract / checkpoint machinery already in `thread.lua`.

## Why this is the right bet

Every hard part is already solved in your own code, on the same libuv model, and
argued for in the very comments (`jwriter`'s "no atomics, here's why";
`lworker`'s "can't be preempted"; `channel_uri`'s Tiger-Style bounds). We are
assembling a proven runtime from proven parts, not researching a new one.
