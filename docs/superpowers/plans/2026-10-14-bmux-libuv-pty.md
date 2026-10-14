# Native libuv terminal transport implementation plan

> Execute the approved BMUX-21 roadmap incrementally using the executing-plans workflow.

**Goal:** Run shells through libuv readiness and SIGCHLD, parsing output in C,
then remove Studio's Lua byte parser and frame-time PTY reads/reaping.

**Architecture:** `src/bpty.c/.h` own a Unix PTY, bounded input queue,
libuv handles and child lifecycle. They borrow a `bterm` while attached.
`src/bptyinal.c` exposes process-backed terminals with the existing grid,
damage, input encoders and event APIs. Studio owns presentation over SDL3.

**Tech stack:** C11+, Lua, existing libuv and SDL3. No new Python tooling.
Windows ConPTY is the separate BMUX-22 backend. Useful Venus data structures
remain available; this transport needs a byte queue rather than a hash table.

## Task 1: Native Unix transport

- [x] Add `src/bpty.c/.h`: controlling terminal via forkpty, precomputed exec
  path/environment, child exec-error pipe, nonblocking/CLOEXEC master.
- [x] Watch master readiness through `uv_poll`; feed directly to `bterm` in
  bounded read batches. Watch writability only while a bounded queue is pending.
- [x] Reap only the owned PID through `uv_signal(SIGCHLD)`, with one startup
  check to cover very early exits. Preserve coexistence with uv_spawn.
- [x] Separate child exit from output EOF; drain final output after reaping.
- [x] Deferred close detaches the core immediately, stops polling before
  closing the fd, sends HUP, and escalates a still-owned child after a deadline.
- [x] Expose PTY resize and explicit foreground-process-group queries.
- [x] Add native tests for real controlling tty, input backpressure, final
  output, concurrent uv_spawn, early exit, invalid executable/cwd, FD cleanup,
  resize and close/GC lifetime. Check sanitizer and loop/child cleanup.

## Task 2: Process-backed Lua terminal

- [x] Add `terminal.open(opts)` and process write/status/group APIs to the
  existing terminal userdata. Replies go directly back to the PTY in C.
- [x] Preserve parser-only `terminal.new` behavior and CLI/Studio parity.
- [x] Validate argv, dimensions and NULs before spawning; create GC ownership
  before native resources. Closing a userdata must make late callbacks safe.
- [x] Test with real PTYs driven exclusively by uv.run, without Lua byte feed.

## Task 3: Studio data-path replacement

- [ ] Replace `pty.open/read/alive` and the Lua VT parser in terminalview.lua.
  Keep native grid ownership; fetch damaged/visible rows for presentation.
- [ ] Pump the shared uv loop once centrally, preserving SDL input handling.
  Integrate idle wakeups; no per-pane read or waitpid calls from frame updates.
- [ ] Route input to existing native encoders (BMUX-18), preserving pane
  shortcuts, composition and negotiated paste/focus/mouse behavior.
- [ ] Remove the superseded Studio PTY implementation after all consumers move.

## Task 4: Verification and acceptance

- [ ] Exercise actual shells and TUIs in Studio; test parser removal, replies,
  damage, resize, process exit and close. Check input/IME routing separately.
- [ ] Run appropriate full regressions and native sanitizer gates. Record
  evidence on BMUX-21 criterion 1447; close only after the Studio data path
  satisfies it. Application throughput/idle budgets remain required roadmap
  gates and must be measured independently.

## Sources and constraints

The existing approved roadmap specifies uv_poll/SIGCHLD and C terminal feed.
[libuv poll documentation](https://docs.libuv.org/en/v1.x/poll.html) requires
handling EAGAIN and stopping a poll handle before closing its fd.
[libuv signal documentation](https://docs.libuv.org/en/v1.x/signal.html)
defines per-loop Unix signal handles. The vendored
`src/vendor/libuv/src/unix/process.c::uv__wait_children` waits only for registered
process PIDs; this transport must likewise never use waitpid(-1).

## Transport checkpoint

Tasks 1–2 are implemented, including application teardown in CLI/Studio/workers
before luv's loop finalizer. The new module uses `bpty` names because the
tracker's proposed `src/lterm.c` already implements CLI completion; that file
is preserved. `bterm_resize_guarded` prepares both screens and checks the host
before allocation-free commit. Rejected host resize preserves deep screen
state. Queue growth OOM accepts no bytes; input tests check 2 MiB of binary data.

Event retrieval copies/rebases payloads into rooted userdata before allocating
Lua tables. Lua 5.5's explicit GC parameters make a close-finalizer run during
event retrieval; safe snapshots or a closed-terminal error are required.
Retained process objects survive native loop destruction until release.

All normal CLI/Studio builds and C11 warnings-as-errors pass. The full normal
suite passed 136/136 (147.79s); an earlier 133/134 run hit mining_jobs at
101.017ms versus its unchanged 100ms bound and its isolated rerun passed.
The eight focused sanitizer tests passed (22.54s), with no diagnostics.
Final review then cleared retired handle flags and reset child signals before
closing inherited descriptors; focused normal/sanitizer gates were rerun on
that final code, including release after freeing the native loop: nine normal
tests pass (11.01s) and eight ASan/UBSan tests pass (20.60s), without diagnostics.
The final normal group includes Studio's dummy-video binding test; this
sanitizer build has no Studio target, so sanitizer evidence covers CLI/native
and worker paths.

Execution evidence is macOS arm64. The Windows stub returns ENOSYS until
BMUX-22; Linux/BSD execution is not established by these runs. Studio's dummy
video test proves the shared binding, not the terminal pane or renderer.
BMUX-21 remains in progress; Task 3 is the next required integration. No
application performance claim is made by this checkpoint.
