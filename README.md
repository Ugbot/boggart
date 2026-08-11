# boggart

A tiny coding agent with a C core and an **embedded Lua runtime that the agent
can rewrite at runtime**. The C side is deliberately dumb — a Lua VM, an HTTP
transport, a line editor, and the baked-in default scripts. Everything
interesting (the agent loop, the tools, the memory, the system prompt) is Lua,
and the model is encouraged to edit that Lua and hot-reload it. It ships as a
single embedded executable.

It feels like `pi` (four core tools, tight context, no product opinion) but,
unlike most harnesses, it can grow its own capabilities: give it a task and it
can write itself a new tool.

## Design

Two references shaped this: antirez's **ds4** agent harness (the loop
*mechanics*) and rxi's **lite** editor, whose C+Lua core boggart-studio grew
out of and now owns outright.

- **The C core knows nothing about the LLM.** `http.request` streams bytes to a
  Lua callback; subprocesses run on the libuv loop from `lua/proc.lua`; that's
  most of it. The Anthropic client, SSE parsing, and tool loop live in `lua/api.lua`.
- **Overlay mutability.** Every module loads from `<data dir>/lua/<name>.lua`
  if present, else from the copy baked into the binary. The agent edits its own
  Lua with the ordinary `write`/`edit` tools and calls `reload` to hot-swap it;
  a syntax error keeps the old code and hands back the error.
- **Tools are data.** `define_tool` lets the model author a new tool (name,
  description, JSON schema, Lua body) that exists on the next turn and persists
  to `<data dir>/lua/tools/<name>.lua`.
- **A golden starting point.** The baked-in Lua *is* the pristine "golden" setup
  the agent forks from — `boggart init` materializes it for editing, `--reset`
  restores it. Its starting toolkit is the `gold` blessed stdlib (`gold.str`,
  `.tbl`, `.fs`, `.pp`, `.args`, `.test`, `.sh`), a global the agent and its
  tools compose instead of reinventing basics.
- **One local database.** Everything durable lives in an embedded SQLite DB at
  `<data dir>/boggart.db` (the amalgamation is vendored with FTS5, so it stays a
  single exe): memory is a full-text-searchable table, conversations are saved
  as resumable sessions, plus a key/value table and harness metadata. Exposed to
  Lua as `db.*` and to the model as the `sql` and `kv` tools.
- **Borrowed from ds4:** tool failures are normal `tool_result`s prefixed
  `Tool error:` (the model retries, nothing crashes); there is no artificial
  tool-call ceiling; big command/file output is saved to a temp file and only a
  head is returned; `edit` matches `old` exactly once and returns post-edit
  context; context pressure triggers a summarize-and-keep-tail compaction.
- **Borrowed from lite:** the `bog.try` xpcall funnel, `strict.lua` (misspelled
  globals become loud errors — invaluable for model-written Lua), and the
  `package.path` + custom-searcher overlay.

## Build

```sh
cmake -B build -G Ninja     # configure
cmake --build build         # → ./boggart (one binary; libcurl is the only dynamic dep)
ctest --test-dir build      # fifteen Lua suites, each against a throwaway HOME
```

Requires CMake ≥ 3.20, Ninja, a C compiler, and libcurl (present in the macOS
SDK; built from source with the Schannel backend on Windows). Lua 5.4, SQLite,
cJSON, libuv, luv, ltui/PDCurses and isocline are vendored under `src/vendor/`
and built statically. The binary is written to the source root so the invocations
below work as documented; everything else stays in `build/`.

On Apple silicon the build re-signs the binary ad-hoc after linking — a stale
linker signature is what makes macOS `SIGKILL` a freshly built arm64 exe.

There is no longer a plain-`make` fallback: the build now pulls in libuv, luv,
ltui/PDCurses and isocline, all with their own flag sets, and maintaining a
second description of that by hand was a standing source of drift.

## Use

Auth: set `ANTHROPIC_API_KEY`, or log in once with the `ant` CLI (`ant auth
login`) and boggart will use that token.

