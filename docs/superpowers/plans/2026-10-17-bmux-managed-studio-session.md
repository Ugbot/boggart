# Studio-managed local Bmux session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Studio's Bmux workspace start or rejoin the current project's persistent local server without requiring a manual `boggart serve` command or socket path.

**Architecture:** A focused Studio Lua module derives a stable private socket and journal name from the canonical project root, verifies the endpoint's session identity, and starts the sibling Boggart executable as a detached child only when the endpoint is absent. The existing joined-layout, terminal, Fleet, and checkpoint owners remain authoritative; Bmux entry stays asynchronous and manual external-server join remains available.

**Tech Stack:** C11 native Unix-socket/PTY runtime, Lua/libuv orchestration, SDL3 Studio workspace, CMake/CTest integration tests.

## Global Constraints

- Keep runtime and UI code in C/Lua/SDL3; add no Python runtime or tooling.
- Start Boggart with structured argv through `uv.spawn`; never construct a shell command string.
- Place managed sockets beneath an owned 0700 directory and accept only the exact persistent session identity expected for the project.
- Studio disconnect/quit releases client views and leases but never stops the detached server or its PTYs.
- Preserve explicit `bmux_server` configuration and manual **Join layout** behavior.
- Never auto-replay uncertain terminal or agent commands.
- Do not infer foreign-agent prompt or approval capabilities from terminal text.

---

### Task 1: Add the managed project-server owner

**Files:**
- Create: `studio/data/core/bmuxlocal.lua`
- Modify: `CMakeLists.txt`
- Modify: `tests/studio_bmux_autostart.lua`

**Interfaces:**
- `core.bmuxlocal.project_paths(project_dir, userdir)` returns the canonical root, private socket path, and stable persistent session name, or `nil, reason`.
- `core.bmuxlocal.ensure(callback)` attaches to a matching live endpoint or starts exactly one detached `boggart serve` attempt and calls back with the verified session socket, status, or a bounded error.
- The module exposes a cancel operation for its temporary probes/timers; cancel never signals the server process.

- [x] Add path and lifecycle assertions to the SDL autostart fixture: symlink canonicalization, stable/distinct project keys, private directory, bounded socket paths, a detached project server, and wrong-session refusal with local fallback.
- [x] Implement the manager using `hash_c.sha256`, `uv.fs_realpath`, `uv.fs_lstat`, `uv.getuid`, `uv.fs_mkdir`, `core.agentlauncher.boggart_command`, `terminal.client`, structured argv and the existing `--bmux-session` option. The server starts with the canonical project as its working directory.
- [x] Build Studio and run both phases of `studio_bmux_autostart`; the fixture attaches to the project daemon and records its PID/host identity.

### Task 2: Connect Bmux workspace entry to the manager

**Files:**
- Modify: `studio/data/shell/workspaces/bmux.lua`
- Modify: `studio/data/core/bmuxlayout.lua`
- Modify: `studio/data/core/bmuxagents.lua`
- Modify: `studio/data/core/bmuxlayoutui.lua`
- Modify: `studio/data/core/terminalview.lua`
- Modify: `studio/data/shell/bmuxtoolbar.lua`
- Modify: `studio/data/shell/init.lua`
- Modify: `tests/studio_bmux.lua`
- Modify: `tests/studio_agent_hooks.lua`
- Modify: `tests/studio_provider_events.lua`
- Modify: `tests/studio_fleet_agents.lua`
- Modify: `tests/studio_manual_agents.lua`
- Modify: `tests/studio_server_agents.lua`
- Modify: `tests/studio_terminal_attached.lua`

**Interfaces:**
- Bmux workspace entry calls `core.bmuxlocal.ensure`; after its verified callback it joins via `core.bmuxlayout.join`.
- The workspace exposes a pending/error status to its toolbar and a retry command. The empty-layout notice points to **+ New terminal** and **+ New agent**, which already create the first project workspace. Do not initialize layout while the journal is blocked.
- `config.bmux_server == false` keeps the existing local-only Bmux workflow for callers that explicitly request it; a configured server table remains a direct explicit target and is never replaced with a managed server.

- [x] Add real Studio assertions for automatic attachment and safe failure fallback; a wrong-session endpoint stays alive and is never adopted or replaced.
- [x] Enter Bmux without configuration and auto-attach; launch Boggart/Codex and create a terminal in an empty project session; enter again and verify the same server is reused.
- [x] Set `config.bmux_server=false` in legacy local-workspace fixtures and keep their local tab/split/process checks passing.
- [x] Keep manual **Join layout**, configured external-server behavior and **Disconnect layout** coverage intact. Preserve Ctrl-Alt application shortcuts from controlled remote terminals.
- [x] Run the Bmux layout/Fleet/agent regression selection; all selected tests passed.

### Task 3: Prove the actual close/reopen agent workflow and document it

**Files:**
- Create: `tests/studio_bmux_autostart.lua`
- Create: `tests/run_studio_bmux_autostart.sh`
- Create: `tests/fixtures/bmux_fake_codex.sh`
- Modify: `CMakeLists.txt`
- Modify: `docs/bmux-studio-layout.md`
- Modify: `docs/bmux-studio-agents.md`

- [x] Add a real SDL/PTY fixture with an isolated `BOGGART_HOME` and fake Codex executable; server-launched Boggart and Codex rows both appear in common Fleet.
- [x] Quit the first Studio process without stopping the detached server; a second Studio process reuses the same host and live server/agent PIDs, then focuses both existing panes.
- [x] Restart the managed daemon and verify journal restore starts the supported shell, leaves foreign Codex inactive and retains the project session name. Existing `bmux_session_restart` also verifies resumable Boggart restoration.
- [x] Add project identity/isolation, wrong-session, private-directory and overlong-path cases; wrong-session and external configured servers remain untouched.
- [x] Document automatic startup, manual external join, server lifetime, inactive foreign-agent restart behavior and the separate attention-hook follow-up.
- [x] Run `studio_bmux_autostart` and the affected Studio/Bmux regression suites; all selected tests passed.
- [x] Run `git diff --check`, inspect the final diff, build Studio and Boggart, and pass the affected 14-test Bmux/Fleet/terminal suite.
