# boggart-studio -- panels, splits and terminals

**Status: design, drafted 2026-09-05.** A spec, not an implementation. It builds
on the layout code that already ships (`studio/data/core/rootview.lua`,
`studio/data/core/commands/root.lua`, `studio/data/shell/`) and names the real
API rather than inventing one.

## Context

boggart-studio is a lite-xl fork. lite-xl already has the hard part of a
multi-pane workspace: a `Node`/`RootView` split tree, tabbed leaves, dockable
locked panels, and drag-resize. The studio shell (`shell/init.lua`) sits on top
with a menu bar, three full-screen workspaces (AGENT / EDIT / FLEET), and a
neovim spine (`shell/modal.lua`) that already binds `Ctrl-w h/j/k/l/s/v/q`.

So "neovim on steroids" is mostly a matter of finishing and exposing what is
there, plus one genuinely new capability -- an embedded terminal backed by a
PTY -- and one new principle: **the agent drives the same workspace the user
does, through the same operations.** A pane the user can open, the agent can
open; a terminal the user can type in, the agent can run a command in.

## 1. Scope and vision

A pane is a rectangle holding one view, with a tab strip when it holds more than
one. Panes tile a window through arbitrary horizontal and vertical splits. Every
split is resizable and every pane is closable. Any view class can live in any
pane: editor (`DocView`), markdown preview (`MarkdownView`), agent chat
(`AgentView`), swarm roster (`SwarmView`), an agent-authored panel
(`PanelView`), and the new `TerminalView`.

In scope:

- Arbitrary nested splits, tabs per pane group, drag- and keyboard-resize.
- Keyboard-driven pane navigation, split, move and close (vim `Ctrl-w`).
- A real embedded terminal (PTY-backed), phased.
- Saved and restored layouts, per project.
- An agent control surface over every one of the above.

Out of scope: floating/overlapping windows, detached OS windows, a full tmux
protocol, remote panes, a plugin marketplace. See section 8.

## 2. Layout model

### What already exists

`rootview.lua` is the layout engine. Read it as the source of truth; this is a
description of it.

- A **`Node`** is either a `leaf` or a split (`hsplit` = side by side,
  `vsplit` = stacked). A leaf owns `views` (its tabs) and one `active_view`. A
  split owns two children `a` and `b` and a `divider` ratio in `[0.01, 0.99]`.
- **`Node:split(dir, view, locked)`** turns a leaf into a split. `dir` is one of
  `up down left right`; `type_map` sends `up/down` to a `vsplit` and
  `left/right` to an `hsplit`, swapping `a`/`b` for `up`/`left` so direction
  reads naturally. The old leaf's content moves into one child; `view` (if any)
  goes in the other.
- **`Node:close_active_view(root)`** closes the active tab, and when a leaf's
  last tab closes it collapses the split -- the sibling is consumed into the
  parent. A locked sibling is never swallowed.
- **`RootView:open_doc(doc)`** opens or focuses a document in the primary node,
  choosing `MarkdownView` for `.md` and `DocView` otherwise (`view_class_for`).
- Layout is recomputed every frame by `Node:update_layout`; `divider`, tab-strip
  height, and locked sizes drive it.

**Docks are locked leaves.** `shell.attach` docks the menu bar with
`primary():split("up", menubar, true)` and the recents rail with
`split("left", rail, true)`. `core.init` docks the command line and status bar
below. A locked leaf takes its size from its view via `get_locked_size()` /
`set_target_size(axis, value)`, not from the split ratio, which is why panels
resize by their own rule and content panes resize by the divider.

**The pane commands already exist** in `commands/root.lua`, guarded to no-op on
a locked node: `root:split-{left,right,up,down}`, `root:switch-to-{dir}`,
`root:switch-to-{next,previous}-tab`, `root:switch-to-tab-N`,
`root:move-tab-{left,right}`, `root:shrink`, `root:grow`, `root:close`. The vim
spine maps `Ctrl-w h/j/k/l` to the switch commands, `s`/`v` to split, `q`/`c` to
close (`shell/modal.lua` `WIN`). `root:switch-to-{dir}` navigates spatially: it
probes the point just past the current node's edge and focuses whatever leaf is
there.

### What this spec adds

