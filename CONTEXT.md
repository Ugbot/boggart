# Boggart Bmux layout language

These terms describe terminal-session layout. A filesystem workspace used for
agent isolation is a different concept from a Bmux workspace.

## Language

**Bmux workspace**:
A named group of surfaces belonging to a running Bmux session.
_Avoid_: filesystem workspace, git worktree

**Surface**:
A selectable layout within a Bmux workspace, containing a pane tree.
_Avoid_: terminal process, operating-system window

**Pane**:
A leaf of a surface's split tree, holding one or more selectable views.
_Avoid_: terminal process, agent

**View**:
Content selected within a pane, such as a terminal, agent conversation or file.
_Avoid_: pane, surface

**Terminal**:
A running or completed shell/program session with its own terminal state and
history, which can be observed through more than one view.
_Avoid_: pane, client connection

**Zoom**:
A presentation that temporarily shows one pane while preserving its neighbours.
_Avoid_: closing panes, deleting the hidden layout
