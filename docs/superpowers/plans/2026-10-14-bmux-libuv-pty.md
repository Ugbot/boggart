# Native libuv terminal transport implementation plan

> Execute the approved BMUX-21 roadmap incrementally using the executing-plans workflow.

**Goal:** Run shells through libuv readiness and SIGCHLD, parsing output in C,
then remove Studio's Lua byte parser and frame-time PTY reads/reaping.

**Architecture:** `src/bpty.c/.h` own a Unix PTY, bounded input queue,
libuv handles and child lifecycle. They borrow a `bterm` while attached.
`src/lterminal.c` exposes process-backed terminals with the existing grid,
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

- [x] Replace `pty.open/read/alive` and the Lua VT parser in terminalview.lua.
  Keep native grid ownership; fetch damaged/visible rows for presentation.
- [x] Pump the shared uv loop once centrally, preserving SDL input handling.
  Integrate idle wakeups; no per-pane read or waitpid calls from frame updates.
- [x] Route input to existing native encoders (BMUX-18), preserving pane
  shortcuts, composition and negotiated paste/focus/mouse behavior.
- [x] Remove the superseded Studio PTY implementation after all consumers move.

## Task 4: Verification and acceptance

- [x] Exercise actual shells and TUIs in Studio; test parser removal, replies,
  damage, resize, process exit and close. Check input/IME routing separately.
- [x] Run appropriate full regressions and native sanitizer gates. Record
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

## Studio integration design

Use one SDL thread per app to wait on libuv's backend descriptor and a control
pipe. The thread only waits and pushes a coalesced SDL user event; the main
thread runs `uv_run(NOWAIT)`, including all C feed and Lua callbacks. Rearming
after dispatch publishes the backend timeout and interrupts a stale wait.
Quiet loops block; callbacks never move to the waiter thread. Stop/join the
waiter before retiring the loop. Backend-descriptor embedding is supported by
[libuv](https://docs.libuv.org/en/v1.x/loop.html#c.uv_backend_fd); SDL documents
[thread-safe event posting](https://wiki.libsdl.org/SDL3/SDL_PushEvent).
Windows lacks this backend descriptor and requires a bounded central wait
fallback until its platform integration is exercised with BMUX-22.

Replace TerminalView's grid/parser with `terminal.open`: use cached revision
for idle checks, native geometry/cursor and damaged visible rows, and request
scrollback rows only when visible. Preserve the last grid after exit/EOF.
Drawing remains SDL-backed; fixed cell positions handle wide heads/tails and
full cluster strings. Native batched rendering and shaping remain Phase 2.

Forward SDL key metadata without breaking existing editor key names. Native
encoders own key/paste/focus/mouse bytes. Text input remains the composition
source; defer printable key events until associated text arrives, flush keys
without text at the end of the SDL batch, and suppress only text consumed by
actual application shortcuts. Reserved pane chords remain application-owned.
Test actual SDL event dispatch, negotiated encoders and IME deduplication.

Freeze the current Lua parser as an identified benchmark reference before
removing it from production. Update termbench to identify the reference as
historical; do not relabel past measurements as current Studio behavior.

## Studio integration checkpoint

The native data path and host input routing are connected. The old PTY module,
byte parser, KEY_SEQ and manual Ctrl-letter encoding are removed from Studio.
The historical parser is frozen and hash-guarded in the termbench reference.
Idle panes use an allocation-free cached revision check; visible row snapshots
and native damage feed presentation. One SDL waiter posts coalesced work to
main-thread uv dispatch, including while the app waits for input.

Normal quit now returns to C teardown so the waiter is joined before loops and
children are retired. The status flag uses a raw global lookup, avoiding strict
Lua's missing-global trap. Embedded virtual-directory enumeration restores
plugin/shortcut discovery in the single-file binary, verified by the sanitizer
build which loads @assets instead of the working-copy Lua tree.

The final normal suite passes 141/141 (142.36s). Eleven focused ASan/UBSan tests
pass (22.00s), including actual Studio, native wait/PTY, worker, terminal/input,
extended resize and normal shutdown paths. Vim also passes under ASan/UBSan.
No sanitizer diagnostics. C11 warnings-as-errors and both product builds pass.
The earlier normal full run passed 141/141 (144.00s); a pre-fix sanitizer run
exposed missing embedded plugin discovery rather than a memory diagnostic.

Real macOS SDL-window runs verify input/IME, pane shortcuts, shell final output
and Vim insert/escape/enter/alternate-screen/save/exit. Dummy-video registered
tests guard the same paths. Screenshots and scope are linked by
[native-pane evidence](../../benchmarks/2026-10-14-native-pane.md).
No throughput, RSS, 100-pane idle CPU or key-to-pixel claim. Windows ConPTY and
its central-wait integration, other platform runs, renderer/shaping, selection,
search and broader application conformance remain required roadmap work.