```sh
./boggart                 # interactive REPL (single agent)
./boggart "one-shot task" # run a single prompt and exit
echo "task" | ./boggart --headless   # scriptable: prompt on stdin, reply on stdout
./boggart swarm           # interactive coordinator that fans out to sub-agents
./boggart swarm "task"    # one-shot multi-agent orchestration
./boggart swarm --resume  # redeliver unprocessed journalled messages and continue
./boggart init            # copy the default Lua into the data dir to edit
./boggart --reset [file]  # revert an overlay file (or all) to the baked-in default
./boggart doctor          # check the install and say, in plain words, what is wrong
./boggart --help          # every flag, subcommand and environment variable
```

REPL commands: `/help /tools /auth /doctor /memory /sessions /resume <id> /reload /reset [file] /model <id> /new /quit`.
Swarm commands: `/help /threads /journal [n] /agents /model <id> /quit`.

### Where boggart keeps its files

One directory holds everything: the SQLite store (`boggart.db`), the credential
file (`auth`, 0600), your overlay Lua (`lua/`) and the REPL history. It is
chosen once, in C (`src/bogpaths.h`, `sys.paths()`), by this order:

1. **`$BOGGART_HOME`**, verbatim — moves the store, the credentials and the
   overlay together. A second install, a test, a shared home: one variable.
2. **An existing `~/.boggart`**, if you already have one. Boggart never
   relocates a directory you are already using.
3. Otherwise the platform location, for a new install:
   - **Linux** `$XDG_DATA_HOME/boggart`, defaulting to `~/.local/share/boggart`
   - **Windows** `%LOCALAPPDATA%\boggart` (not `%APPDATA%` — a multi-megabyte
     store with a WAL sidecar has no business roaming)
   - **macOS** `~/.boggart`, deliberately not `~/Library/Application Support`:
     this directory is the agent's own editable source and a credential file,
     i.e. things people grep, diff and back up, and a Finder-hidden path with a
     space in it is hostile to all three.

Everything in it is created on demand, on every start — directories, database,
schema. Missing pieces are the normal state of a new machine, not an error.
A database that fails `PRAGMA integrity_check` is moved aside to a timestamped
`boggart.db.corrupt-<stamp>` and recreated, loudly: sessions and memories in it
are gone, and boggart says so rather than pretending it recovered them. Nothing
is ever deleted. A store written by a *newer* boggart is refused, untouched,
with an explanation.

`boggart doctor` reports all of it — which directory and why, whether it is
writable, database size/integrity/schema, whether a credential is set **and
where it came from** (`ANTHROPIC_API_KEY` in the environment silently beats the
stored file), the endpoint, MCP servers configured versus actually connecting,
overlay files shadowing built-in modules, and free disk. It exits non-zero when
something is genuinely broken, so `boggart doctor >/dev/null || ...` works in a
script. `/doctor` prints the same report inside the REPL.

## Swarm mode — all agents are actors

A separate mode adds lightweight **agentic fan-out**. The unit is an *agent*, which
is just a conversation **session** plus its own **journal** (its slice of the
message log), a **skills** list (bundles of instructions + a permitted tool
set), a **mailbox**, and its **tool calling**. Every agent — the coordinator and
every sub-agent — is an actor on one internal pub/sub bus; they differ only by
spec and lineage. Fan-out is the coordinator spawning child agents that run
**concurrently** (async `curl_multi` plus a libuv loop under a cooperative
scheduler — no OS threads for actors) and report back.

- **Messaging machinery is in C** (`src/lswarm.c`): per-agent FIFO mailboxes,
  topic pub/sub, and a write-through **journal** to the same SQLite DB. Lua owns
  only agent *behaviour* and a ~60-line scheduler (`lua/sched.lua`).
- **Standard agents** (`lua/agents/*.lua`: coordinator, researcher, coder,
  critic) and **skills** (`lua/skills/*.lua`: core, comms, orchestrate, memory,
  data, selfmod) are overlay-mutable like everything else.