The model is sound. The work is filling gaps, not replacing it.

- **`root:split-*` accepts a target view.** Today split then re-opens the same
  doc (`commands/root.lua`). Generalise so a split can be opened directly onto a
  chosen view class -- the agent surface (section 6) and "open terminal in a
  split" both need this. A thin `RootView:open_view_in(dir, view)` on top of
  `Node:split`.
- **Pane movement, not just tab movement.** `root:move-tab-*` reorders tabs
  within a leaf. Add `root:move-pane-{dir}` that detaches the active view and
  re-splits it into the neighbour, the nvim `Ctrl-w H/J/K/L` gesture.
- **Equalise and zoom.** `root:balance` resets dividers under a subtree to
  `0.5`; `root:zoom` toggles a remembered layout against a single maximised pane
  (nvim `Ctrl-w =` and a `Ctrl-w o` analogue that hides rather than closes).
- **Coexistence with docks is already correct.** Sidebar and agent dock are
  locked leaves the split walk skips (`each_content_leaf` in `shell/init.lua`
  already filters `not node.locked`). Splits happen inside the content block; a
  dock is never split into and never navigated onto (`root:switch-to-*` checks
  `get_locked_size()`). Nothing here changes that contract.

### The workspace-switch geometry gap

`shell.switch` flattens all content leaves into one tab strip on an AGENT /
EDIT / FLEET switch and logs "geometry not yet preserved"
(`collapse_content_leaves`). For per-pane-group layouts to survive a workspace
switch, stash the content subtree's **shape**, not just its views. This is
"option A" the code comments already describe, and it shares its serializer with
persistence (section 5). Do it once, use it twice.

## 3. Embedded terminal

### Feasibility, honestly

Feasible, and a good fit for the runtime. The C layer already links libuv
(`luv_loop`) and already spawns children with `uv_spawn`
(`studio/src/api/system.c`, `system.exec`). The scheduler already pumps the loop
every frame with `uv.run("nowait")` (`core/init.lua`, `run_threads`), and the
codebase's model is "everything is a libuv handle" (memory:
async-event-loop-model). A PTY master fd is just one more handle on that loop.

One thing that exists is easy to mistake for the answer and is not.
`src/termctl.c` (`docs/cli-plan.md` B0) is boggart's own full-screen terminal
**control** layer: raw mode, alternate screen, a double-buffered cell grid, and
ANSI **emission**, driving the real tty for `boggart --tui`. It points the wrong
way for an embedded terminal. An embedded terminal is a **host**: it spawns a
child on a PTY and **parses** the child's ANSI into a grid it draws itself.
termctl emits ANSI to a terminal; TerminalView consumes ANSI from a child.
Reuse its ideas -- `tc_wcwidth` for display width, its cell-grid layout, its
knowledge of which sequences matter -- not its code path.

The studio GPU renderer is the other half and it is ready: `renderer.draw_text`
and `renderer.draw_rect` (`studio/src/api/renderer.c`), a monospace
`style.code_font`, and the same per-view `push_clip_rect` every other view uses.
A terminal is a grid of monospace cells; drawing it is drawing runs of cells
with those two calls.

### Pieces

1. **PTY host (new C).** Add `openpty`/`forkpty` (or `posix_openpt` +
   `grantpt`/`unlockpt`) behind a small Lua surface, e.g. `sys.pty.open{cmd,
   args, env, cwd, cols, rows}` returning a handle. Wrap the master fd in a
   `uv_pipe_t` (via `uv_pipe_open(fd)`) or a `uv_poll_t` so reads wake the loop.
   Child exit arrives through the same `uv_spawn` exit path
   `system.exec` already uses. This is the only mandatory new C.
2. **ANSI/VT parser (new Lua).** A state machine consuming child bytes into a
   cell grid: CSI/SGR (colour and attributes), cursor addressing, erase,
   scroll regions, `\r \n \b \t`, and UTF-8 decode with wide-char width. Keep it
   a pure function of bytes so it is testable headless with no PTY.
3. **`TerminalView` (new Lua, `core/terminalview.lua`).** A `View` subclass
   holding the grid, drawing visible rows with `code_font`, a block cursor, and
   a scrollback ring. `get_name()` returns the command or `"terminal"`. It is an
   ordinary view: it lives in any pane, tabs, splits, and closes like the rest.
