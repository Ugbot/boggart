# Bmux checkpoint codec and layout reconstruction

BMUX-95, inline continuation of the session-restore design. C/Lua only; reuse
native JSON, snapshot validation and the shared structural tree. No new runtime.

**Goal:** validate a bounded data-only checkpoint and reconstruct a fresh shared
layout with explicit trusted reference mapping before SQLite/runtime integration.

**Files/interfaces:**

- `lua/bmux/checkpoint.lua`: `validate(table)`, `decode(bytes)`, `encode(table)`
  return copied data/bytes or `nil, {kind='checkpoint', message=...}`.
- `lua/bmux/layout.lua`: `restore(snapshot, options)` constructs a new Host or
  returns an error; options include existing `resolve`, `limits`, `changed` and
  an explicit `remap(old_view)` callback returning a reference without an ID.
- `lua/bmux/rehydrate.lua`: staging implementation using the actual Host/Tree.
- `lua/bmux/layoutcommands.lua`: share `reference(host, descriptor)` validation.
- `tests/bmux_checkpoint.lua`, `tests/bmux_rehydrate.lua`, CMake registration.

- [ ] Define copied checkpoint records and cross-reference validation; reject
  recipes with argv/env/tokens, unsafe history text and missing/mismatched refs.
  Tests include a repeated native reference, mixed agent ID types, valid emoji,
  absolute POSIX/Windows cwd, stopped/manual data and Boggart resume recipes.
- [ ] Verify JSON/object/array and all text/collection bounds; round trips must
  retain empty-array wire forms and never expose mutable caller tables.
  Oversized/deep/malformed documents return bounded errors without side effects.
- [ ] Reconstruct staged workspace/surface/pane/view objects, preserving each
  order/selection/focus/zoom and ratio while generating a fresh host identity.
  Tests use a real command-built source tree and mutate the restored Host with
  ordinary commands; stale old-host commands fail and future IDs stay unique.
- [ ] Reject malformed input/stricter limits before remapping. Failed remappers
  return errors without mutating the original Host or firing publication hooks.
  Share the existing descriptor validator rather than adding another schema.
- [ ] Build normal and ASan/UBSan targets. Run the checkpoint/rehydrate tests plus
  `bmux_tree`, `bmux_layout`, `bmux_snapshot`, `bmux_layout_server`, actual joined
  Studio and native Fleet workflows. Record evidence, commit and push.

Representative checks:

```lua
local c,why=require('bmux.checkpoint').decode(raw)
assert(c,why and why.message)
local restored,why=require('bmux.layout').restore(c.layout,{
  resolve=function(v)return owned_terminals[v.terminal_id]~=nil end,
  remap=function(v)return {kind='terminal',terminal_id=bindings[v.terminal_id],generation=1,title=v.title}end,
})
assert(restored,why and why.message)
assert(restored.host_id~=c.layout.host_id)
```

The test fixture supplies real defined bindings and owns no executable effects.
BMUX-96/97 remain required for the complete persistence/restore feature.
