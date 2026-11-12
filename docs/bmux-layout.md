# Shared Bmux pane tree

`lua/bmux/tree.lua` owns structural pane operations. Studio's RootView nodes are
instances of this model, with UI methods added to the adapter class. There is
no second mutable pane tree alongside RootView. This completes the structural
extraction in BMUX-78. The server hierarchy and revisioned API are documented
in [server-owned layout](bmux-layout-host.md). Studio's actual
[Join layout](bmux-studio-layout.md) consumes that hierarchy. The cTUI consumer
remains required by BMUX-31/BMUX-35.

## Model and adapter

`Tree.class(options)` returns a callable node class. Calling it creates a leaf
unless `hsplit` or `vsplit` is supplied. Views are opaque Lua values. A leaf
contains `views` and `active_view`; a split contains `a`, `b` and a `divider`.
Every node has `id`, `position` and `size`. IDs are unique within that class's
lifetime, not persistent or globally unique terminal identities. A split keeps
the original leaf ID on its original content; a collapse promotes the sibling
ID with its contents. Callers resolve IDs again after structural edits rather
than retaining a removed node object.

Optional adapter callbacks:

| Callback | Purpose |
| --- | --- |
| `empty()`, `is_empty(view)` | Create and replace a presentation placeholder |
| `focused()`, `focus(view)` | Query host focus and activate an existing view |
| `close(view, done)` | Admit closing the originally requested view, asynchronously if needed |
| `after_close()` | Clear host bookkeeping after an admitted removal |
| `divider` | Number or function returning the current divider width |
| `locked_size(view)` | Return a locked leaf's desired width and height |
| `arrange_leaf(node)` | Apply computed bounds to a renderer's leaf presentation |

Without a focus callback the class tracks selection itself. A supplied
`focused()` returning nil is authoritative. Without a close callback, removal
is immediate. The model never spawns, kills or detaches terminal processes.
Studio supplies EmptyView, platform focus, `try_close`, animated dock metrics
and the tab-strip body offset. Composite dock bounds and split geometry remain
shared model operations.

## Operations and invariants

- `split(direction, view?, locked?)` preserves the existing leaf and creates a
  sibling. Locked leaves can subdivide into locked docks, preserving focus.
- `close_view(view, root)` or `close_active_view(root)` captures the requested view; admission resolves its
  current location even after movement. Repeated admission callbacks are
  harmless. Background closure preserves the currently focused view. Last
  closure retains an empty pane and never consumes a locked sibling.
- `move_view(view, destination, root, index?)` moves tabs between panes or
  reorders them in one pane. `swap_views(destination)` exchanges pane contents
  and follows the moved selection. View and terminal identities are unchanged.
- `get_leaves`, `get_children`, `get_node_for_view`, `find_node` and
  `get_parent_node` traverse the current presentation tree. `get_content_root`
  stops at locked docks, including composite docks.
- `get_node_in_direction` uses current geometry. `set_divider`, `resize_by`,
  `balance` and `update_layout` share resize policy. Tiny bounds clamp child
  sizes and divider rectangles to nonnegative space.
- `toggle_zoom` preserves the original tree in `zoomed`; `unzoom` restores it.
  A structural split, move or close restores hidden neighbours first. Zoom
  snapshots do not create or focus temporary placeholder views. Traversals
  describe visible panes while zoomed; callers needing the full tree must
  unzoom or explicitly inspect the saved tree.

Studio keeps drawing, tab hit testing and input dispatch in
`studio/data/core/rootview.lua`. Tab movement, directional focus, pane swaps
and divider dragging call the shared operations. Bmux mode-switch snapshots
continue to preserve its content tree; they are not durable session storage.

See the [layout design](superpowers/specs/2026-10-15-bmux-shared-layout-design.md),
[implementation plan](superpowers/plans/2026-10-15-bmux-shared-layout.md) and
[verification](benchmarks/2026-10-15-shared-tree-verification.md).
