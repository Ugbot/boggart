# Bmux checkpoints and session restore

Delivery: BMUX-95/96 implement the codec, reconstruction and SQLite runtime
journal; BMUX-98/99 implement native transfer and Studio/cTUI session controls;
BMUX-100 adds [explicit archive recovery](../../bmux-recovery.md). Actual
clean/crash restart, inactive imports across recovery/resave/restart, ownership
conflicts and both frontend flows are verified. Hard native allocation limits
block whole restoration and retain the saved document, rather than publishing a
partial layout; recovery can archive it before saving the current owned state.

BMUX-33 continues the approved server-owned hierarchy and native agent design.
Persist layout, working directories, best-effort history and agent resume IDs
in the existing SQLite store. A restarted server gets a fresh host identity and
new execution objects. A process survives client detach, not daemon exit.

## Document and execution boundary

Use one versioned checkpoint document, validated and copied before effects:

```lua
{
  v=1, layout=layout_snapshot,
  terminals={
    {id='old-terminal', generation=1, cwd='/work', cols=80, rows=24,
     history=2000, launch='shell', program='/bin/zsh', lines={'previous output'}}
  },
  agents={
    {id='old-agent', generation=1, provider='boggart', name='Boggart TUI',
     terminal_id='old-agent-terminal', terminal_generation=1,
     launch='boggart', resume_id=123}
  }
}
```

This example's agent terminal must have a corresponding terminal record with
`launch='saved'`; a resource has one execution owner. Checkpoints contain no
argv, environment, controller/attachment tokens, approval requests, queued
commands or replay receipts. `program` is informational and never executable.

`terminal.launch` is `shell` or `saved`; `agent.launch` is `boggart` or `saved`.
Only a Boggart provider with a numeric positive resume ID can carry the latter
automatic recipe. A terminal owned by an agent cannot separately restart a
shell. Foreign/custom programs remain inactive previews until explicitly
launched. Agent records without native terminals may retain informational
references, but cannot carry an automatic recipe.

The document itself grants no execution authority. The trusted local journal
may reopen default shells and local Boggart CLI sessions using those enum
recipes. It never executes `program` or imported command strings. Import forces
all recipes to `saved` before application, and subsequent captures preserve that
inactive state. Merely saving or restarting an import cannot promote its trust.
An explicit user launch creates a new ordinary owned runtime.

## Bounds and validation

- Entire encoded document: 4 MiB, using the existing bounded native JSON decoder.
- Layout: existing v1 limits (16 workspaces, 64 surfaces, 256 panes, 512 views,
  32 tabs/pane, depth 24), selections and zoom validated as a whole.
- At most 4096 terminal metadata records and 1024 agent records. Unique IDs;
  native terminal references match exact generations. Every layout reference
  resolves in the document; repeated views may reference one resource.
- Geometry 1–4096, history capacity 0–100000. A cwd is an absolute UTF-8 path,
  at most 4096 bytes. The runtime still enforces its own allocation budget.
- At most 256 plain lines and 64 KiB of text per terminal; 2 MiB across the
  checkpoint. Lines contain valid UTF-8 and no C0/C1 controls or terminal escapes.
  History capture truncates to these budgets rather than growing indefinitely.
- Unknown metadata fields, dangling references, duplicate execution ownership,
  invalid recipes, sparse arrays and malformed UTF-8 are rejected. Validators
  return copied records and bounded diagnostic errors, never partial images.

The data codec has no process, filesystem or store effects. Invalid imported
data cannot reach a runtime remapper or change an active layout.

## Shared layout reconstruction

`bmux.layout.restore(snapshot, options)` constructs a new authoritative Host.
It validates the source first, applies the requested host limits before calling
the trusted `options.remap(old_view)` reference lookup, validates every returned
descriptor through the existing layout-command reference validator, then
publishes a complete tree. `options.resolve` checks the remapped references.
Neither callback belongs to the external document. The constructor does not
start/stop processes or edit an existing Host.

Generated workspace/surface/view IDs and pane nodes belong to the fresh Host;
the old host identity is never reused. Tab/surface/workspace order, titles,
selected tabs, focused panes, split ratios and zoom survive reconstruction.
Unavailable mappings are explicit failures. The new host starts at revision 1
and retains ordinary validated commands and collision-free future allocation.

## Runtime journal and client follow-through

BMUX-96 integrates the codec with existing SQLite KV storage. A named server
session scopes the checkpoint; ordinary private-socket servers derive a default
name from their stable socket address. Embedded/test control servers opt in.
Coalesced dirty notifications capture layout/runtime changes and a final flush
precedes shutdown releasing PTYs. Failed/corrupt checkpoints leave the last
good saved data intact and produce an observable recovery error.

Capture uses native parser text without interpreting it as commands. Cwd follows
validated local shell directory metadata where available, otherwise its launch
directory. Runtime restoration allocates one new native owner per resource and
maps all views/agent references to it. Boggart resumes its existing saved session
in an idle TUI; it does not replay a previous tool action. Missing directories,
unavailable sessions or exhausted budgets remain visible inactive entries.

BMUX-97 supplies named-session/export/import controls and actual daemon relaunch
verification through Studio and terminal clients. Until both runtime integration
and those checks pass, BMUX-33 remains incomplete. Existing client disconnect
and reconnect semantics retain their current owners and pinned host rules.

Alternatives: persisting raw terminal input or shell argv could replay effects
and cannot satisfy safe imports. Serializing renderer objects or process IDs
would preserve invalid ownership. A separate database/runtime would duplicate
the C/Lua store and native execution owners. A copied data document plus trusted
enum recipes reuses the existing modules and makes the launch boundary explicit.
