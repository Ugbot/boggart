# Explicit recovery verification

BMUX-100, macOS arm64, 2026-10-16. Normal and ASan/UBSan CLI/Studio builds
passed. The final broad gates include the recovery critical-section admission,
readable confirmation, imported Boggart recovery proof and TEXT/BLOB byte-match
correction. No product changes followed them. `git diff --check` passed.

| Gate | Result | Local evidence |
| --- | --- | --- |
| Final native terminal/control/Fleet/Studio/store gate, normal | 86/86, 51.20 s | `build/bmux-recovery-bytes-verified.log` |
| Same final gate, ASan/UBSan | 86/86, 83.58 s | `build-asan/bmux-recovery-bytes-verified.log` |
| Pre-byte-correction focused persistence/owner/admission gate, normal | 12/12, 11.33 s | `build/bmux-recovery-agent-final.log` |
| Same focused gate, ASan/UBSan | 12/12, 19.15 s | `build-asan/bmux-recovery-agent-final.log` |
| Final actual SDL window: complete recovery and restart workflow | Passed | `build/bmux-recovery-bytes-real-sdl.log` |

`tests/bmux_journal_native.lua` exercises owner-guarded absent/update/delete/check
operations across two real SQLite connections, stale owner/data rejection,
embedded NULs and exact comparisons across SQLite TEXT/BLOB storage classes.
The latter first failed in `build/bmux-recovery-blob-before.log`; comparisons now
cast both operands to bytes. `tests/bmux_recovery.lua` starts from actual binary
corrupt BLOB data and checks private raw/metadata archives, exact byte retention,
consumed previews, stale revision/data/owner conflicts, live rival/invalid-owner
refusal, archive/storage failures, nil versus empty originals and subsequent
startup. It verifies journal subscription recovery using actual PTY output and
checks subscription failure returns an observable blocked journal without
leaking an owner lease.

Explicit inspection of idle external corruption first failed in
`build/bmux-recovery-idle-before.log`. Preview now verifies saved bytes under the
current owner, detects the replacement without idle polling, and still rejects
healthy unchanged sessions. Archive files and sidecars are synced, then both
their directory and parent are synced before the guarded SQLite replacement.

`tests/bmux_recovery_client.lua` verifies real native routes/capabilities, bounded
commands, exact preview/archive/status acknowledgement validation, unchanged
ordinary status shape, one-shot admission and no mutation replay after an
uncertain response. It invokes the actual layout HTTP route during the archive
interval to verify 409 admission, then edits successfully after recovery.
Recovery metadata uses a separate status endpoint, preserving older clients.

`tests/bmux_ctui_sessions.lua` uses actual terminal pointer, keyboard and paste
events for preview, Escape cancellation, wrong-name rejection and confirmation.
It checks the exact original file, unchanged live PID and later automatic saves
through the existing input controller. `tests/studio_bmux_sessions.lua` uses
actual SDL toolbar/dialog events, preserves binary originals, resumes later
layout saves, quits/restarts the recovered imported daemon, joins it again and
verifies read-only stopped output with no marker execution. The original source
PTY remains alive throughout. The final actual SDL run covers the same flow;
the [confirmation](../images/bmux-session-recovery.png) was visually inspected.
The full saved name is shown separately from its short prompt label.

`tests/bmux_session_transfer.lua` adds recovery between its two real daemon
starts. The imported document contains a valid local Boggart resume reference;
shell and agent recipes remain saved through recovery, capture, final save and
the next startup. No native PID or marker shell appears. Existing
bmux_session_restart retains trusted shell/Boggart clean/crash restore, cwd,
Unicode history, aliases, focus/zoom and fresh-host/owner coverage.

This completes BMUX-100, BMUX-97 and BMUX-33's persistence/import/recovery scope.
The broader Bmux roadmap remains active. These are correctness/UI gates, not a
speed comparison against cmux or proof of untested platform/font parity.
