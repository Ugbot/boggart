# Shared Bmux layout

BMUX-31 requires workspace → surface → split tree → pane, shared by Studio and
the cTUI. The server ultimately owns session layout; terminal processes remain
independent of layout. This carries forward `docs/tmux.md`'s one-model/two-
renderers decision. The cTUI may present the same tree as a pane switcher when
it cannot tile it. That presentation must not destroy the underlying tree.

First replace Studio's structural Node implementation with `bmux.tree`, a pure
Lua model. Its nodes are the actual RootView nodes, not a second tree projected
from mutable UI state. An adapter supplies empty views, global focus, asynchronous
close admission and divider/leaf presentation. UI drawing, tabs, docks and
pixel hit testing stay in RootView. Existing native PTYs/images are unaffected.

Alternatives considered: copying RootView into a separate cTUI tree would
duplicate layout policy; snapshotting a pure tree beside RootView would create
two owners. Sharing the actual structural nodes gives both clients the same
operations while allowing unrelated renderers. The model contains opaque view
values; server/cTUI adapters can use plain descriptors instead of Studio views.

The interface provides a node class with split/close/find/leaves, directional
focus, divider resize, balance, zoom/unzoom, view movement and pane-content swap.
Split/collapse retain existing view identity and stable leaf IDs. A close callback
removes the originally requested view even if focus or position changes before
admission. Last-pane closure leaves an empty pane; structural edits while zoomed
restore the hidden layout first. Tiny geometry must not yield negative sizes.

Workspace/surface containers and actual cTUI use follow this production Studio
extraction. The model will then be used by the server layout owner and attachment
protocol; no client may become a second authority for server-owned layouts.
Persistence/restore remains BMUX-33, cTUI terminal attachment BMUX-35, and network
drive operations have their existing tracker scope. Do not close BMUX-31 on the
tree extraction alone.

Acceptance includes pure descriptor tests for all structural operations and
edge cases, then existing Studio mode/tab/split/zoom/dock/agent/attached-terminal
regressions in normal and sanitizer builds. Tests must traverse the same model
interface used in production. Later cTUI/server tests must prove those adapters
consume the shared hierarchy, not merely import its module.
