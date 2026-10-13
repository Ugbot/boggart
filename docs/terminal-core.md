# C terminal core (BMUX-14/15/16)

`src/lvt.c` owns byte parsing, not a window, PTY, screen or Lua state. Its
`lvt_parser` contains all mutable storage for one stream; the transition table
is immutable. The module requires C99, calls no allocator and has no global
mutable state. `boggart_vt` is compiled with both front ends; its `bterm`
consumer connects parser events directly to C grid dispatch. Both front ends
expose it through `require("terminal")`; live PTY integration is pending. The studio still
uses its Lua parser until that integration is verified.

```c
lvt_parser parser;
lvt_init(&parser);
lvt_feed(&parser, bytes, length, consume_event, context);
/* Repeat feed for each PTY read, without resetting the parser. */
lvt_finish(&parser, consume_event, context); /* Only at process EOF. */
```

`lvt_feed` decodes UTF-8 in the ground state and takes an ASCII fast path. It
preserves partial scalars across reads, replaces malformed sequences, and
reprocesses rejected continuation bytes so an ESC/control byte cannot be lost.
Wide-cell widths and grapheme clustering belong to the grid/Unicode work.
String payloads in DCS/OSC/APC remain raw bytes; UTF-8 continuation bytes there
must not become C1 controls. The raw `lvt_next` API exposes the pinned parser
mechanism, including its C1 transition table, for state-machine tests.

Events arrive in exit, transition, entry order. They borrow buffers until the
next byte; consume/copy them synchronously, and never re-enter the same parser
from its callback. CSI/DCS events carry parameter arrays, intermediate bytes,
the final byte and a colon-separator mask. Numeric parameters saturate at
65535. Bounds match the pinned parser: four intermediates and 24 parameters;
excess parameters suppress dispatch. Cancellation/restart and DCS/APC lifetime
events are preserved.

OSC events carry up to 4096 raw payload bytes. Overflow drops the entire
command; CAN/SUB cancel it. This deliberately separates the mechanism from
typed OSC handling (BMUX-17). The callback must not treat an OSC event as proof
that a command is valid. Title, cwd, hyperlinks, notifications and shell marks
need their own validation and dispatch. Grid semantics and Ghostty differential
conformance remain BMUX-16/23 gates.

Verification:

```sh
ctest --test-dir build -R '^vt_parser$' --output-on-failure
python3 tools/check_ghostty_port.py
python3 tools/gen_vt_table.py /path/to/pinned/ghostty --check
```

The C suite traverses all 3584 state/byte combinations, checks cancellation and
restart from every state, high bytes in DCS, ordered events, CSI styles and
overflow, split UTF-8 including EOF, malformed recovery, bounded OSCs and
independent instances. A million deterministic adversarial bytes run through
the parser for sanitizer coverage. ASan/UBSan and TSan are supported by the
existing `BOGGART_SANITIZER` build option and apply to both the parser library
and its test executable. This suite verifies the parser mechanism; it does not
claim that vim or a multiplexer renders correctly yet.

## Page and style storage (BMUX-15)

`src/lpage.c` stores fixed-geometry screens in contiguous allocations of 16
rows. Visible rows and bounded history use pointer rings; full-screen upward
scroll rotates visible pointers and, once history fills, recycles its oldest
row. Region scrolling moves only pointers within that region. History pointer
capacity grows lazily to its configured limit. Clearing history releases cell
styles and frees empty pages. `lpage_usage` reports owned capacity bytes, not
process RSS or allocator overhead. Geometry is limited to 1–4096 rows/columns;
resize/reflow belongs to BMUX-20.

Cells preserve codepoint, style ID, hyperlink ID and width/flags; wide-cell
pair integrity and grapheme storage remain BMUX-19. Rows expose wrapped and
damage state. `lpage_ack_damage` acknowledges visible damage after a renderer
consumes it; scrolling conservatively damages the whole visible screen.
Borrowed rows/cells can move or recycle on any mutation, so renderers must not
retain their pointers across terminal updates.

`src/lstyle.c` interns default, indexed and RGB colours plus attributes in a
screen-owned hash table. Acquiring a style owns one reference; each cell owns
its own reference, including cells in history. Cell edits transfer references
with their cells. Last release removes the hash entry and reuses its ID.
Default ID 0 is permanent. Retain an ID while holding it outside a cell; it
cannot be shared between screens, and a borrowed style value can be invalidated
by the next pool mutation.

```sh
ctest --test-dir build -R '^page_storage$' --output-on-failure
```

