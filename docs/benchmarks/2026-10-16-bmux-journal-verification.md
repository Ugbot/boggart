# SQLite runtime journal verification

BMUX-96, macOS arm64, 2026-10-16. Normal and ASan/UBSan CLI/Studio builds passed.
The broad regression preceded the final shutdown admission and physical-history
scan guards; the final focused gates include both changes. No product-code
changes followed those gates. `git diff --check` passed.

| Gate | Result | Local evidence |
| --- | --- | --- |
| Broad normal terminal/control/Fleet/Studio/store tests | 80/80, 66.09 s | `build/bmux-journal-verified.log` |
| Broad ASan/UBSan same suites | 80/80, 96.37 s | `build-asan/bmux-journal-verified.log` |
| Final normal shutdown/bounds/restart/client gates | 9/9, 10.29 s | `build/bmux-journal-final-bounded-verified.log` |
| Final ASan/UBSan same gates | 9/9, 14.42 s | `build-asan/bmux-journal-final-bounded-verified.log` |
| Actual SDL Studio/native-terminal shared-agent workflow | Passed | `build/bmux-journal-real-sdl.log` |

`tests/bmux_session_restart.lua` runs actual native daemons, PTYs, SQLite state,
control clients and a real idle Boggart TUI. It verifies clean quit/relaunch and
SIGKILL recovery: workspace/surface/split/zoom/tab aliases, cwd after OSC and
stock-shell `cd`, Unicode output history, saved Boggart session ID with a new PID,
fresh host identity, old-host command rejection and one owner per resource.
A foreign executable appends to a marker file on its authorized first launch;
the file stays unchanged across both restarts. That process returns only as an
inactive preview. A second actual daemon on another socket cannot claim the
same saved session or start its resources. Default socket-derived naming and
the explicit CLI option are exercised.

`tests/bmux_journal.lua` verifies coalesced/unchanged saves, same-PID owner
conflict, checkpoint/owner replacement, corrupt data preservation, inactive
preview attachment with denied input/control, missing directories/executables,
hard restore budget rollback and observable storage failures. A real HTTP
mutation injected after the final checkpoint reproduced a lost shutdown edit
before the admission guard (`build/bmux-journal-shutdown-before.log`); it now
receives 503 before the server releases its owners.

`tests/bmux_journal_native.lua` uses two SQLite connections to verify native
compare/set, stale compare/delete, empty and embedded-NUL values. Native history
extraction preserves complete emoji/combining clusters, hides concealed cells,
does not consume row generations, obeys line/byte limits and GC boundaries, and
does not scan beyond the latest 256 physical rows through arbitrarily blank
history.

`tests/control_unix.lua` retains ownership/auth/Origin/body-limit/GC/shutdown
coverage and adds actual killed-listener recovery. Native kernel-held lock files
serialize the bind/recovery interval; owned stale sockets can be reclaimed,
while live sockets, replacement files, symlinks and unrelated lock-path contents
remain intact. The actual daemon crash test first reproduced the stale-path
failure in `build/bmux-session-restart-second.log`.

Broad gates:

```sh
ctest --test-dir build --output-on-failure -R '^(bmux_.*|studio_.*|terminal.*|control.*|serve_streams|agent_channel_watch|fleet|agentbridge|agentcontrol|fleetworkers|manualfleet|store_save|json_c)$'
ctest --test-dir build-asan --output-on-failure -R '^(bmux_.*|studio_.*|terminal.*|control.*|serve_streams|agent_channel_watch|fleet|agentbridge|agentcontrol|fleetworkers|manualfleet|store_save|json_c)$'
```

Final gates select bmux_journal_native, bmux_journal, bmux_session_restart,
control_unix, control, serve_streams, terminal_observers, studio_server_agents and
studio_bmux_layout in both builds.

Linux cwd lookup is implemented with `/proc`, but this run verifies macOS's
system libproc backend. Windows ConPTY remains separate work. This increment
does not implement client import/export or explicit corrupt-session recovery;
those remain BMUX-97 and keep the BMUX-33 story open. No performance-superiority
claim over cmux is made from these correctness gates.
