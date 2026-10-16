# Studio-managed local Bmux session

## Problem

Studio already has a Bmux workspace, attached layout views, server-owned agent
launch, common Fleet and persisted server sessions. The ordinary user path still
requires running `boggart serve --socket ...` separately and entering its socket
path in **Join layout**. That manual step hides the useful parts of Bmux and
makes reopening Studio depend on remembering local server details.

## User flow

When a user enters Studio's Bmux workspace without an explicit `bmux_server`
configuration, Studio connects to the local session for the canonical project
directory. If no server answers at that project's socket, Studio starts the
matching `boggart serve` executable as a detached child, waits asynchronously
for its private Unix socket, verifies the persistent session identity, and
joins it. On an empty session, **+ New terminal** or **+ New agent** creates a
workspace for the project; Studio does not create a duplicate workspace while
multiple clients attach. A later entry reconnects to the same server and
layout.

The server belongs to the project session, not the Studio window. Closing
Studio releases its layout and terminal attachments but leaves the detached
server, PTYs and running agents alive. Opening the project again reattaches to
those same live processes. If the server itself has stopped, its existing
SQLite journal restores only the restart recipes it already supports; foreign
executables remain inactive previews. Studio does not auto-replay an agent
launch or control command after an uncertain result.

The existing **+ New agent**, Fleet and Focus behavior remains the way to launch
and navigate Boggart, Codex and other providers. A configured `bmux_server`
continues to select the user's explicitly configured server. **Join layout**
continues to support entering another socket manually.

## Architecture

Add a focused Studio Lua owner, `core.bmuxlocal`, for managed local-server
identity and startup. It canonicalizes `core.project_dir`, hashes that path with
the existing native SHA-256 module, and derives a stable session name and short
socket filename beneath `bog.userdir/bmux`. The directory must be an owned,
private, non-symlink directory. Reject paths that exceed the native Unix-socket
length limit with a clear message; do not fall back to a public or project-tree
socket.

Startup first probes the expected socket. A live endpoint is accepted only when
`GET /layout/session` reports the exact expected persistent session name. When
the endpoint is absent, start `core.agentlauncher.boggart_command()` with
structured argv (`serve`, `--socket`, path, `--bmux-session`, name), detached
using the existing libuv pattern. Repeated requests in one Studio process share
one startup attempt. Multiple Studio processes may race to start, but the native
listener's private socket lock admits only one server; all clients then verify
the same session before joining. Readiness retries use one-shot libuv timers so
the SDL event loop remains responsive. Startup never kills an existing process
to recover a socket.

`core.bmuxlocal` calls the existing `core.bmuxlayout.join` once the status probe
passes. `shell.workspaces.bmux` starts this path on entry when no explicit
server configuration exists, and avoids creating a competing local shell while
the managed join is pending. The empty-layout notice directs the user to **+ New
terminal** or **+ New agent**. Those existing server operations create the
workspace. Studio does not create one when the journal status is blocked.
Manual join remains a separate command and does not acquire ownership of a
server it did not start.

No new control route, terminal owner, provider semantic adapter, Python runtime,
or persisted identity format is needed. C continues to enforce socket ownership
and mode, listener locking and process PTY behavior. Lua coordinates startup and
session identity; SDL3 continues presenting the existing Bmux workspace.

## Failure behavior

- Missing executable, failed spawn, occupied/wrong-session socket, overlong
  socket path, or readiness deadline produces a bounded actionable Studio
  error. The user can still use the existing explicit join or local Bmux
  terminal commands.
- A server with a different or non-persistent session identity is never joined
  automatically, overwritten or stopped.
- A session with a journal recovery error may be observed, but Studio must not
  create a new workspace or shell that could obscure the recovery state.
- Closing Studio only closes client observation and leases. It does not signal
  the detached server or its PTYs.
- The helper is POSIX/Unix-socket behavior. Windows keeps its existing explicit
  path until the ConPTY/socket work is ready.

## Verification

Use a real SDL Studio test and real detached Boggart servers in an isolated
`BOGGART_HOME`. The test launches Boggart and a fake Codex executable that makes
no network calls, proves first entry creates and joins the project session,
checks repeated entry does not create a second server, closes Studio, launches
Studio again and checks the same host and live process identities. It also
verifies project isolation, wrong-session refusal, safe local fallback,
overlong-path refusal and daemon restart using the existing shell and
foreign-inactive restore rules. The existing server-agent and layout suites
cover configured external-server behavior and resumable Boggart restoration.
Existing Bmux layout, server-agent, session-journal and recovery checks remain
the regression set.

Provider-specific attention is a separate next slice. Boggart approvals and
published provider events remain usable where already supported; this change
does not claim Codex semantic status or approval controls.