4. **Input routing.** When focused and in raw mode the view encodes keystrokes
   to PTY bytes (arrows to `\e[A` etc, `Ctrl-C` to `0x03`) and writes the master
   fd. See section 4 for how the modal spine yields to it.
5. **Resize.** On layout change, compute `cols`/`rows` from pixel size and
   `code_font` metrics, `ioctl(TIOCSWINSZ)` the master, which raises `SIGWINCH`
   in the child. Debounce to the settle cadence, not every frame.

### v1 versus deferred

v1 (a usable shell that runs `git`, `ls`, `make`, and the boggart CLI):

- One child on one PTY per view; spawn, read, write, resize, reap.
- SGR: 8/16 colours, bold, underline, reverse, mapped to theme colours.
- Cursor addressing, line/screen erase, scroll region, autowrap.
- UTF-8 with wide-char cells; a fixed scrollback ring.
- Keyboard input, block cursor, focus follows the pane.

Deferred, called out so v1 is honest about what breaks:

- Full 256-colour and truecolor (v1 approximates to the theme's 16).
- Alternate-screen apps (vim, htop, tmux). v1 may render them wrong or refuse
  the private-mode switch. This is the line most worth drawing early.
- Mouse reporting, bracketed paste, sixel/images, reflow on width change
  (v1 re-lays-out but does not rewrap history).

## 4. Focus and input model

One focused pane at a time -- `core.active_view`, unchanged. Keys route through
the existing chain: `keymap.on_key_pressed`, wrapped first by the modal spine
(`shell/modal.lua` `intercept`), then the view.

The spine already gates itself on **`typing()`**: it never claims a stroke while
the focused surface is taking typed text, asking each view a uniform
`is_text_input()` (`DocView` via vim, `AgentView` via `edit_mode`, the command
line always). `TerminalView` joins that contract:

```lua
-- A terminal in raw mode is taking every key; the spine must not eat Ctrl-w.
function TerminalView:is_text_input()
  return self.raw_mode  -- child put the tty in raw mode
end
```

This is the crux. In raw mode the terminal owns `Ctrl-w`, `j`, `k`, `Ctrl-d`,
everything -- exactly as the composer does -- so the child program, not the pane
navigator, sees them. To leave a raw terminal by keyboard the user needs a
prefix the spine still sees; reserve one escape stroke (proposal: `Ctrl-w`
routed to the spine only after a leading `Ctrl-\`, or a fixed `Ctrl-w w` grab
window) and document it. A cooked-mode terminal (a plain prompt reading a line)
can let the spine keep `Ctrl-w` since the shell is not in raw mode.

The vim layer over editors is unchanged (`core/vim.lua`); it already answers
`is_text_input()` false in normal mode, which is why `Ctrl-w` navigation works
over a `DocView` today and will work identically next to a terminal.

## 5. Persistence

A layout is the content subtree's shape plus each pane's contents. Persist it
**per project**, because the project is the unit of context (`docs/projects.md`,
`lua/project.lua`): projects are named, own roots, and already round-trip
through the store (`bog.store.project_put` / `project_get`). A layout is one
more field on the project.

Serialize the subtree the workspace-switch code already needs to stash
(section 2):

```lua
-- Recursive, mirrors the Node tree. Docks are excluded; they re-attach on load.
{ type = "hsplit", divider = 0.5,
  a = { type = "leaf", active = 1, tabs = {
          { view = "doc", path = "src/main.c" },
          { view = "terminal", cmd = "zsh", cwd = "." } } },
  b = { type = "leaf", active = 1, tabs = {
          { view = "agent" } } } }
```

Rules:

- Save on layout change (debounced) and on quit; load on project switch and
  launch, after docks attach.
- A `doc` pane restores by `RootView:open_doc`; a missing file degrades to an
  empty pane with a note, never an error.
- A `terminal` pane restores as a **fresh** shell in the saved `cwd`. Terminal
  scrollback and live child state are not persisted -- a restart is a restart.
- `agent`/`swarm`/`panel` panes restore to their single live instance
  (`studio.view`, the swarm surface, the named panel file).
- One serializer, three callers: quit-save, per-project layouts, and
  workspace-switch geometry. They must not drift.

`global` is a project too, so a user who never names a project still gets their
layout back.

## 6. Driving it with the agent

**Principle: the agent operates the workspace through the same operations the
user does.** Not a parallel path -- the same `root:*` commands, the same
`open_doc`, the same `sys.pty`. Anything the agent can arrange, a person could
have arranged by hand, and vice versa. Two directions:

### Results land in panes (pull)

The agent already produces pane-shaped output; route it into the layout instead
of only inline in the chat.

- **A file the agent opens or edits** opens a `DocView`/`MarkdownView` via
  `RootView:open_doc`, landing in the primary content node (the same call the
  file tree uses). `AgentView` already renders `write`/`edit` results as inline
  diffs (`core.diff`, patience); "open it in a pane" is opening the target doc
  beside the chat and, optionally, scrolling to the hunk.
- **A shell/`bash` tool result** surfaces in a `TerminalView`. `AgentView`
  already runs `!cmd` and captures output through `take.run_bash` with the
  `("proc", handle)` scheduler protocol; a long-running or interactive command
  is handed to a PTY-backed terminal pane instead of captured inline.
- **A diff review** opens a diff pane; a plan or report opens a `MarkdownView`.

### The agent arranges the workspace (drive)

Expose the pane operations as agent-callable actions so the agent can compose a
layout for a task, the way it composes a plan. Thin wrappers over what section 2
defines, so there is nothing new to keep correct:

- `workspace.split(dir, view_spec)` -- split and open a view (editor, markdown,
  terminal, agent, panel) in the new pane.
- `workspace.open(view_spec)` / `workspace.focus(selector)` /
  `workspace.close()` -- open, focus, close panes.
- `workspace.terminal(cmd, {cwd, split})` -- open a terminal and run a command,
  reading its output back (the drive-side of the bash tool).
- `workspace.layout.save(name)` / `workspace.layout.load(name)` -- name and
  recall a layout (section 5), so the agent can set up "reviewing" versus
  "debugging" arrangements and switch between them.
- `workspace.workspace(name)` -- switch AGENT / EDIT / FLEET
  (`shell.switch`).

These are the existing `root:*` commands and `RootView` methods with an
argument surface, registered like every other tool. Guard them with the same
approval gate spawned agents already honour (`shell/agent/approval`), so
"the agent rearranged my panes" is a reviewable action, not a surprise. The
result: a user can hand the agent a task and watch it open the file on the left,
a terminal running the test on the lower right, and the diff in the middle --
then take the keyboard and drive the same panes itself.

## 7. Build order

Each phase ships on its own.

1. **Finish splits.** `open_view_in`, `move-pane-*`, `balance`, `zoom`; confirm
   `Ctrl-w` fidelity. Pure Lua over the existing tree.
2. **Preserve split geometry across workspace switch.** Write the subtree
   serializer (`shell.switch` stops flattening). Unlocks phase 5.
3. **Terminal v1.** PTY host in C (`sys.pty`), the ANSI parser, `TerminalView`,
   input, resize. The one phase with new C; ship it behind a flag.
4. **Layout persistence.** Reuse the phase-2 serializer; save/load per project.
5. **Agent pull.** Route file opens, diffs, and shell results into panes.
6. **Agent drive.** The `workspace.*` action surface behind the approval gate.
7. **Terminal polish.** Alt-screen and full-colour, promoting real editors and
   `htop`/`tmux` from "deferred" to "works".

## 8. Non-goals

- **No full tmux/screen.** No tmux control protocol, no session server, no
  detach/reattach. Panes are studio panes.
- **No remote panes.** A terminal is a local child on a local PTY. Remote work
  is SSH inside a local terminal, not a studio feature.
- **No floating or OS windows.** The tree tiles; panes do not overlap and do not
  detach into separate OS windows.
- **No terminal multiplexer semantics inside a pane.** One child per terminal
  view. Want two shells, open two panes.
- **No plugin marketplace.** View classes are code in the tree, not installable
  third-party packages.
- **The composer contract holds.** "Type a message and press Enter" never
  breaks (`docs/tui-vim.md`). A user who never splits a pane or opens a terminal
  sees today's studio.
