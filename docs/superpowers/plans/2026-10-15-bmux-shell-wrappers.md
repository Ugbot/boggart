# BMUX shell wrapper implementation plan

> Execute sequentially in the current feature branch; no extra agents needed.

**Goal:** Ordinary detected agent commands in BMUX shells register in the common
Fleet without requiring the user to remember `ctl run`.

**Architecture:** Extend the existing approved agent-control design's installed
wrapper path. Lua creates private, temporary POSIX shell entrypoints for detected
Codex, Claude, OpenCode and Gemini commands plus the sibling Boggart executable.
Each executes the native wrapper with literal argv and a resolved real executable.
Per-child PATH injection keeps other terminals and user dotfiles untouched.
The native explicit wrapper skips the injected directory when resolving its root
command, so explicit wrapping does not create duplicate records. Nested agent
commands retain PATH discovery. Provider notify hooks remain BMUX-47 follow-up.

**Tech stack:** C11+, Lua, existing libuv/PTY/UDS and Fleet registry.

- [x] Add `tests/agenthooks.lua` for installed-profile discovery, literal arguments,
  utility bypass, private creation, repeat/collision behavior and owned cleanup.
- [x] Implement `lua/agenthooks.lua`: `install{directory,executable,path,cwd,
  previous_bin,disabled}` returns a wrapper set (`bin`, `path`, `commands`,
  idempotent `cleanup`) or nil/error. Preserve replacements and unrelated files.
- [x] Update `core.manualagents` to install once, inject PATH plus
  BOGGART_AGENT_BIN alongside pane context and remove owned wrappers on shutdown.
  BOGGART_AGENT_HOOKS=0 disables automatic wrappers. Missing sibling CLI reports
  the limitation without making terminal creation fail.
- [x] Update native `ctl run` root executable lookup to skip the injected bin
  directory by filesystem identity. Preserve target argv and child PATH.
- [x] Add real application-loop Studio coverage with fixture provider executables:
  ordinary commands, utility bypass, literals/stdin, exact exit, nested agents,
  explicit wrapper deduplication, per-pane focus, opt-out and cleanup.
- [x] Run focused normal and ASAN/UBSAN checks plus an actual SDL workflow.
- [x] Update usage/design evidence and tracker; review the complete increment.

Landing uses a signed-off commit and push on the existing feature branch;
BMUX-67 records its landing status.

First-argument utility bypass is provider-specific; this is command lifecycle
registration, not structured provider activity/approval telemetry. Absolute-path
launches and commands hidden by shell aliases/functions remain explicit-wrapper
or launcher paths. Do not claim generic process discovery or complete BMUX-47.
