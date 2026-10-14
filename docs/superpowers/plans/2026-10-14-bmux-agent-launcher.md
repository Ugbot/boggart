# Bmux agent launcher and common Fleet implementation plan

**Goal:** Launch real agent TUIs into Bmux and register Boggart and external
agents in the same Fleet roster, with honest process status and working controls.

**Architecture:** A shared Lua registry aggregates internal scheduler records and
native process-backed agents through adapters. Studio owns launch/focus/stop
callbacks; the registry owns bounded metadata and capability checks. Native C
PTYs keep literal argv, parsing, input and process cleanup. Rich IPC comes next.

- [x] Add a bounded common registry, stale-generation control rejection and
  literal quoted-argument parsing. Test registration, internal/external merging,
  capability rejection and retirement with real APIs rather than duplicated code.
- [x] Add New agent/New Boggart TUI/resume and external/custom launcher profiles.
  Register before spawn; track failed launch, hidden exit and manual pane close.
- [x] Make Fleet read the common model; external details offer working Focus and
  Stop, never internal scheduler/approval controls. Keep internal behavior intact.
- [x] Verify actual Boggart TUI rendering/input and non-Boggart PTY lifecycle,
  shared Fleet display/totals, cross-mode focus and stop/close/exit. Check normal,
  sanitizer, real SDL and embedded assets, document limits, commit and push.

The registry does not infer activity from ANSI text. Runtime event/control IPC,
manual-shell hook registration, rich provider adapters, worktrees and persistent
server ownership remain later parts of the accepted broad BMUX objective.

Verification: normal affected **11/11** (5.30s), ASan/UBSan **11/11** (11.92s).
After final argv/adapter ownership checks, focused normal **4/4** (2.51s) and
ASan/UBSan **4/4** pass. Actual SDL window tests cover real Boggart TUI typing,
quit/resume, foreign process lifecycle and Fleet controls. The 44-module/34-file
attribution gate and diff checks pass. The complete UI discovery script still
reports the same three workflows/model dropdown failures with baseline b9b9b99
Studio data and this change; they are tracked separately as BMUX-63.
