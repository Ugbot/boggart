# Server-owned Bmux terminals

`boggart serve` now owns native PTY/grid objects independently of HTTP clients.
Closing a client connection leaves its terminals running. A later client uses
the same opaque terminal ID and runtime generation to read or control the same
process. This is BMUX-30's server foundation; Studio's existing Bmux panes still
own their local terminals. Thin Studio/cTUI attachment, live replay and layout
recovery remain BMUX-32/34/35 and BMUX-31/33.

Start a dedicated host on an owned private directory's Unix socket:

```sh
bmux_directory=$(mktemp -d /tmp/boggart-host-XXXXXX)
boggart serve --socket "$bmux_directory/control.sock"
```

From another terminal, create a shell with a literal executable/argument vector:

```sh
curl --unix-socket /path/to/private/control.sock \
  -H 'Content-Type: application/json' \
  --data '{"cmd":"/bin/sh","args":[],"cols":80,"rows":24,"history":2000}' \
  http://localhost/terminals
```

Use the returned `id` in subsequent routes. Private UDS peer/ownership checks
and the existing control capability policy apply. TCP listeners retain their
existing bearer-token rules; terminal routes do not bypass them.

| Method | Route | Input / result |
| --- | --- | --- |
| POST | `/terminals` | `{cmd?, args?, cwd?, env?, cols?, rows?, history?}` → 201 lifecycle record |
| GET | `/terminals?offset=0&limit=64` | Metadata page, total and next offset |
| GET | `/terminals/:id` | Native process outcome, geometry and lifecycle |
| GET | `/terminals/:id/screen?first=1&count=24` | Non-destructive visible cell rows, cursor/modes and process status |
| POST | `/terminals/:id/input` | `{generation, text}` → accepted byte count |
| POST | `/terminals/:id/resize` | `{generation, cols, rows}` → current metadata |
| POST | `/terminals/:id/close` | `{generation}` → closed lifecycle record |

An omitted command uses the server's shell; cwd defaults to its working
directory. `args` and `env` are dense literal arrays. Environment overrides use
`KEY=value`, with the existing native TERM/private-channel rules. Neither argv
nor environment values are enumerated in lifecycle metadata. Commands may of
course print their own environment to the terminal grid. JSON input must be an
object and unknown option/mutation fields are rejected.

IDs include a random per-server prefix and monotonically increasing serial;
they are never reused within that host. This version creates generation 1 and
does not restart records in place. Input, resize and close require that exact
generation. After a client first attaches, input and resize also require its
explicit controller lease; see [attachment cursors and ownership](bmux-terminal-attachments.md).
A PID is metadata, not authority. Creation may return a record with
`state=failed` when the executable/cwd cannot be started; inspect its error.
Native exit status/signals and output EOF determine completion. Exited grids
remain readable/resizable until closed or evicted. Close is idempotent and
reports `stopped` if native completion was not already known; it requests native
teardown without inventing a successful exit or signal outcome.

## Bounds and ownership

The registry defaults to 256 retained records and 32Mi reserved logical cells,
accounting for `cols * (rows + history)` per open grid. These are admission
budgets, not measured RSS limits. Only completed/closed history can be evicted;
live terminals are never replaced to admit another request. Failed capacity
requests do not kill live processes. Trusted embedding callers may configure
`control.start{terminal_limits={max_records=..., max_cells=...}}`.

Dimensions are 1..4096; history is 0..100000 rows. Argument vectors are bounded
to 128 entries/64KiB; environment overrides to 64 entries/64KiB. Input is at most
64KiB per request and retains the native bounded queue/backpressure behavior.
Listing returns at most 64 records. Screen reads return at most 64 visible rows
and 32768 cells; choose a smaller count for wide grids. Screen reads do not
acknowledge damage, consume terminal events or affect another reader. They are
an observation endpoint, not the ordered snapshot/replay protocol in BMUX-32.

Native C continues to own PTY I/O, parsing, replies, process status, deferred
close and reaping on the existing libuv loop. Lua holds the registry and route
policy. No per-terminal polling timer or worker thread was introduced, so
cross-thread bus delivery is not involved. `control.stop()` closes all retained
native terminals. Unix serve now catches SIGINT/SIGTERM and runs shutdown when
the daemon actor reaches its next job boundary; an in-flight model job is not
forcibly aborted by this change. Native teardown escalates owned children that
ignore HUP. SIGKILL, server crashes and machine restart do not preserve these
PTYs; durable restore is separate from live client disconnect survival.

Server-side Fleet/provider-hook attachment, native terminal CLI verbs, the product
attach client and automatic Studio reconnect are still open
roadmap work. The existing Studio manual registrar remains separate. Windows
ConPTY remains BMUX-22.

See [the persistent-host design](tmux.md),
[native control/authentication](control-surfaces.md), and
[verification evidence](benchmarks/2026-10-15-server-terminals-verification.md).