- **Coordination tools**: `spawn`, `await`, `send`, `publish`, `subscribe`,
  `inbox`, `threads` — an agent only gets the tools its skills permit.
- **Durable + resumable**: agents are persisted sessions; every bus message is
  journalled with a `processed_at` stamp, so `--resume` reloads and redelivers
  anything unhandled.

The default single-agent path is untouched: it stays synchronous, bus-free, and
uses the blocking HTTP transport.

## MCP (Model Context Protocol)

boggart can connect to MCP servers; the **client lives in C** (`src/lmcp.c`) and
speaks both transports — **stdio** (launches the server as a subprocess) and
**Streamable HTTP** (via libcurl). The philosophy is "MCP servers are just
tools": on connect, each server tool is registered as an ordinary tool named
`mcp__<server>__<tool>`, so it flows through the normal tool loop with no
special-casing. A thin Lua module (`mcphost.lua`) does the registration.

The differentiator is **per-agent tool management**: because MCP tools are
normal registry entries gated by skill allowlists, you can have many servers
connected while each agent sees only the slice its skills grant — a whole server
via a wildcard (`mcp__github__*`) or individual tools (`mcp__github__create_issue`).
This keeps each agent's tool surface (and context) small.

Connect servers at startup by declaring them in `~/.boggart/lua/mcp_servers.lua`
(a Lua module returning `{ {name=, command=, args=}, {name=, transport="http",
url=, headers=}, ... }`), or at runtime with the `mcp_add` tool; `mcp` lists
connected servers. v1 is tools-only (resources/prompts, the server→client SSE
channel, OAuth, and exposing boggart *as* an MCP server are future work).

Default model is `claude-opus-5` (adaptive thinking; no sampling params).

## Events — autocommands for the agent

Every other extension point in boggart runs one way round: the agent calls a
tool, the agent draws a panel. `lua/events.lua` is the inversion, taken from
Neovim's autocommands — Lua **registers interest** and the harness calls it:

```lua
local events = require("events")            -- or bog.events

local h = events.on("tool:*", function(name, data)
  events.notify(name .. " " .. data.name)   -- vim.notify, both worlds
end, { desc = "trace tool calls", once = false })

events.off(h)                               -- or events.off(h.id)
events.list()                               -- every registration, in firing order
events.emit("my:event", { ... })            -- your own events are fine too
```

Patterns are **globs, not Lua patterns**: `*` is the only metacharacter
(`"tool:*"`, `"file:write"`, `"*"`). Handlers fire in registration order.

| event | payload |
| --- | --- |
| `session:created` / `session:saved` / `session:resumed` | `{ id, count }` |
| `turn:start` | `{ session, preview, chars }` — preview is the first 200 chars |
| `turn:text` | `{ session, text }` — one streamed delta (hot) |
| `turn:end` / `turn:error` | `{ session, stop }` / `{ session, message, kind }` |
| `tool:before` / `tool:after` | `{ name, input }` / `{ name, error, bytes }` |
| `tool:refused` | `{ name, reason }` — a permission gate stopped it |
| `context:compacted` | `{ session, before, after }` (chars) |
| `file:write` / `file:edit` | `{ path, bytes, lines }` |
| `swarm:actor_started` / `swarm:actor_stopped` | `{ id }` / `{ id, reason }` |
| `notify` | `{ msg, level }` |

Payloads carry identifiers and sizes, never transcripts or file contents: an
event nobody can afford to subscribe to is an event nobody subscribes to.
`events.EVENTS` is the same table, in the binary.

**Registering from your own Lua**: drop a file in `~/.boggart/lua/events/`
(*not* `~/.boggart/lua/events.lua` — that path is the overlay copy of the module
itself). Each file is called with the module as its only argument and is re-read
on every `reload`:

```lua
-- ~/.boggart/lua/events/audit.lua
local events = ...
events.on("file:*", function(ev, d)
  bog.store.kv_set("last_" .. ev, d.path)
end, { desc = "remember the last file touched" })
```

