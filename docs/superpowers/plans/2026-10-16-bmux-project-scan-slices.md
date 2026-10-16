# BMUX-108: cooperative initial project rebuild

Bounded benchmark-only resume attribution identifies `project_scan_thread`:
466–513 ms in one resume before terminal join begins. Preserve the original
BMUX-106 timing and this trace before changing product behavior.

Build a replacement graph/list privately, yielding after at most 128 traversal
operations or at a 2 ms checkpoint (checked every 32 operations). Publish the
complete sorted list and graph together; existing readers retain the old list
while scanning. A filesystem syscall or sort cannot itself be preempted.

Snapshot the list owner, current working directory and requested roots. After
each yield, discard the staged graph if any changed, then retry the latest
project. Leave old graph/watch ownership intact until commit. Initial/full
rebuilds use slices; existing small incremental directory refreshes retain their
current behavior. No periodic startup delay or reduced scan scope is introduced.

1. Add a deterministic native Studio scanner regression using 800 synthetic
   directory entries. Require yielding before publication, complete sorted
   multi-root output, root-change cancellation and owner-change cancellation.
   Run it before the product fix and preserve the failure.
2. Pass an optional staged context through directory read/build/flatten for full
   rebuilds. Keep watcher transition/publication atomic between yields.
3. Verify the scanner regression, native terminal/layout/Fleet behavior and full
   100-pane workflow normally and under ASAN. Track BMUX-107 failures explicitly.
4. Capture 20 matched uninstrumented real Metal startup trials before/after with
   source identities; do not infer comparison to cmux/Ghostty. Optional coroutine
   attribution remains bounded and labels its overhead separately.

Review added a full reconciliation pass after installing the new watches, so
files changed while the staged build yielded cannot be missed. That pass also
cancels on a changed list owner/CWD; the scanner remembers its committed CWD.
The regression covers an owner switch mid-reconciliation with newly added files.
This deliberately adds startup metadata I/O and temporary staging memory; only
interactive readiness is optimized here, not total indexing CPU/completion time.