The storage suite checks style deduplication and reuse, history eviction,
stable owned bytes after history fills, cell insert/delete reference transfer,
region scrolling and damage. It compares 30,000 mixed operations against a
simple shifting reference screen with exact cell, wrap, history and reference
counts, including multiple page allocations, ring growth and history clearing.
The test and library use the existing sanitizer build option.
Lua/PTY consumers remain subsequent work; this storage API does not establish
terminal compatibility by itself.

## Headless dispatch (BMUX-16, application gate pending)

`src/bterm.h` exposes a terminal with one owner thread, fixed geometry, a
primary screen with history, a lazily allocated alternate screen without
history, and an optional synchronous reply sink. `bterm_feed` keeps parser
state across reads; `bterm_finish` flushes incomplete UTF-8 at EOF. The callback
must copy or consume replies immediately and must not re-enter the terminal.
An allocation or reply failure makes feed/finish return false until reset;
earlier mutations are retained. Reset clears both screens, history, saved
cursors, modes and parser state while retaining geometry and the reply sink.

`bterm_state` copies cursor position, delayed wrap, margins, pen, cursor shape
and supported mode bits. Screen/style accessors borrow data until mutation;
acknowledge damage through `bterm_ack_damage`. No Lua calls or renderer/PTY
dependencies exist on the byte path.

Dispatch includes cursor movement/position, tab stops, erase, insert/delete
cells and lines, scrolling, top/bottom margins, saved cursors, alternate
screen modes 47/1047/1048/1049 and primary/secondary DA plus DSR/CPR replies.
Origin, autowrap, cursor visibility, insert/newline, application cursor/keypad,
focus, bracketed paste and reverse-video modes are represented. Focus/paste
and keyboard encoding consumers follow in BMUX-18/21. Reply bytes reach the
provided sink; writing them to an actual PTY is BMUX-21 work.

SGR preserves indexed colours and supports semicolon and colon RGB forms,
optional colon colour-space fields, underline colour/styles, and standard
attributes/reset codes. Components truncate to eight bits as in the pinned
source. Malformed colon groups are ignored as a unit, a deliberate stricter
boundary than interpreting leftover subparameters as separate attributes.
Erase/insert/scroll blanks use the current background colour and default
attributes.

```sh
ctest --test-dir build -R '^terminal_dispatch$' --output-on-failure
```

Tests assert grids, wrapped rows, margin clipping, history isolation, repeated
alt-screen sets, cursor/style restoration, background erasure, exact reply
bytes and failed-sink recovery. Whole feeds and chunks of 1–17 bytes produce
identical grids/state/replies; 131,072 deterministic adversarial bytes also
match whole versus one-byte feeds and release styles on reset. The standalone
suite is included in sanitizer builds.

Cells currently hold one scalar with width 1: grapheme/wide-cell behaviour is
BMUX-19, and geometry/reflow is BMUX-20. Character-set designation, soft reset,
selective erasure, mouse modes, DCS/APC extensions and live PTY
consumers are not yet implemented. The pinned Ghostty differential suite is
BMUX-23. Keep BMUX-16 open until vim, htop, less and tmux rendering is verified
through the integrated terminal; these C tests do not satisfy that app gate.

## Lua terminal object

`src/lterminal.c` is registered as `terminal` in both front ends and worker
states. It owns the C terminal through userdata; `close`, `__gc` and Lua's
to-be-closed scope cleanup release it. All operations on a closed object fail
except repeated close. The CLI's existing `term` completion API remains separate.

```lua
local terminal = require "terminal"
local t <close> = terminal.new(80, 24, 2000) -- columns, rows, history limit
t:feed(bytes)                              -- entire read goes straight to C
for _, y in ipairs(t:damage()) do
  local row = t:row(y)                      -- copy only the rows needed
  -- render row.cells and row.wrapped
end
t:ack_damage()                             -- after consuming the rows
local reply_bytes = t:replies()             -- consume queued DA/DSR replies
```

Rows and cursor/margin coordinates are one-based in Lua. Each copied cell has
`codepoint`, `width`, `flags`, `hyperlink` and a copied `style` with tagged
`fg`, `bg`, `underline` colours and `attrs`. Blank codepoint is zero. The module
exports colour tags and commonly consumed mode bits. `state()` copies cursor,
margins, modes, alternate/pending-wrap state, cursor style and pen.

`snapshot()` copies the active screen, state and diagnostic parser fields;
`snapshot(true)` includes active scrollback. `row(index, true)` copies history
oldest first. Snapshots/rows stay independent after later feeds. Raw pending
intermediate/OSC bytes use numeric arrays so snapshots remain JSON-compatible
even during invalid UTF-8 or NUL-containing strings. Snapshot and damage queries
do not acknowledge damage or drain replies. Full persisted session/attach state
is subsequent server work.

