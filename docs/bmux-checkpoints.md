# Bmux checkpoint data and layout reconstruction

The checkpoint codec and shared-layout reconstruction are implemented in
BMUX-95. SQLite journaling and automatic server startup restoration remain
BMUX-96; client import/recovery controls and relaunch acceptance remain BMUX-97.
BMUX-33 is not complete yet.

`bmux.checkpoint.validate(table)` copies and checks a v1 document containing
`layout`, `terminals` and `agents`. `decode(bytes)` uses the existing bounded
native JSON codec before validation; `encode(table)` validates and produces
canonical JSON with explicit empty arrays. Each returns data/bytes, or
`nil, {kind='checkpoint', message=...}` with a bounded diagnostic.

Native terminal records preserve their old ID/generation as mapping keys, an
absolute cwd, geometry/history capacity, optional informational program name,
plain history lines and a `shell`/`saved` recipe. Agent records preserve provider,
name, old identity/generation, optional terminal pair and numeric resume ID,
with a `boggart`/`saved` recipe. A Boggart recipe requires an owned terminal and
resume ID. An agent's terminal cannot also have a shell recipe. Layout aliases
can refer to one resource; dangling and duplicate-owner references fail.

The document is at most 4 MiB. History is at most 256 lines/64 KiB per terminal,
2 MiB overall, with valid UTF-8 and no C0/C1 controls or escapes. Metadata arrays
are bounded to 4096 terminals/1024 agents; the existing stricter layout limits
remain. The format carries no argv, environment, input queue, approvals or
attachment/controller credentials. Recipe enums do not confer execution trust.

`bmux.layout.restore(snapshot, options)` reconstructs a fresh authoritative Host.
It requires trusted `remap(old_view)` and `resolve(new_reference)` callbacks.
The remapper returns an ordinary terminal/agent descriptor without a view ID;
the existing command reference validator checks it. Original custom titles take
precedence over a resource's default title. Workspace/surface/tab order, active
tabs, pane focus, ratios and zoom survive under the new host identity.

Source snapshots and requested host limits are checked before any remapping.
Missing mappings or unavailable references fail without changing an existing
Host. The constructor never emits a change callback: the caller installs the
completed Host before publication. Normal later commands invoke `changed` and
allocate unique IDs. Old-host commands remain invalid. These operations start
no processes and perform no filesystem/store writes.

The future journal's trusted local startup path chooses whether to execute the
enum recipes. Imports must force all recipes to `saved`, including after future
saves/restarts. Informational program strings are never executed. See the
[restore design](superpowers/specs/2026-10-16-bmux-session-restore-design.md) and
[verification](benchmarks/2026-10-16-checkpoint-codec-verification.md).
