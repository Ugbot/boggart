# Checkpoint codec and shared-layout reconstruction

BMUX-95, macOS arm64, 2026-10-16. Normal and ASan/UBSan CLI/Studio builds passed.
No product-code edits followed the gates. `git diff --check` passed.

| Gate | Result | Local evidence |
| --- | --- | --- |
| Normal Bmux and joined Studio regressions | 15/15, 16.51 s | `build/bmux-checkpoint-verified.log` |
| ASan/UBSan same suites | 15/15, 22.74 s | `build-asan/bmux-checkpoint-verified.log` |
| Final codec/reconstruction boundary cases | 2/2 normal and 2/2 ASan/UBSan | `build/bmux-checkpoint-boundary-verified.log`, `build-asan/bmux-checkpoint-boundary-verified.log` |

`tests/fixtures/bmux_checkpoint.lua` builds an actual authoritative Host through
ordinary layout commands: two workspaces, multiple surfaces, an alias view of
one terminal, nested splits, mixed string/numeric agent IDs and a hidden zoom
tree. No executable processes are part of this fixture.

`tests/bmux_checkpoint.lua` checks copied/canonical round trips, empty arrays,
UTF-8 emoji/combining history, absolute POSIX/Windows directories and numeric
Boggart resume references. Its 44 rejection cases cover unsafe metadata fields,
credentials, control/escape text, invalid recipes, duplicate execution owners,
missing/generation-mismatched references, malformed arrays, table metatables,
and history/collection budgets. Additional cases cover oversized encoded
metadata, malformed/oversized raw JSON and the Lua decoder fallback: a full
supported depth-24 layout succeeds, while excessive JSON nesting is refused.

`tests/bmux_rehydrate.lua` restores the actual shared tree under a fresh host
with explicit reference mapping. It checks order, custom titles over resource
defaults, active tabs, selected workspace/surface, focus, split ratios, zoom,
alias references, stale old-host rejection and unique future command allocation.
Stricter limits and malformed snapshots fail before mapping. Failed/unavailable
remappers cannot mutate the original Host or publish a partial layout. An empty
checkpoint remains a usable Host. Reconstruction emits no initial change hook.

The broader regression includes actual native terminal Bmux and Studio
server-agent workflows; it protects existing consumers of the shared modules.
It does not prove SQLite saving or daemon relaunch: those integrations remain
BMUX-96/97, and BMUX-33 remains in progress.

```sh
ctest --test-dir build --output-on-failure -R '^(bmux_.*|studio_bmux_tree|studio_bmux_layout|studio_server_agents)$'
ctest --test-dir build-asan --output-on-failure -R '^(bmux_.*|studio_bmux_tree|studio_bmux_layout|studio_server_agents)$'
```
