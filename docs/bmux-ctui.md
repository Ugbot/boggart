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
| `f` | Open server Fleet |
| `a` | Launch a server agent |
| `e` | Sessions: status, checkpoint files, saved-session inspection |
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

**Ctrl-B e** opens the [session controls](bmux-session-transfer.md). Export to a
new private file, import a regular checkpoint file as a new inactive saved
session, inspect a saved name or refresh persistence/recovery status. Use e/i/c/r
or Up/Down and Enter; Escape cancels a field, then closes the modal. Closing
the dialog or client leaves server processes running. Imported output remains
inactive when its named session is started explicitly and joined again.

## Agents and Fleet

**Ctrl-B a** opens the server agent launcher: Boggart TUI, resume a Boggart
session, Codex, Claude Code or a custom executable with quoted literal arguments.
Profiles run in the server's working directory. An empty host gets its first
workspace automatically. **Ctrl-B f** opens Fleet, showing the server's common
roster across providers, including workers and foreign processes.

Use Up/Down or j/k to select a row. Pointer clicks select rows and activate the
displayed actions; the wheel changes selection. Available actions follow the
provider's published capabilities:

| Fleet key | Action |
| --- | --- |
| Enter | Focus the agent's existing pane, or reopen its terminal reference |
| `p` | Compose a structured prompt |
| `i` | Interrupt the current turn |
| `a` / `r` | Approve / reject the exact observed request |
| `x`, then `y` | Stop the process or cancel the selected worker |
| `n` | Open the server launcher |
| `R` | Refresh/reconnect Fleet observation |
| `u` | Explicitly retry the exact pending agent command |
| Escape / `q` | Close Fleet |

Worker Focus reveals its owning TUI. Ordinary foreign executables expose process
observations and Stop; Bmux does not infer prompt/approval semantics from text.
An agent layout reference attaches to its published native terminal, initially
read-only. Focus does not create another execution owner.

The prompt editor uses the shared grapheme composer: arrows/backspace/delete
operate on complete emoji/combining sequences. Enter sends, Ctrl-J inserts a
newline, and Escape cancels. Drafts are bounded to 16,384 bytes. Local completion
is disabled for these server-directed fields. The editor captures the observed
runtime, conversation and input revision; stale or conflicting input cannot
overwrite a human draft. Modal keys, mouse and paste are consumed before PTY
input. On narrow displays, rows/actions clip or wrap while keyboard actions
remain available.

Known refusals retain the editor text. An ambiguous acknowledgement blocks
another agent mutation. Escape closes the editor; **u** in Fleet or the launcher
explicitly retries the original bytes. Refresh and reconnect never replay it.
If launch succeeds but layout placement fails, use Fleet Focus to find the
retained runtime. **Ctrl-B u** outside Fleet still retries terminal input/control.

Closing the tab reference or detaching leaves server agents alive. Hidden views
release their readers and input leases; reopening starts read-only on the same
process/session. Studio and terminal Bmux can observe and control the same agent
through this shared server. See [Studio agents](bmux-studio-agents.md) and
[verification](benchmarks/2026-10-16-ctui-fleet-verification.md).

## Ownership and limits

The C termctl canvas owns raw terminal mode, input decoding, cluster storage and
cell diffs. `bmux.canvas` uses the shared structural tree and validated snapshot
projection. `bmux.tui` routes commands and bounded pending input. The shared
`terminal.remote` module owns attachment leases, queueing, native semantic input
and exact uncertainty retry; Studio supplies its image adapter to that module.
`bmux.tuifleet` supplies modal Fleet presentation through `bmux.fleetclient` and
mounts remote records in the common registry through `bmux.fleetsource`.
`bmux.agentviews` shares existing-runtime pane lookup with Studio. Fleet painting
skips the obscured terminal frame and preserves the grapheme under the caret.

Observation is stream driven; there is no idle screen/layout polling timer.
SIGWINCH wakes libuv, and incomplete Escape input has a one-shot 30 ms ambiguity
timeout. Input waits for outstanding layout commands, then resolves against the
confirmed tree. Conflict/disconnection clears queued input rather than replaying
it against a changed layout.

At most 32 visible active terminal views attach per client. Hidden views detach;
visiting them again creates a fresh reader without restarting the process.
Each reader retains up to 256 history rows subject to the existing host budget.
If a history request exceeds that budget, the pane retries read-only attachment
once with zero history. The screen must still fit the host's frame limit. This
observation fallback never replays a terminal input or agent command.
Clusters retain the native 65-scalar limit and authoritative cell width; terminal
font and width-policy support still determines how an external terminal paints
those bytes. RGB colors map to termctl's portable 256-color palette. SDL shaping
and color glyph rendering remain Studio features.

Agent references without a published terminal show an unavailable notice.
[Server restart restore](bmux-journal.md) now reconstructs saved sessions with
fresh native owners. Sessions supplies file import/export, inspection and
[explicit archive recovery](bmux-recovery.md) through **Ctrl-B e v**. Richer
foreign-provider adapters remain follow-ups. Studio local agents retain their owners.