`replies()` returns and drains the bounded 64 KiB reply queue. Overflow raises
a Lua error and leaves the core failed; `reset()` clears queued replies and
recovers it. Feed/finish/reset throw on failure, and successful mutation calls
return no values. `finish()` belongs at EOF, never at a read boundary.

`usage()` reports active screen capacity bytes, pages, row capacity, history
rows, live styles and queued reply bytes/capacity. Its screen byte count is not
whole-terminal RSS or Lua allocation accounting. C grid allocations belong to
the native core; snapshots and the userdata belong to Lua. `source()` returns
the 16 source/header hashes embedded during CMake configuration. Changes to
those files trigger regeneration; the native benchmark compares them with the
checkout and rejects a stale executable.

`tests/terminal.lua` covers copies, coordinates, colour tags, pending UTF-8/OSC,
damage, alt-screen isolation, reply draining/overflow/reset, invalid inputs,
explicit/scope close and garbage collection. `tools/fingerprint.lua` verifies
the same API, grid snapshot and reply bytes in CLI and studio. Live shells and
removing the Lua parser from studio's data path remain BMUX-21.


## Typed OSC events (BMUX-17 increment)

`src/bosc.c/h` parses OSC 0/2 (title), 7 (cwd file URI), 8 (hyperlink),
9/99/777 (notification), 133 (shell marks/status) and 52 (clipboard). It borrows
bounded input/scratch, validates UTF-8 and controls, requires explicit URI
schemes and valid percent escapes, and strictly decodes padded/unpadded base64.
Unsupported ConEmu OSC 9 commands produce no notifications. These are typed
metadata; parsing never executes, opens, fetches or changes a directory.

The C `bterm_set_event_sink` callback receives borrowed typed data plus zero-based
cursor coordinates and alternate-screen identity synchronously. It must copy
before returning and never re-enter the terminal. BEL also emits a typed event.
Without a sink these events are discarded. Clipboard policy defaults to denied;
`bterm_clipboard_policy` sets independent read/write permissions which survive
reset/RIS. `bterm_clipboard_reply` validates permitted text and sends base64 with
the request's BEL/ST ending through the ordinary reply sink. Native clipboard
access belongs to the future host permission provider, not this core.

Kitty OSC 99 title/body chunks assemble by ID in eight lazily allocated slots.
Each assembly holds at most 4096 text bytes and 256 ID bytes. Overflow discards
that ID through its completion; close cancels its assembly. If more than eight
incomplete IDs arrive, further unknown IDs are discarded until reset, so tails
of discarded chunks cannot become misleading complete notifications. Existing
assemblies can finish. Allocation pressure never fails normal grid output.
Urgency persists across chunks unless explicitly replaced. Close/query requests
are emitted as data; no notification extension or GUI action is advertised.

The Lua object copies events into a lazily allocated queue of at most 256 records
and 64 KiB payload bytes. `events()` returns the copied array plus the overflow
count and drains both; `usage()` exposes queue bounds/occupancy/loss. Overflow
preserves earlier events and continues parsing/rendering. Reset clears queues;
close/GC frees them. Lua event coordinates are one-based. Notifications include
`id`, `title`, `body`, `urgency`, `action`; shell marks include `mark`, optional
`status` and raw `options`; links include `id`/`uri`; clipboard requests include
`selection`, `query`, `text`, `bel` and policy generation.

```lua
local t <close> = require("terminal").new(80, 24, 2000)
t:clipboard_policy(false, false) -- host choice; shell bytes cannot change it
t:feed(bytes)
local count, dropped = require("terminal.events").drain(t, trusted_pane_id)
```

`terminal.events.drain` publishes JSON data on `terminal.title`, `.cwd`,
`.hyperlink`, `.notification`, `.shell`, `.clipboard` and `.bell` through the
existing bus. The caller supplies the trusted pane identity. Draining happens
before any subscribers run, avoiding Lua re-entry from byte parsing. Revocation
invalidates queued clipboard requests even if permission is later restored;
the bridge checks policy generation again before every clipboard publication,
since an earlier subscriber may revoke it. Deferred consumers must recheck host
permission before applying a clipboard side effect. `clipboard_policy()` with
no arguments reads policy/generation; `clipboard_reply(selection, bel, text)`
returns false for denied/invalid responses. No OS clipboard integration is
claimed by these APIs.

OSC 8 currently emits validated link metadata, but cells still store no owned
link URI. Link interning, cell/history ownership and URI snapshots remain the
next BMUX-17 increment; the story stays in progress until those are verified.
`tests/c/osc.c`, `tests/c/terminal_events.c` and `tests/terminal.lua` cover payload
validation, ordering, fragmentation, interleaving, bounds, policy/revocation,
reply encoding, queue lifetime and actual bus subscriber delivery. CLI/studio
parity also fingerprints drained typed events.
