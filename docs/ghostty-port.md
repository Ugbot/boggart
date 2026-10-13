# Ghostty port ledger (BMUX-13)

The terminal core follows the BMUX roadmap's selected-module C port. Product
builds stay C99 and do not link Ghostty or require Zig. The existing CLI `term`
module in `src/lterm.c` remains the input/completion API; the VT parser starts
in `src/lvt.c` with its own C interface.

Upstream is [ghostty-org/ghostty at
05dcf887ef51ea27821f20979493306ec3a19149](https://github.com/ghostty-org/ghostty/tree/05dcf887ef51ea27821f20979493306ec3a19149).
This is a fixed source snapshot, not a floating `main` dependency. Its
`build.zig.zon` identifies 1.3.2-dev and Zig 0.16.0 minimum; Zig belongs only in
the optional differential oracle, whose build will need that pinned toolchain.

`THIRD_PARTY/ghostty-LICENSE` is the exact upstream MIT notice. The machine
ledger in `THIRD_PARTY/ghostty-port.json` records the source SHA-256 hashes,
review status and destination files. The parser mechanism and transition table
and page/style storage plus selected CSI/SGR dispatch and typed OSC are now ported.
OSC 8 cell/history ownership is implemented; live PTY integration remains BMUX-21.
“Studied” below means its interface and dependencies have been reviewed for
the port boundary; it is not a correctness or completeness claim.

| Upstream module | Status | BMUX work / adaptation |
| --- | --- | --- |
| `src/terminal/Parser.zig`, `parse_table.zig` | ported | BMUX-14; `src/lvt.c`, `src/lvt.h`, `src/vt_table.h`; 14-state parser, ordered entry/exit actions, 4 intermediates, 24 parameters, colon separators |
| `src/terminal/UTF8Decoder.zig` | studied | Streaming replacement behaviour verified; Boggart uses original scalar-range checks instead of copying third-party DFA tables |
| `src/terminal/osc.zig` and eight `osc/parsers/*.zig` modules in the manifest | ported | `src/bosc.c/h`, `src/bterm_osc.c`; bounded typed payloads, host events and notification chunks; screen-owned link references and copied URI snapshots complete BMUX-17 |
| `src/terminal/stream.zig`, `sgr.zig` | ported | BMUX-16; `src/bterm.c`, `src/bterm_dispatch.c`, `src/bterm_sgr.c`; selected CSI/ESC commands and SGR adapted to C grid operations/reply sink. OSC, key/mouse extensions and application parity remain separate gates |
| `src/terminal/PageList.zig`, `page.zig`, `Screen.zig`, `style.zig` | ported | BMUX-15/19; `src/lpage.c/h`, `src/lstyle.c/h`, `src/lgrapheme.c/h`, `src/bterm.c`, `src/bterm_internal.h`; portable 16-row pages, visible/history rings, style IDs/refcounts, wide-pair repair and bounded grapheme slots. Reflow and tracked positions remain BMUX-20 |
| `src/input/key_encode.zig`, `function_keys.zig`, `key.zig`, `key_mods.zig` | ported (selected interfaces/encoding) | `src/bkey.c/h`, `src/bterm.c`; normalized events, held/consumed/side modifiers, portable host policy, legacy and Kitty encoding. Foot legacy mapping notice retained separately |
| `src/input/kitty.zig` | studied | Its Foot-derived raw table is not copied; numeric functional ranges derive from the primary Kitty protocol |
| `src/terminal/kitty/key.zig`, `modes.zig` | ported (selected cases) | Fixed per-screen eight-entry flag rings, bounded negotiation/query and keyboard DEC mode defaults |
| `src/input/mouse_encode.zig` | ported | `src/bmouse.c/h`; normalized events/options, five formats and atomic writes; no renderer types |
| `src/termio/stream_handler.zig` | ported (selected cases) | Mouse-mode negotiation in `src/bterm_dispatch.c`; no message/PTY/app glue |
| `src/terminal/Terminal.zig` | ported (selected printer behavior) | `src/bterm.c`; previous-cell association, Unicode/legacy printing, width changes and wide wrap spacers. Fixed C geometry, own Unicode data, original style/link preserved on widening. Input-state interface and last-set mouse semantics also studied |
| `src/input/paste.zig` | ported | `src/bpaste.c/h`; binary transforms, bracketed framing, optional safety heuristic and atomic/overlapping buffers |
| `src/terminal/focus.zig` | ported | `src/bterm.c`; negotiated focus reports. Mode enable reports adapt the existing stream-handler path |
| `src/terminal/paste.zig`, `src/termio/Termio.zig` | studied | Paste/focus call boundaries only; no clipboard readers, Kitty OTP grants, app/backend or PTY glue copied |
| `src/unicode/grapheme.zig` | ported (width kernel) | BMUX-19; `src/bunicode.c/h` preserves valid emoji selector width changes, invalid-selector state restoration, and terminal cluster width effects. UAX #29 segmentation is independently implemented |
| `src/unicode/props.zig`, `props_table.zig` | studied | Boggart generates its own Unicode 16.0.0 properties from official data; no uucode source or generated table is copied |
| `src/renderer`, `src/font` | skipped for P1 | Study shaping, atlas and damage handling before BMUX-24/25; keep Boggart's renderer |
| `src/apprt`, `src/config`, `build.zig` | skipped | No platform app glue, config subsystem or Zig product build |

The page/storage sources depend on SIMD, OS allocations, compression, tracked
positions, and graphics state. Port the required storage semantics in bounded
pieces, not the entire dependency graph. The parser and storage must expose
damage rows for the renderer and stable snapshots for server attach.

## Port workflow

1. Start from the pinned upstream tree. Read the source, its tests and notices;
   validate it against the ledger hash. Keep upstream source out of the default
   product build. Any additional source must get a ledger entry before use.
2. Translate into a focused C99 module with explicit ownership and fixed parser
   storage on the byte path. Preserve semantic behaviour and document deviations.
   A port carries this header for **each** upstream file it derives from:

   ```c
   /* ported from ghostty@05dcf887ef51ea27821f20979493306ec3a19149 src/terminal/Parser.zig
    * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
    * SPDX-License-Identifier: MIT
    * See THIRD_PARTY/ghostty-LICENSE for the complete upstream notice.
    */
   ```

3. Mark the module `ported` and list every destination C/header file in the
   manifest. Keep the source hash. Mixed-origin files list every relevant marker.
   The translated portions retain MIT attribution; they are not relicensed as
   original Boggart code. Ship the third-party notice with source and binaries.
4. Bring across behavioural cases into meaningful C tests: table transitions,
   cancellation/restart, split UTF-8/CSI/OSC, bounded overflow, malformed streams,
   and entry/exit ordering. Run sanitizers and the same termbench corpus.
5. Use the pinned libghostty-vt oracle in development/CI to compare actions and
   grids. Application/conformance gates remain BMUX-23; “ported” in this ledger
   describes provenance and does not certify terminal parity.
6. Update the pin deliberately in a separate change: review upstream diffs,
   update hashes and notices, update every derivative header, then rerun
   differential tests, sanitizer tests and performance measurements.

Validate without network access:

```sh
python3 tools/check_ghostty_port.py
python3 tools/check_ghostty_port.py --upstream /path/to/pinned/ghostty
python3 tools/gen_vt_table.py /path/to/pinned/ghostty --check
```

The explicit `ghostty-oracle` CMake target builds the pinned public VT SDK in
a scratch directory, validates its native ABI schema, and checks the immutable
resize fixtures. It is a test tool with no product dependency. See
[terminal-resize.md](terminal-resize.md) for compiler prerequisites, source and
executable provenance, input coverage, and the native acceptance still pending.

The second command checks every hashed source file. The first checks the exact
licence hash and both directions of the source/destination attribution ledger.
The generator checks source hashes and enum ordering before translating every
transition declaration; `--check` verifies the generated table byte for byte.

## Nested notices and exclusions

Ghostty's `src/input/kitty.zig` identifies its functional-key table as derived
from Foot. Before translating that table, inspect Foot's notice and preserve
any required attribution; alternatively generate values from the Kitty protocol
specification. The Ghostty MIT notice alone is not a licence review for all
transitive dependencies. Unicode properties use uucode at the revision in
`build.zig.zon`; generated data needs its own recorded source/version/notice.

cmux source is excluded from this port. Implement its requested behaviour and
control verbs from public interface documentation. No copying of cmux app code
or platform glue is part of the BMUX plan.


The hyperlink storage adaptation in `src/llink.c/h` follows `Screen.zig`'s
cursor/cell ownership and implicit versus explicit IDs. Its indexed pool also
uses the translated style pool's refcount/hash/free-list machinery; both source
markers are recorded for `llink.c`. It frees strings on last release instead of
keeping zero-reference page entries until pruning, and owns pools per screen
rather than per page. This preserves links during row-pointer scrolling while
bounding strings by live cells/cursors. It does not copy the unlisted
`hyperlink.zig` implementation or import Ghostty's page-memory dependency graph.


Mouse input now ports `src/input/mouse_encode.zig` to `bmouse.c/h`, replacing
renderer coordinate dependencies with normalized integer terminal pixels and
atomic output/deduplication updates. `src/termio/stream_handler.zig` supplies only
mouse-mode/format negotiation in `bterm_dispatch.c`; its application message and
PTY glue are excluded. `src/terminal/Terminal.zig` is studied for the input-state
contract, with its pinned hash recorded; no terminal application glue is copied.
See [terminal-core.md](terminal-core.md) for bounds and deliberate adaptations.
Keyboard encoding now ports selected interfaces from `key.zig`/`key_mods.zig`
and the behavior in `key_encode.zig`/`function_keys.zig`. The latter cites Foot;
`THIRD_PARTY/foot-LICENSE` preserves its MIT notice, with hashes/derivative headers
verified by the ledger checker. Kitty functional numbers come from the primary
protocol and the raw `kitty.zig` table remains studied. `kitty/key.zig` supplies
bounded per-screen stack behavior; `modes.zig` supplies selected DEC options and
defaults. No platform app, key binding, configuration or IME glue is copied.

Paste encoding ports the transform and heuristic in `input/paste.zig` to
`bpaste.c/h`, with capacity validation before mutation and support for overlapping
caller-owned buffers. `terminal/focus.zig` supplies the three-byte focus reports
in `bterm.c`. The studied higher-level paste/termio files provide boundary
context, not application/clipboard/PTY implementations. Boggart's host focus
survives RIS rather than returning to the pinned reset's default focus flag;
the view owns that state. See [terminal-core.md](terminal-core.md).