**Registering from the agent**: the `on_event` tool is `define_tool`'s mirror
image (`op = on | off | list`). Those handlers are **session-only** and
deliberately so — a persisted tool waits to be called in a conversation someone
is watching, while a persisted handler would run on every future start, on every
matching event, with no approval gate to put in front of it. Durable reactions
go through a file the user can see, which the agent may write with `write`.

**Isolation**: each handler runs in its own coroutine. Throwing affects neither
the emitter nor the other handlers (it is reported through `notify`, and five
failures unsubscribe it); yielding — `sys.exec` under the swarm scheduler —
gets the handler dropped rather than allowed to suspend the agent's turn. A
handler that loops forever still wedges the agent: bounding that needs a debug
hook, and `tools.lua` already uses the one hook slot for generated tool bodies.
Emitting with nothing subscribed costs one comparison, so the hot events
(`turn:text`) are free when nobody is listening.

## Layout

```
src/            C core: boggart.c (main), lhttp.c (curl: blocking + async multi),
                lsys.c (os), ldb.c (SQLite), lswarm.c (bus+journal),
                lmcp.c (MCP client: stdio + Streamable HTTP), embedded.c (generated)
src/vendor/     vendored Lua 5.5 + sqlite (FTS5) + cJSON + libuv + luv
                + ltui/PDCurses + isocline
studio/         boggart-studio, the desktop app: an SDL window whose main
  src/            surface is the conversation, with an editor behind it.
  data/core/      agentview (chat), sidebarview (chats + Chat/Code),
                  widgets (buttons), studio (commands), recipes, diff
lua/            the golden default harness, baked into the binary:
  boot.lua        overlay loader, wiring, hot-reload, sessions, REPL, dispatch
  api.lua         Anthropic client: shared SSE decoder + sync & async transports + turn loop
  tools.lua       read/write/edit/bash/list + define_tool/on_event/reload + sql/kv + memory
  events.lua      autocommands: on/off/emit/notify, glob patterns, <data dir>/lua/events/
  store.lua       SQLite store: memory(FTS5), sessions/threads, journal, kv, meta
  lifecycle.lua   install, first run, self-repair, `doctor` (also callable from the GUI)
  memory.lua      durable memory (backed by store) + prompt index
  prompt.lua      system prompts (single-agent discipline + swarm coordinator)
  util.lua json.lua strict.lua      helpers, JSON, undefined-global guard
  gold.lua gold/  golden stdlib: str, tbl, fs, pp, args, test, sh
  sched.lua       cooperative actor scheduler (swarm)
  thread.lua      an agent = session + journal + skills + mailbox + tools (swarm)
  skills.lua skills/    skill bundles (core, comms, orchestrate, memory, data, selfmod)
  agents.lua agents/    standard agents (coordinator, researcher, coder, critic)
  tools_swarm.lua swarmmode.lua      swarm tools + the swarm mode entry
  mcphost.lua     MCP glue: register server tools as mcp__<server>__<tool>
tools/          gen_embedded.sh (bakes lua/ into src/embedded.c)
tests/          test.lua (units), integration.lua (turn loop), swarm.lua (actors/bus/journal)
```

## Credits & licenses

- Lua 5.4 — MIT (© Lua.org, PUC-Rio), vendored in `src/vendor/lua/`.
- SQLite — public domain, amalgamation vendored in `src/vendor/sqlite/`.
- libuv — MIT, vendored in `src/vendor/libuv/` (event loop, processes, fs).
- luv — Apache-2.0 (© the luvit authors), libuv bindings for Lua.
- ltui — Apache-2.0 (© tboox), terminal UI; PDCurses (public domain) on Windows.
- isocline — MIT (© Daan Leijen), the line editor; replaced linenoise, which
  had no Windows port.
- `strict.lua` and several harness patterns adapted from rxi/lite — MIT (© rxi).
- Loop mechanics studied from antirez/ds4.
