# Saved server sessions

Private-socket Bmux servers now save their layout and supported runtime recipes
in the existing SQLite store. Reuse the same `BOGGART_HOME` and socket path when
restarting, or choose a stable session name explicitly:

```sh
boggart serve --socket /absolute/private-directory/control.sock --bmux-session work
boggart bmux --socket /absolute/private-directory/control.sock
```

Without `--bmux-session`, a private-socket server uses its absolute socket path
as the name. TCP servers persist only with an explicit name. Embedded/test
`control.start` stays ephemeral unless given `session='name'`; `session=false`
also disables it. A name belongs to one live daemon at a time, even when two
daemons use different sockets in the same store.

## What returns after restart

The shared workspace/surface/split/tab hierarchy, custom titles, selected tabs,
focused panes and zoom are reconstructed under a fresh host identity. Alias
views of one terminal still share one owner. Runtime IDs/PIDs, attachments,
controller leases, pending input, approvals and command receipts are fresh.
Clients pinned to the old host must explicitly join the restarted server.

Default shells created without custom argv/environment reopen in their saved
cwd. Native cwd lookup follows stock shells on macOS/Linux, with local OSC 7
directory metadata and the launch directory as fallbacks. Relative launch cwds
are anchored before saving. Stored output is fed to the parser as plain history,
never typed into the shell.

Ordinary server Boggart TUI profiles reopen using the local CLI and saved numeric
session ID, in an idle conversation. They do not replay model/tool work.
Custom executables, explicit Boggart command/argv profiles, stopped processes,
and unavailable directories/sessions/executables return as inactive parser
previews. These can be viewed but cannot acquire an input lease. Existing agent
entries return to the common Fleet with their resume reference and supported
capabilities. The stored informational program string is never executed.

History is best effort: the newest 256 physical rows, up to 256 output lines and
64 KiB per terminal, with 2 MiB shared across the checkpoint and 4 MiB total JSON.
Trailing blank rows are skipped within that bounded scan. Whole graphemes are
retained, controls are scrubbed, concealed cells are blanked and styling is not
persisted. Hard owner/layout/store budgets are enforced. An unsuccessful restore
releases newly created owners and keeps the old checkpoint rather than publishing
a partial replacement layout.

## Saving and recovery

Native terminal/Fleet/layout changes mark a one-shot 250 ms checkpoint timer;
there is no idle persistence polling loop. Unchanged encoded data skips a write.
Shutdown first refuses new control requests, saves, then releases PTYs and the
owner claim. Crash recovery uses the last completed checkpoint.

The native listener holds an exclusive, private `socket.lock` file with a Boggart
format marker while binding/listening. After a crash, it can recover only its
owned private stale socket, after a failed connection and an inode recheck.
Live listeners, files, symlinks and replacement paths remain protected. Normal
shutdown removes only the socket/lock inodes it owns. SQLite additionally claims
each named session with a PID/random owner record and atomic compare/set, and
each checkpoint write compares the previous document. A live or reused PID is
conservatively treated as owned.

`GET /layout/session` uses capability `control:GET:/layout/session` and rejects
query parameters. It returns `host_id` and `persistent`, plus `name`, `restored`, `blocked`,
`dirty`, `writes` and an optional bounded `error` for persistent servers. It
exposes no ownership token or execution credential. Corrupt/changed checkpoints,
owner conflicts and storage failures remain intact and observable through this
status. The shared session client pins `host_id` before accepting the status.
Choosing another name does not erase the old session.

[Native transfer](bmux-session-transfer.md) (BMUX-98) creates new named saved
sessions with every imported recipe demoted to inactive state. It never
overwrites existing/corrupt bytes or live owners. Actual daemon startup/resave
coverage verifies that imported data cannot acquire execution authority.
BMUX-99 adds Studio/native session menus and file controls. BMUX-100 completes
[explicit recovery](bmux-recovery.md): preserve exact original bytes in private
synced files, then resume saving current state under exact owner/data/layout
guards. Existing PTYs retain their identities; inactive imports remain inactive.
Actual Studio/native recovery and restart checks complete BMUX-33/97.

Implementation: `bmux.journal` owns lifecycle/storage, `bmux.capture` builds the
[validated data](bmux-checkpoints.md), and `bmux.restore` allocates/remaps one
native owner per resource. `repo:kv_compare_set` / `bog.store.kv_compare_set`
provide atomic SQLite compare/set; nil means absent/conditional deletion. Optional
owner key/value arguments guard the same statement; journal writes and named
imports use them. Recovery metadata is read through the separate
`GET /layout/session/recovery/status` route, preserving the ordinary status shape.
`terminal:plain_tail(lines?, bytes?)` supplies immutable text without per-cell Lua
tables. `terminal:working_directory()` queries its owned live process, returning
nil when unavailable. macOS links the system `libproc`; Linux uses `/proc`.
See [verification](benchmarks/2026-10-16-bmux-journal-verification.md).
