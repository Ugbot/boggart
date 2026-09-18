# The tmux story -- boggart as a persistent, reattachable session host

**Status: design, drafted 2026-09-18.** Thinking, not implementation. The prompt
was: "the tmux story could simply be part of boggart. but that needs thinking."
This is the thinking. It builds on what ships: the studio pane tree
(`docs/studio-panels.md`, `studio/data/core/rootview.lua`), the embedded PTY
(`studio/src/api/pty.c`, `studio/data/core/terminalview.lua`), the cTUI
(`lua/tui.lua`), the control plane (`src/lserve.c` + `lua/control.lua`, HTTP +
SSE, `boggart serve`), and the project store (`lua/project.lua`).

## 1. What "tmux as part of boggart" actually means

"tmux" is four features wearing one name. Boggart wants some and not others.
Enumerate before picking.

- **(a) Integrated multiplexer.** Boggart hosts terminals + splits inside its
  own UIs. The studio already has this (arbitrary nested `Node` splits, tabs,
  drag-resize) and a PTY-backed `TerminalView`. The cTUI has none of it -- one
  transcript, one input, one agents pane, no splits. So (a) is *half-built in
  the studio and absent in the cTUI*.
- **(b) Persistent server with detach/reattach.** The core tmux feature: a
  session lives in a server process; you close the terminal, the work keeps
  running, you reattach later and everything is still there. For boggart this
  means an agent's hour-long task, its terminals, and its layout survive the
  client disconnecting.
- **(c) Driving an external tmux** (`tmux -CC` control mode) as one of the
  "systems boggart is a user of" (`docs/team.md`).
- **(d) Some blend.**

### The pick: (b) primary, (a) as its local rendering, (c) rejected

**Primary is (b): boggart becomes a persistent, reattachable session host.**
Justification in one line: boggart's value is long-running agents and the swarm
(`docs/compounding.md`), and the single feature that turns "an agent ran for an
hour" into "an agent ran for an hour *and I could leave and come back*" is
detach/reattach -- which real tmux has and no agent tool has.

The blend, precisely:

- **(b) is the story.** It is the distinctive win and it reuses what boggart
  already is -- a server (`boggart serve`) holding sessions and a scheduler on
  one uv loop (memory: async-event-loop-model), with a project store for
  durable context. tmux had to invent a server; boggart already runs one.
- **(a) is the prerequisite, not the point.** You can only reattach to panes if
  panes exist. The studio has them; the cTUI needs a minimal split model
  (section 3). But an integrated multiplexer that is not detachable is just a
  worse terminal emulator -- table stakes, not a reason to exist.
- **(c) is a non-goal.** Boggart hosting its own sessions is the whole thesis of
  "one binary, whole stack" (`docs/team.md`). Driving an external tmux would put
  the session's truth in a process boggart does not own and cannot serialize,
  reattach cross-client, or attribute. A terminal *inside* boggart can of course
  run `tmux` (section 6); boggart the runtime does not delegate its session model
  to it.

The one-sentence framing: **a boggart session is a server-side object -- agents,
terminals, panes, layout -- that any client (cTUI or studio) attaches to,
detaches from, and reattaches to, with the work continuing in between.**

## 2. The detach/reattach model: server, client, wire

### The inversion this requires

Today the UI *is* the process. `lua/tui.lua` `M.run` owns the uv loop, creates
the coordinator agent in-process, and pumps `bog.sched` itself; the studio does
the same. Close it and the agents die with it. That is the thing detach/reattach
forbids.

The move is the one boggart already made for `boggart serve`: **the session
lives in the server; the UI becomes a client.** The server holds the scheduler,
the agents, the sessions, the terminals, and the layout tree. The cTUI and
studio stop *being* the runtime and start *rendering* it.

- **The server** is `boggart serve` (`src/lserve.c` + `lua/control.lua`),
  extended to own **session objects**. A session object is the reattachable
  unit: `{ project, agents (scheduler actors), terminals (pty handles + parsed
  grids), layout (the Node/pane tree) }`. It already owns most of this -- the
  serve daemon runs the scheduler and holds sessions; what it does not yet own
  is the **layout** and the **terminals**, which today are born inside the UI.
