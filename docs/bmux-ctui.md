# Bmux in a terminal

Start a Boggart server on a private Unix socket, then attach from a terminal:

```sh
boggart serve --socket /absolute/private-directory/control.sock
boggart bmux --socket /absolute/private-directory/control.sock
```

The directory and socket must be owned by you with no group/other permissions.
Use `--token` when the server requires one. Studio's **Join layout** can use the
same socket: both clients observe and edit the same workspace/surface/pane tree.
The older `boggart --tui` remains the agent conversation front end.

Press **Ctrl-B**, release it, then a command:

| Key | Action |
| --- | --- |
| `t` | New server terminal; initializes an empty host |
| `%` / `"` | Split with a new terminal right / down |
| `n` / `p` | Next / previous pane |
| `h j k l` | Directional focus |
| `[` / `]` | Previous / next tab |
| `z` / `=` | Toggle zoom / balance splits |
| `x` | Close the tab reference; keep its server process |
| `w` / `s` | Next workspace / surface |
| `W` / `S` | Create workspace / surface |
| `c` | Request input control |
| `!` | Explicitly take control from another client |
| `v` | Release control and reattach read-only |
| `r` | Refresh or reconnect observations |
| `u` | Retry the exact uncertain terminal command |
| `?` | Help; Escape closes help |
| `q` | Detach; server terminals keep running |
| Ctrl-B | Send a literal Ctrl-B to the controlled application |

PageUp/PageDown browse the attached history tail locally. Mouse clicks focus
panes. Wheel events reach a controlled application with mouse reporting enabled,
otherwise they scroll local history. The active controller resizes the PTY to
its pane; observers clip without changing server geometry. Narrow windows show
the focused pane and retain the canonical split tree for navigation and later
expansion.

## Ownership and limits

The C termctl canvas owns raw terminal mode, input decoding, cluster storage and
cell diffs. `bmux.canvas` uses the shared structural tree and validated snapshot
projection. `bmux.tui` routes commands and bounded pending input. The shared
`terminal.remote` module owns attachment leases, queueing, native semantic input
and exact uncertainty retry; Studio supplies its image adapter to that module.

Observation is stream driven; there is no idle screen/layout polling timer.
SIGWINCH wakes libuv, and incomplete Escape input has a one-shot 30 ms ambiguity
timeout. Input waits for outstanding layout commands, then resolves against the
confirmed tree. Conflict/disconnection clears queued input rather than replaying
it against a changed layout.

At most 32 visible active terminal views attach per client. Hidden views detach;
visiting them again creates a fresh reader without restarting the process.
Each reader retains up to 256 history rows subject to the existing host budget.
Clusters retain the native 65-scalar limit and authoritative cell width; terminal
font and width-policy support still determines how an external terminal paints
those bytes. RGB colors map to termctl's portable 256-color palette. SDL shaping
and color glyph rendering remain Studio features.

Agent references currently show an adapter-unavailable notice in the joined
hierarchy. Remote agent conversation/execution adapters and durable server
restart restore remain follow-up work. Existing Studio local agent launching
and common Fleet registration retain their execution owners.
