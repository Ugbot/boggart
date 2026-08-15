# boggart's async IO — the plan (settled)

## The one idea

Everything boggart waits on — model HTTP, subprocesses, MCP stdio, timers, the
keyboard — sits on **one uv loop per actor-group**. It's all actors; a group of
coroutine-actors shares a loop (and that loop's `curl_multi`), and an actor that
needs real isolation gets its own thread → own loop → own `curl_multi`. Then
"wait for the next thing to happen" is a single **bounded** `uv.run`, and the
only difference between a CLI that blocks to completion and a UI that paints at
60fps is the timeout you pass. Nothing ever blocks the loop; nothing ever blocks
user input.

## Decisions (grilled)

1. **Full one-loop.** Integrate `curl_multi` into libuv. One reactor, permanent.
2. **Per-loop curl — "it's all actors."** No global `g_multi`; each interpreter's
   uv loop owns a `CURLM`. Fixes the main loop (the freeze) and is the mechanism
   that lets any actor's loop do async HTTP. (Lifting the worker `http.begin`
   denial follows for free later; not required for the fix.)
3. **Refactor first, verify after.** Build the curl↔uv integration now; prove it
   with real DeepSeek runs + the `tc.snapshot` hook. (No trickle-server harness
   up front — owner's call.)
4. **~~One shared frame driver.~~ SUPERSEDED — one event loop.** The frame-driver
   idea (`sched.frame{budget_ms}`: a `uv_run` *bounded* to a paint budget, called
   once per painted frame) was wrong twice over: it *polls* the loop at the paint
   rate, so a stream is throttled to ~1 resume per frame instead of full socket
   speed; and it makes the UI own the block, which is why input fought the stream
   on real terminals. The correct model is the plain event loop everyone else
   runs (Node's raw stdin is a libuv handle, never polled): **everything is a
   handle on one loop, the scheduler sleeps in a single unbounded `uv.run("once")`
   and wakes when any handle fires.** The scheduler resumes **first**, then sleeps
   only when nothing is runnable (draining a just-completed request before the
   sleep is what stops us waiting forever on a socket that already closed). No
   `sched.frame`; no fixed quantum.
5. **One transport.** Retire `stream_once` and the `opts.async` branch; every turn
   is an actor on the loop. One-shot/`--headless` is that same actor run to
   completion (`sched.run`, which sleeps in the same unbounded `uv.run`).
6. **stdin on the loop — load-bearing, not polish.** termctl puts stdin on the uv
   loop (`tc.attach()` → `uv_poll` on fd 0); a keypress is a callback that wakes
   the one `uv.run`. This is what *lets* the cTUI sleep in a single unbounded
   `uv.run` and still get keys instantly — without it we were forced back into
   polling. `tc.poll` in attached mode stops owning the fd; it only parses what
   the callback buffered. A repeating heartbeat `uv_timer` wakes the loop ~4×/s so
   the agent clock ticks even when a slow child sends no traffic.
7. **Blocking IO → the uv threadpool.** A slow synchronous op (a big file read)
   must not block the loop. Move blocking file IO (`util.read_file`, today
   `io.open`) onto libuv's async `fs`/threadpool (`uv.fs_*`, `uv.queue_work`);
   the actor yields and resumes on completion. `proc.run` already yields;
   HTTP is now async — so no common tool blocks the loop.

## The invariant that makes it "never block input"

**Everything waits in one place: a single unbounded `uv.run("once")` with stdin,
http sockets, subprocesses and a heartbeat timer all handles on that loop.** A
keypress, a streamed token, or the clock tick each wake it immediately; nothing
polls, and the process is genuinely asleep in between. Every "freeze" we chased
was a violation of *having one loop*: HTTP off the loop (the original two-reactor
freeze), or the loop driven by a bounded paint quantum (the throughput throttle).

## What stays / goes / is new

- **Stays:** the scheduler, coroutine actors, the `io/proc/recv` yields, the async
  transport's *shape*, `step(block)`. The studio's per-frame model — we generalise
  what already works there.
- **Goes:** `g_multi` global + `curl_multi_wait` (a second reactor); `http.pump`
  as the scheduler's wait (running the loop pumps curl now); `stream_once` +
  the `opts.async` branch; the cTUI's `sched.frame` bounded-poll hand-crank.
- **New:** per-loop `CURLM` on uv; the scheduler's resume-first + unbounded
  `uv.run("once")` drive (`resume_ready`/`classify`); stdin on the loop
  (`tc.attach` → `uv_poll` on fd 0) with a heartbeat `uv_timer`; async file IO via
  the threadpool (still to do).

## Sequence (each step ships and is checkable)

1. ✅ **curl_multi ↔ libuv, per-loop** (`src/lhttp.c`): `CURLMOPT_SOCKETFUNCTION` →
   `uv_poll` per curl fd; `CURLMOPT_TIMERFUNCTION` → one `uv_timer`; events →
   `curl_multi_socket_action`; completions as today. `http.pump` is now a thin
   bounded `uv.run` over the unified loop. *(commit a1ba9e4)*
2. ✅ **Scheduler drives the loop, not a pump.** `M.step`/`M.run` resume-first,
   then sleep in a single **unbounded** `uv.run("once")` when nothing is runnable
   (`resume_ready`/`classify` are the primitives). curl-on-uv means running the
   loop *is* pumping http, so `http.pump` is gone from the scheduler entirely. A
   real swarm run proves full throughput: a 600-word child completes in ~14s via
   `sched.run`, vs the ~68s the old bounded-frame path took.
3. ✅ **cTUI is a plain event loop** (`lua/tui.lua`) — no `sched.frame`. Body:
   drain input (`tc.poll(0)`), `sched.resume_ready()`, paint if due, then sleep in
   `uv.run("once")`. The between-turns prompt is the same loop with no actors.
   Verified live: same 600-word task completes in ~16.6s (parity with the one-shot),
   the agent clock ticks during a turn, and a mid-stream Ctrl-C interrupts in ~0.15s.
   *(`sched.frame` deleted; `dash.lua` and the SDL studio still to convert.)*
4. ✅ **stdin on uv** — termctl `tc.attach()` puts fd 0 on the loop as a `uv_poll`;
   `tc.poll` in attached mode only parses buffered bytes. This is what makes step 3's
   single `uv.run` sleep correct: a keypress wakes it instantly. A heartbeat
   `uv_timer` keeps the clock ticking. (`termctl.c`/`termctl.h`/`ltermctl.c`;
   `termctl_smoke` now links `uv_a`.)
5. ✅ **Retired `stream_once`** — one transport. `api.lua` calls `stream_async`
   unconditionally; the blocking `http.request` path and the `opts.async` branch
   are gone, and the now-meaningless `async` flag is stripped from `agent_opts`
   and its callers. Every turn — REPL, one-shot, headless, cTUI, swarm — is a
   scheduler coroutine on the unified loop. The offline turn-loop tests
   (`integration`, `events`) now stub `http.begin` and drive turns under the
   scheduler, matching production. (`http.request` C binding kept but unused.)
6. **Blocking file IO → threadpool** (`util.read_file` → async `uv.fs`).