- **The client** is a thin cTUI or studio: it opens a connection, gets a
  snapshot of the session (layout + each terminal's cell grid + each transcript),
  renders it, sends input, and streams live deltas. Detach = close the client.
  The server keeps running. Reattach = a fresh client asks for the same session
  id and gets a fresh snapshot.
- **The wire** is the control plane that exists: HTTP for request/response
  (list sessions, attach, send input, resize), SSE `/events` for the live push
  (the bus already broadcasts every event; `docs/control-surfaces.md`). A turn's
  tokens, a terminal's output deltas, an agent's status change -- all already
  events on the bus. Attach is "subscribe to this session's topic and pull the
  current snapshot." This is exactly the **session-share** artifact team.md M5
  already scopes ("an invitation plus an event-stream cursor; live collaboration
  rides the bus, not a new mechanism") -- detach/reattach is session-share where
  the two endpoints are the same person at two times.

### Relating to the existing stores

- **Projects are the durable context** (`lua/project.lua`): a session belongs to
  a project, and the project already round-trips through the store. A **detached
  session is a live server-side object**; a **closed session is a project row**
  (its transcript is already persisted via `bog.store.thread_save`, its layout
  via the section-5 serializer in `docs/studio-panels.md`). So there are two
  resumes, and they must not be confused:
  - **Reattach** (new): the agents are *still running* server-side; you rejoin
    live work. This is the tmux feature.
  - **Resume** (exists): `boggart --tui --resume` reloads a *dead* session's
    transcript from the store and starts fresh agents. This is not tmux; it is
    reopening a saved file.
- **One uv loop** (memory: async-event-loop-model): the server already sleeps in
  one unbounded `uv.run`, every agent a coroutine on `bog.sched`, every socket
  and timer a handle. A detached session is simply actors that keep being resumed
  by that loop with no client attached. Nothing new in the scheduling model --
  the client was never load-bearing for *running*, only for *watching*. This is
  already the cTUI's own internal rule (the scheduler keeps the loop, the UI
  paints one frame per step); detach just removes the painter.

## 3. Vocabulary: session / window / pane on boggart's trees

tmux's nouns map cleanly, and boggart already has two of the three shapes.

| tmux | boggart | status |
|---|---|---|
| **server** | `boggart serve` | ships |
| **session** | the session object of section 2 (a project's live work) | new: must move server-side |
| **window** | a workspace (AGENT / EDIT / FLEET in the studio; the whole screen in the cTUI) | studio ships; cTUI has one |
| **pane** | a `Node` leaf holding a view (`DocView`, `AgentView`, `TerminalView`, ...) | studio ships; cTUI absent |
| **pane running a shell** | a `TerminalView` over a `pty` handle | ships (studio only) |

### The studio side is done; the model is the Node tree

The studio's `Node`/`RootView` split tree (`docs/studio-panels.md` section 2) is
already the pane model, and its section-5 serializer already turns a layout into
data. That serializer is the **canonical layout representation** for a session --
the thing the server holds and ships to any client. `TerminalView` + `pty.c` is
already the pane-running-a-shell. Nothing to invent here; the work is *hosting*
it (section 5), not *building* it.

### The cTUI needs a pane model -- but a minimal, shared one

The cTUI (`lua/tui.lua`) draws one full-screen chat with a right-hand agents
pane. To be a reattach client for a session that has four studio panes, it needs
*some* notion of panes. Two honest options:

- **Share the model, not the renderer.** The canonical session state is the same
  layout tree for both clients. The studio renders a tree node as a GPU pane; the
  cTUI renders the *same* tree as either a split cell-grid (if wide enough) or a
  **pane switcher** -- one pane visible at a time, a tmux-`Ctrl-b n` gesture to
  cycle, the layout tree still intact underneath. The cTUI already clips runs to
  a column and already draws a divider for its agents pane (`blit`, `pane_width`);
  a two-pane cell split is the same arithmetic generalized. This is the pick:
  **one layout model, two renderers, the cTUI free to collapse the tree to a
  switcher when the terminal is too narrow to tile.**
- Reject: giving the cTUI its own independent split system. Two layout models
  that must stay in sync across reattach is the drift bug waiting to happen; the
  section-5 serializer must be the single source (`docs/studio-panels.md` already
  makes this point for one process -- reattach makes it non-negotiable).

So the cTUI gains: a layout tree it renders (tile when wide, switch when narrow),
and `TerminalView`'s parser reused headless (the parser is already specified as a
pure function of bytes, testable with no PTY -- `docs/studio-panels.md` section
3). The embedded terminal thus fits *both* front ends because its state is a cell
grid, and both front ends already draw cell grids (the cTUI via `tc`, the studio
via `renderer.draw_text`).

## 4. The agent angle: the distinctive win over plain tmux

Plain tmux detaches a *shell*. Boggart detaches a *swarm*. That is the whole
difference and it is worth stating sharply.

An agent already spawns and runs long tasks on the scheduler. Give it a
tmux-shaped host and this becomes possible:

- An agent **owns a pane**. Via the `workspace.*` drive surface already designed
  (`docs/studio-panels.md` section 6: `workspace.split`, `workspace.terminal`),
  an agent opens a terminal pane and runs a build, a test loop, a training run --
  a thing that takes an hour.
- The human **detaches**. Closes the laptop. The server keeps resuming the
  agent's actor on the one uv loop; the terminal's child keeps emitting; the
  parsed grid keeps updating server-side.
- The human **reattaches** from anywhere a client can reach the server -- a
  different machine, the cTUI instead of the studio -- and *watches the same
  pane* mid-run, scrollback intact, the agent still working.

This is the compounding thesis made physical (`docs/compounding.md`): the agent
does the long work; the human supervises intermittently rather than babysitting.
tmux gives a human that power over their own shells; boggart gives it over a
fleet of agents *and* the human, in the same session, through the same panes --
the `workspace.*` operations the agent drives are the same ones the human drives
(the studio-panels principle: "the agent operates the workspace through the same
operations the user does"). Detach/reattach is what makes "hand the agent a task
and walk away" a real workflow instead of a slogan, because walking away no
longer kills the work.

Attribution rides along for free: agents already carry a principal
(`docs/team.md`), so "which agent owns this pane" and "who typed into this
terminal" are facts the session records, not guesses. A shared session (team.md
M5) is then multi-human + multi-agent in one layout -- two people reattached to
the same swarm's panes -- which is past what tmux does at all.

## 5. Scope, phasing, and the hard problems

### v1 -- one line

**v1 is detachable/reattachable server-side sessions: agents + terminals + pane
layout live in `boggart serve`, a client (cTUI or studio) attaches over the
existing HTTP + SSE control plane, detaches by closing, and reattaches to live
work -- reusing `pty.c`, the section-5 layout serializer, and the project store,
with the terminal grid replayed from a server-side snapshot on reattach.**

### Phasing

Each phase ships alone; each is useful before the next.

1. **Session object, server-side.** Lift the scheduler + sessions the serve
   daemon already runs into a named, listable **session** the control plane
   exposes (`GET /sessions`, `POST /sessions/:id/attach`). No UI change yet; a
   session with no client is a session running headless. This is the load-bearing
   inversion (section 2).
2. **cTUI as a client.** `lua/tui.lua` gains a mode: instead of creating a
   coordinator in-process, attach to a server session, render its snapshot, send
   input over the wire, stream deltas over SSE. Detach = quit; reattach =
   `--attach <id>`. Ship this for the *chat* pane first (one transcript, no
   terminal panes) -- it proves the wire without the terminal-replay problem.
3. **Terminals server-side.** Move `pty.open` so the child is spawned in the
   *server*, its bytes parsed into the grid *server-side* (the `TerminalView`
   parser, run headless). The client renders the grid and sends keystrokes. This
   is what makes a terminal survive detach.
4. **Layout server-side + reattach snapshot.** The section-5 serializer becomes
   the wire representation of a session's layout; on attach the client pulls
   layout + each terminal's grid + each transcript, then streams deltas. Studio
   and cTUI both attach to the same object.
5. **The cTUI pane model** (section 3): tile-when-wide / switch-when-narrow, so a
   cTUI can reattach to a multi-pane session.
6. **Shared sessions** (team.md M5 falls out): two clients on one session id.

Deferred: named-session management sugar (rename, kill, `ls`), copy-mode/scroll
parity across clients, per-pane detach (detaching one pane while watching
another).

### The three hard problems

1. **A headless server holding UI + terminal state.** Today the studio and cTUI
   *are* the process that owns agents, PTY children, and layout; there is no
   place for that state to live with no UI attached.
   *Resolution:* the state was never really the UI's -- the agents and sessions
   already live in `bog.sched` and the store, which the serve daemon already
   runs. Only two things are born in the UI and must move: the **PTY child**
   (open it in the server, phase 3) and the **layout tree** (make the section-5
   serializer the server's own representation, phase 4). Once those move, "no
   client attached" is just a session whose event stream has no subscriber -- the
   loop keeps turning regardless, which is already how the scheduler behaves.

2. **Reattaching a GPU studio vs a terminal cTUI to the same session.** The two
   clients render with utterly different machinery (GPU quads vs `tc` cells) and
   different capabilities (a cTUI cannot tile four panes on 80 columns).
   *Resolution:* the canonical session state is **data, not pixels** -- the
   layout tree (section-5 serializer), the per-terminal cell grid, the
   per-agent transcript run-lines. Both clients already draw from exactly these
   (the studio from run-lines and `renderer`, the cTUI from run-lines and `tc`),
   so "render the session" is work each already does. The capability mismatch is
   handled at the client, not the model: the cTUI collapses the layout tree to a
   pane switcher when it cannot tile (section 3), the studio tiles it -- same
   tree, two presentations, no second source of truth.

3. **Terminal state replay on reattach.** A detached terminal's child kept
   running and kept emitting ANSI; a fresh client that attaches an hour later has
   no scrollback and cannot replay a megabyte of raw escape sequences from the
   start.
   *Resolution:* **never replay raw ANSI; replay the parsed grid.** Because the
   parser lives server-side (hard problem 1's resolution), the server always
   holds the *current* cell grid plus a bounded scrollback ring -- `TerminalView`
   already keeps exactly this, and the cTUI already has the snapshot primitive
   (`tc.snapshot` / `BOGGART_TUI_SNAP` writes the whole on-screen buffer). On
   attach the server ships that grid snapshot + the scrollback ring as the
   initial state, then streams live cell-delta events over SSE. State replay is
   O(screen), not O(history), and it is identical whichever client attaches.
   This is the concrete reason the parser must be server-side and not a client
   detail -- it is what makes reattach cheap and renderer-agnostic.

## 6. Non-goals

Real tmux does much that boggart will not.

- **No tmux command language.** No `tmux new-window`, `split-window`,
  `send-keys`, no `.tmux.conf`, no prefix-key grammar to reimplement. Panes are
  driven by the `workspace.*` surface and the client's own keys.
- **No tmux-compatible wire or control mode.** Boggart is not a drop-in tmux
  server; a real tmux client cannot attach to it, and boggart does not speak
  `tmux -CC`. The wire is boggart's own control plane (HTTP + SSE).
- **No driving an external tmux** as boggart's session model (section 1c). A
  terminal pane can of course *run* tmux like any other program; boggart the
  runtime does not put its session truth inside one.
- **No terminal multiplexer semantics inside one pane.** One child per
  `TerminalView` (`docs/studio-panels.md` non-goals stands). Want two shells,
  open two panes.
- **No new persistence tier.** A session is a live server object or a project
  row; there is no third "tmux resurrect" store. Live child state is not frozen
  to disk and thawed -- a detached session stays *running*; a closed session
  reopens as transcript + fresh shells (the resume-vs-reattach split, section 2).
- **The composer contract holds.** A user who runs `boggart --tui` and never
  detaches sees today's cTUI. Attach/detach is additive; single-process,
  single-client is still the default and still works with no server ceremony.
