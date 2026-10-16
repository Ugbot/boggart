# Session controls verification

BMUX-99, macOS arm64, 2026-10-16. Normal and ASan/UBSan CLI/Studio builds
passed. Broad gates preceded the final pending-dialog correction; focused gates
include that correction and the client-visible imported output checks. The last
test-only change adds actual native pointer activation. No product changes
followed the final gates. `git diff --check` passed.

| Gate | Result | Local evidence |
| --- | --- | --- |
| Broad native terminal/control/Fleet/Studio/store, normal | 84/84, 46.52 s | `build/bmux-session-controls-verified.log` |
| Same broad suites, ASan/UBSan | 84/84, 83.25 s | `build-asan/bmux-session-controls-verified.log` |
| Final shared actions/UI/journal/restart clients, normal | 9/9, 19.27 s | `build/bmux-session-controls-ready-final.log` |
| Same final gates, ASan/UBSan | 9/9, 33.64 s | `build-asan/bmux-session-controls-ready-final.log` |
| Corrected actual daemon restart fixture | 10 consecutive passes, 20.09 s | `build/bmux-session-controls-restart-repeat.log` |
| Actual SDL window, complete final Sessions workflow | Passed | `build/bmux-session-controls-real-sdl-final.log` |
| Actual terminal mouse export, normal and ASan/UBSan | Passed in each | `build/bmux-session-controls-pointer-final.log`, `build-asan/bmux-session-controls-pointer-final.log` |

`tests/bmux_ctui_sessions.lua` runs the actual Bmux CLI in a native PTY. It uses
Ctrl-B e, real pointer input, keyboard and bracketed paste to check persistence
status, new-file export, overwrite refusal, file import, saved-name inspection,
Unicode/narrow editor rendering and modal input isolation. The current PTY keeps
its PID and survives detach. An actual external checkpoint replacement is
preserved and shown as recovery-needed status. A second daemon starts the
imported name with a marker-writing default shell; its terminal remains stopped
without a PID and the marker never appears. A new actual Bmux client joins that
daemon, shows the retained Unicode output/inactive marker, and cannot acquire
input control or start the shell.

`tests/studio_bmux_sessions.lua` uses real SDL toolbar clicks and chooser/form
keyboard events for the same transfer workflow, including cancellation at the
second import field. It verifies disconnect closes shared action ownership and
leaves the source PTY running. Studio then joins the imported daemon and displays
the saved Unicode text in a read-only stopped native terminal without executing
the source's shell recipe, program label or history command. The actual SDL
window run covers this complete final flow; the captured
[Sessions chooser](../images/bmux-session-controls.png) was visually inspected.

The SDL test first exposed an invalid assumption that `core.project_dir` is
always set (`build/bmux-studio-sessions-callback-error.log`). The export default
now falls back to the current directory. A held real status reply reproduced
loss of an entered export path during a pending request
(`build/bmux-session-controls-busy-before.log`). The dialog now retains the path
for explicit Enter after the pending request completes, with no automatic
execution or retry. Both final builds and the real SDL run cover the correction.

`tests/bmux_session_files.lua` checks actual regular-file I/O: exclusive private
0600 creation, no overwrite, copied/demoted imports, 4 MiB bounds, malformed
documents, invalid paths, directories, symlinks and nonblocking FIFO refusal.
`tests/bmux_session_transfer.lua` retains the native transport/storage/restart
checks and adds host-pinned typed status, including changed-host rejection.

The final normal gate exposed the previously existing restart fixture's socket
readiness race (`build/bmux-session-controls-busy-final.log`): the socket can
exist before private permissions are applied. Both its main and rival daemon
waits now require the complete native-client type/mode contract; ten subsequent
clean/crash restart runs passed. The production ownership check remains intact.

BMUX-33 criterion 1451 is linked to bmux_session_restart, bmux_ctui_sessions and
studio_bmux_sessions and recorded passing. BMUX-33/97 remain open for explicit
corrupt-checkpoint recovery. These correctness and UI checks establish no speed
advantage over cmux and no untested platform/font parity.
