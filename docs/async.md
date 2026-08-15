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
4. **One shared frame driver.** `sched.frame{ budget_ms, paint }`: step the swarm
   non-blocking, run the unified loop **bounded** to the budget (waking on any
   IO), then paint. cTUI passes ~16ms (it owns the clock); studio passes 0 (SDL
   vsync is its clock); a CLI one-shot passes "block-until-done", no paint. This
   deletes the studio's ad-hoc `step(false)` and the cTUI's hand-crank.
5. **One transport.** Retire `stream_once` and the `opts.async` branch; every turn
   is an actor on the loop. One-shot/`--headless` is that same actor run to
   completion with a blocking budget.
6. **stdin on the loop.** Re-plumb termctl input onto a `uv_tty`, so a keypress
   *wakes* the bounded wait (~0ms input latency). Belt-and-suspenders on top of
   the bounded-loop guarantee.
7. **Blocking IO → the uv threadpool.** A slow synchronous op (a big file read)
   must not block the loop. Move blocking file IO (`util.read_file`, today
   `io.open`) onto libuv's async `fs`/threadpool (`uv.fs_*`, `uv.queue_work`);
   the actor yields and resumes on completion. `proc.run` already yields;
   HTTP is now async — so no common tool blocks the loop.

## The invariant that makes it "never block input"

The frame driver's wait is **always bounded** — `uv.run` with a frame-deadline
timer, **never** `uv.run("once")` unbounded. Input is therefore serviced every
frame (≤16ms), and with stdin on the loop, instantly. Every "freeze" we chased
was a violation of this one rule (`sched.run` → blocking `step(true)` →
`uv.run("once")`).

## What stays / goes / is new

- **Stays:** the scheduler, coroutine actors, the `io/proc/recv` yields, the async
  transport's *shape*, `step(block)`. The studio's per-frame model — we generalise
  what already works there.
- **Goes:** `g_multi` global + `curl_multi_wait` (a second reactor); `http.pump`
  (becomes a thin `uv.run` shim in transition, then removed); `stream_once` +
  the `opts.async` branch; the studio's and cTUI's hand-cranked pumps.
- **New:** per-loop `CURLM` on uv; `sched.frame{budget_ms, paint}`; `uv_tty`
  input in termctl; async file IO via the threadpool.

## Sequence (each step ships and is checkable)

1. **curl_multi ↔ libuv, per-loop** (`src/lhttp.c`): `CURLMOPT_SOCKETFUNCTION` →
   `uv_poll` per curl fd; `CURLMOPT_TIMERFUNCTION` → one `uv_timer`; events →
   `curl_multi_socket_action`; completions as today. Keep `http.pump` as a thin
   `uv.run` shim so nothing else changes yet.
2. **`sched.frame{budget_ms, paint}`** + scheduler `"io"`-wait via the unified
   loop; delete `curl_multi_wait`.
3. **cTUI + studio adopt `sched.frame`**; delete both hand-cranks (incl. the
   interim `tui.lua` poll loop).
4. **stdin on uv** (termctl input → `uv_tty`); the frame wakes on a keypress.
5. **Retire `stream_once`**; one-shot/headless drive the async actor to completion.
6. **Blocking file IO → threadpool** (`util.read_file` → async `uv.fs`).

## Interim (staged, uncommitted)

`tui.lua`'s turn loop is already changed from blocking `sched.run` to a bounded
poll loop — the stopgap that removes the unbounded freeze. It is exactly what
step 3 deletes. Either commit it so the cTUI is usable during the refactor, or
discard it and let step 3 land the real thing.
