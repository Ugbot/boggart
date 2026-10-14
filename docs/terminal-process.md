# Process-backed native terminals

`require('terminal').open(opts)` starts a Unix process with a controlling PTY
and feeds its output directly into the C terminal core on the shared libuv loop.
It returns the same terminal userdata as `terminal.new`, with row/snapshot,
damage, event and negotiated input-encoder methods. Lua does not read or parse
process output. `terminal.new` remains useful for parser-only terminals.

```lua
local terminal = require 'terminal'
local uv = require 'uv'
local t <close> = assert(terminal.open {
  cmd = '/bin/sh', args = {'-c', 'printf hello'},
  cols = 80, rows = 24, history = 2000,
})
uv.run()
local process = t:process_state()
assert(process.exited and process.eof and process.exit_status == 0)
print(t:row(1).cells[1].text)
```

Options are `cmd` (default `$SHELL`, then `/bin/sh`), `args` (argv tail, at most
1,024 strings), `cwd`, `cols`, `rows` and `history`. Dimensions/history use the
same bounds as `terminal.new`. Strings cannot contain NUL. Validation errors
raise; native spawn failures return `nil, error`. The child inherits the host
environment with `TERM=xterm-256color` and `COLORTERM=truecolor`. Command paths
and environment are prepared before fork; child setup avoids heap allocation.
Inherited host descriptors enumerated before fork are closed in the child.

Additional methods:

- `t:write(bytes)` accepts the whole string into a queue or returns `nil, error`
  without accepting bytes. Writable readiness drains it. The pending queue is
  bounded to 32 MiB; later I/O failures appear in process state.
- `t:process_state()` returns cached PID, exit/EOF status, exit code/signal,
  error code/message, revision, bytes read, read-callback count and queued bytes.
  Reading this state performs no PTY read or waitpid. Parser-only terminals
  return `nil`.
- `t:foreground_group()` explicitly queries the foreground process group;
  this is a process-group ID, not a distinct foreground process PID.
- `t:resize(cols, rows)` prepares both grids, applies kernel PTY geometry, then
  commits without allocation. Preparation/kernel failures preserve the grids.
  After EOF it resizes the frozen parsed grid without touching the closed PTY.
- `t:close()` immediately detaches the parser, stops polling and closes the
  master. HUP requests child shutdown; a 250 ms deadline kills a still-owned
  child. Native memory retires after child reaping and handle close callbacks.
  Explicit close and GC are safe; callers continue pumping uv for cleanup.

Application teardown in CLI, Studio and worker states closes and reaps any
remaining owned PTYs before luv's loop finalizer runs. A thread-local native
ownership list keeps worker loops separate. Parser-only terminals preserve
lazy loop creation. A new process cannot be opened after state teardown starts.

Automatic DA/DSR/OSC replies go directly back through the PTY queue in C.
`t:replies()` retains its explicit reply-queue behavior for parser-only objects.
Key, paste, mouse and focus encoders return bytes; the host sends those bytes
through `t:write`. Event retrieval roots an immutable payload image before
creating Lua tables, so finalizers may close/feed the terminal safely.

The transport lives in `src/bpty.c/.h`: the tracker initially proposed
`src/lterm.c`, but that file already implements CLI completion and stays intact.
`uv_poll` handles master readiness with a 256 KiB callback budget. A SIGCHLD
watcher waits only for its own child, alongside libuv's own process watchers.
Child exit and output EOF are separate: a fast exit cannot discard unread output.
One startup waitpid check covers a child that exits before open returns.

This API is compiled into CLI and Studio. Registered tests exercise actual
controlling terminals, automatic replies, queued input, coordinated resize,
immediate exits, final-output draining, native allocation/ioctl failures,
descriptor cleanup, uv_spawn coexistence, parser failure and deferred close/GC.
`terminal_process_studio` runs the same binding tests using SDL's dummy video
driver; it does not verify rendering or input delivery in a real window.

BMUX-21 remains in progress: Studio's terminal pane still uses its old PTY/Lua
parser until the next integration step replaces that data path and connects the
central event-loop wakeup. Windows currently returns `UV_ENOSYS`; ConPTY is
BMUX-22. No new application throughput, idle CPU, RSS or latency claim follows
from these transport tests.
