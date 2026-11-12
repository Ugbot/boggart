# Native checkpoint transfer verification

BMUX-98, macOS arm64, 2026-10-16. Normal and ASan/UBSan CLI/Studio builds
completed successfully. Final focused gates include the released-parser history
correction; broad gates preceded that correction. No product changes followed
the final gates. `git diff --check` passed.

| Gate | Result | Local evidence |
| --- | --- | --- |
| Broad terminal/control/Fleet/Studio/store, normal | 81/81, 46.89 s | `build/bmux-session-transfer-verified.log` |
| Same broad suites, ASan/UBSan | 81/81, 74.32 s | `build-asan/bmux-session-transfer-verified.log` |
| Final transfer/journal/restart/client gates, normal | 10/10, 7.72 s | `build/bmux-session-transfer-ready-final.log` |
| Same final gates, ASan/UBSan | 10/10, 17.10 s | `build-asan/bmux-session-transfer-ready-final.log` |
| Transfer repeated through actual daemon startup/save/restart | 30 consecutive passes, 15.20 s | `build/bmux-session-transfer-repeat-fixed.log` |

`tests/bmux_session_transfer.lua` covers native control routes and the shared
transfer client, read-only capability denial, host/name/query/data validation,
existing/corrupt checkpoint preservation, occupied/invalid owner preservation,
storage errors and owner release. A real existing PTY keeps its identity and
stays alive while a separate named checkpoint is imported.

The fixture includes default-shell and Boggart automatic recipes, an existing
local Boggart thread, command-looking informational program/history strings,
Unicode history and layout aliases/splits/zoom. The raw trusted-looking document
is submitted directly to prove server-side demotion independently of the
client. Actual daemons start the imported session twice, with a real final save
between them. Every terminal remains stopped without a PID; Boggart resume IDs
remain metadata. A default shell executable would append a marker if invoked;
the marker never appears. Input to inactive previews is rejected. Captures and
resaved checkpoints retain `saved` recipes, shared aliases and Unicode output.

Malformed import acknowledgements disable further client mutation. Reading the
named checkpoint remains available and cannot replay or re-enable the POST.

Review added a failing reproduction for exporting a released parser's retained
history (`build/bmux-session-transfer-history-before.log`). Export now copies
the journal's history-cache index before capture; it preserves retained text
without mutating the journal's cache. The final normal and sanitizer gates cover
the correction. A repeated native test exposed a readiness race in the test:
the Unix socket can exist briefly before private permissions are applied.
The test now waits for the complete native-client ownership/mode contract, and
preserves the original failure if cleanup also fails. Thirty subsequent runs
passed.

The focused gates select bmux_checkpoint, bmux_session_transfer, bmux_journal,
bmux_session_restart, bmux_layout_server, bmux_layout_client, bmux_fleet_client,
studio_bmux_layout, studio_server_agents and control_unix. The existing real
restart tests retain clean shutdown/crash/dead-owner recovery coverage.

This verifies the native transfer boundary. Studio/terminal session menus and
explicit corrupt-session recovery remain BMUX-97; BMUX-33 stays open. No
performance-superiority or cross-platform rendering claim follows from these
macOS correctness gates.
