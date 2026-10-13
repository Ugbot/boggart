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
styles/links and frees empty pages. `lpage_usage` reports owned capacity bytes, not
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
BMUX-19, and geometry/reflow is BMUX-20. A shared generated Unicode 16.0.0
kernel now supplies scalar widths and streaming grapheme boundaries; see
[unicode.md](unicode.md). Cell integration remains pending. Character-set designation, soft reset,
selective erasure, DCS/APC extensions and live PTY
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
rows, live styles/links, link capacity bytes and queued reply bytes/capacity. Its screen byte count is not
whole-terminal RSS or Lua allocation accounting. C grid allocations belong to
the native core; snapshots and the userdata belong to Lua. `source()` returns
the 24 source/header hashes embedded during CMake configuration. Changes to
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

OSC 8 also changes the active cursor's link. `src/llink.c/h` owns copied key/URI
strings in a pool per screen. An explicit ID interns the (ID, URI) pair; each
open without an ID creates a distinct identity, even for the same URI. One
cursor reference keeps its link alive; printed cells independently retain it.
Closing the link releases only the cursor reference. Insertion/deletion and
scrolling transfer references with cells; overwrite, erasure, history eviction
and reset release them. At zero references strings are freed immediately and
numeric slots are reused, so memory does not grow with past OSC 8 activity.
Tables retain capacity for the maximum concurrent links seen on that screen.

Alternate-screen transitions and cursor restore end the active link without
changing previously printed cells. Repeated mode sets which do not switch
screens keep the active link. Reset/RIS clears links in both screens/history.
Malformed OSC 8 is ignored and preserves current state. Cells continue to expose
screen-local numeric `hyperlink` IDs; Lua rows/snapshots additionally copy
`link = {id = explicit_id_or_empty_string, uri = uri}` for linked cells. These
copies survive eviction and ID reuse. Consumers must not hold numeric IDs across
mutations without owning a reference. C accessors `bterm_link` / `lpage_link`
borrow the active screen's value; rendering follows BMUX-24/25, and opening a
URI remains a separate host decision.

`usage().links` counts live links in the active screen, including its cursor.
`link_bytes` counts its pool metadata capacity and live string bytes, included
in `screen_bytes`; neither is total process RSS. The link pool bounds source
keys at 256 bytes and URIs at 4096, with parser validation at the OSC boundary.
`lpage_put` retains its own style/link references and leaves the caller's
acquired reference owned by the caller. It rejects dead link IDs and rolls back
its retained style without changing the old cell. `tests/c/links.c` verifies pool identity/copies/growth,
10,000 cycles of unique-link history eviction with stable capacity, insert/delete,
wraps, alternate-screen separation, reset and invalid-ID rejection. The storage
reference model now checks link reference counts across 30,000 operations.
`tests/c/osc.c`, `tests/c/terminal_events.c` and `tests/terminal.lua` cover payload
validation, ordering, fragmentation, interleaving, bounds, policy/revocation,
reply encoding, queue lifetime and actual bus subscriber delivery. CLI/studio
parity also fingerprints drained typed events.


## Native mouse input (BMUX-18 increment)

`src/bmouse.c/h` translates the pinned mouse encoder into allocation-free C99.
It accepts a normalized action/button/modifier event, explicit reporting options
and optional motion state, and returns complete encoded bytes. Its 64-byte
maximum covers X10, UTF-8, SGR, urxvt and signed SGR pixels. Cells are clamped to
visible geometry and encoded one-based; pixels follow the pinned encoder's
signed terminal coordinate convention without clamping or adding one. The host
subtracts pane origin/padding and applies scaling before calling. Hosts with
fractional positions should floor for cell formats and round for pixel format
before passing integer pixels; renderer-specific transforms stay outside C.

Event policies are none/X10/normal/button/any. X10 reports only presses of buttons
1–3 and omits modifiers; normal reports press/release; button tracking requires
a button for motion; any reports all valid events. Buttons 4–7 encode wheel
up/down/left/right and 8–9 encode extras. Legacy releases use button code 3;
SGR releases preserve button identity. Shift/Alt/Ctrl add modifier bits. Outside
press/motion needs a motion-capable mode and a held button; releases always
report when the policy permits them. Cell motion suppresses repeated cells,
while pixel motion keeps every event. Last-cell state updates only after emitted
bytes, including successful press/release reports. Failed capacity checks leave
output and motion state unchanged, unlike a partially written protocol report.

Geometry is 1–4096 rows/columns with 1–65535 pixels per cell. Positions use signed
32-bit normalized pixels. Invalid enum/button/modifier values or zero/oversized
geometry return false; valid suppressed events return true with zero bytes.
Buttons 0 are valid only for motion. No encoding call allocates or calls Lua,
PTY, renderer or bus code.

The native dispatcher negotiates DEC modes 9/1000/1002/1003 and formats
1005/1006/1015/1016. This is last-set state, as in the pinned stream handler:
enabling replaces the event/format, and resetting any corresponding mode disables
reporting or resets its format to X10. RIS/reset disables reporting. Screen
transitions preserve negotiated mouse modes and clear motion deduplication;
repeating the existing screen mode leaves it alone. Cell-size changes invalidate
the cached cell without changing state on a failed encoding call. C callers use
`bterm_input_state` and `bterm_mouse`; these are separate from automatic DA/DSR
reply emission and do not put mouse bytes in the reply queue.

```lua
local terminal = require "terminal"
local t <close> = terminal.new(80, 24, 2000)
t:feed(shell_output)
local modes = t:input_state() -- mouse_mode / mouse_format names
local bytes = t:mouse { action = "press", button = 1, x = 19, y = 39,
  cell_width = 10, cell_height = 20, modifiers = terminal.SHIFT }
-- Host sends bytes to the PTY; empty means the event was suppressed.
```

`mouse` accepts raw fields of one event table; it does not run `__index` getters.
Action defaults to press; button defaults to zero (therefore required for press/
release), position and modifiers default to zero, and cell dimensions default
to one. `any_button_pressed` is an optional boolean; by default a button-bearing
press/motion implies held state. Explicit false supports out-of-viewport events
where no button is held. Modifiers use exported `SHIFT`, `ALT` and `CTRL` bits.
Invalid Lua events raise an error without failing the parser. Coordinates and
cell sizes must be integer values. `input_state()` is a copied input-mode view;
full persisted attach/restore state remains server-model work.

`tests/c/mouse.c` verifies exact byte vectors, every format, wheel/extras,
modifiers, coordinate boundaries, atomic capacity failure, motion policies and
100,000 adversarial normalized events. `tests/c/terminal_mouse.c` verifies the
parser-to-encoder path across 1–17-byte chunks, reset/RIS, screen transitions,
cell-size changes and failed writes. Lua tests cover strict validation,
raw-field reads, dimensions, motion and separation from replies; parity checks
encode mouse bytes and input state in both front ends.

## Native keyboard input (BMUX-18 increment)

`src/bkey.c/h` translates the pinned keyboard encoder and legacy function-key
behavior into normalized C99 events. It supports press/repeat/release, application
cursor/keypad modes, DEC backarrow/NumLock handling, modifyOtherKeys mode 2,
legacy C0/fixterms and all five Kitty flags. Functional keys cover the pinned
Ghostty set (F1–F25, navigation, keypad, locks and left/right modifiers). Their
Kitty numeric ranges derive from the [primary protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/#functional-key-definitions);
`kitty.zig` remains studied. The Foot-based legacy mappings retain Daniel
Eklöf's copyright and the full `THIRD_PARTY/foot-LICENSE` notice, whose hash and
derivative headers are checked alongside the Ghostty ledger.

Physical printable keys use `key="text"` plus explicit `base_layout` and
`unshifted` Unicode scalars. The host supplies the physical PC-layout character
and the unshifted character in the active layout separately; text contains the
actual UTF-8 produced by the event. Modifiers are held-state bits after the
event, with separate consumed modifiers and right-side bits. Consumed modifiers
affect text-bearing binding decisions, while Kitty reports the original held
state. Lock bits are excluded from legacy bindings. Shift/Alt/Ctrl/Super match
the pinned behavior; Hyper/Meta additionally encode their primary Kitty bits.
The host supplies post-event modifier state, including releases with the other
side still held; the encoder does not infer the OS's key state.

Text is valid UTF-8, at most 4096 bytes per event. Unshifted/base scalars must be
valid Unicode (zero means absent). Unlike the pinned writer's invalid-UTF-8
fallbacks, invalid input is rejected before any bytes are written. A sizing pass
and an emission pass produce atomic output without allocation, including at
insufficient capacity. Associated text skips C0/DEL as in the pinned encoder,
and also excludes C1 controls as required by the primary protocol. The maximum
output bound is `BKEY_CAPACITY` (32864 bytes); output must not alias input.

Composing/preedit events are suppressed, except Kitty modifier events in
all-key mode. IME confirmation on Enter sends committed text directly and
Backspace with preedit text emits nothing, preserving the pinned behavior.
An unidentified pure text event also retains the pinned direct-text fallback,
even with Kitty flags set. The host must submit each committed text event once;
text delivery and physical key callbacks need coordinated routing in Studio.

```lua
local terminal = require "terminal"
local t <close> = terminal.new(80, 24)
t:feed(child_output)
local bytes = t:key { key = "text", action = "press", text = "A",
  unshifted = 97, base_layout = 97, modifiers = terminal.SHIFT,
  consumed_modifiers = terminal.SHIFT }
-- Host writes bytes once to the child PTY.
```

`key` reads raw fields and validates action/key names, scalars, UTF-8, modifiers,
sizes and booleans. Action defaults to press, key to text, and absent fields to
zero/empty/false. `option_as_alt` is `none` (default), `all`, `left` or `right`.
On macOS the side and policy govern Option text translation, Alt prefixes and
associated text. Elsewhere Alt always represents a modifier. C callers can
explicitly select macOS behavior for portable tests using `bterm_key_options`
or `bterm_key`. Input output remains separate from automatic terminal replies.

Native DEC modes 1/66/67/1035/1036 and ESC keypad mode select keyboard options;
1035/1036 default on. CSI `>4;2m` enables modifyOtherKeys mode 2 and `>4m` or
`>4;0/1m` disables it. Each screen owns a fixed eight-entry Kitty flag ring:
CSI `>flags u` pushes, `<number u` pops, `=flags;mode u` replaces/sets/clears
bits, and `?u` emits `?flags u` through the reply sink. Missing push flags mean
zero, missing pop count means one, explicit zero count does nothing. As in the
pinned stack, large pops clear the ring and overflowing pushes evict old state.
Unknown flags/modes, colon parameters and excess parameters leave state alone.
The main and alternate screen stacks remain independent and RIS clears both.
`input_state()` now also copies `kitty_flags`, `backarrow`, `ignore_keypad_numlock`,
`alt_prefix` and `modify_other_keys_2`; application modes remain in `state().modes`.

`tests/c/key.c` covers exact legacy/application/Kitty sequences, C0 ambiguity,
non-Latin and Unicode input, modifier sides, IME, capacity atomicity and UTF-8
bounds, plus every functional-key/flag/modifier combination. Native tests cover
query replies, bounded stack overflow/pop, invalid negotiations, alternate
screens, RIS and 1–17-byte chunks. Lua tests cover the full negotiated path,
raw fields and validation; parity also fingerprints encoded keyboard bytes.

## Native paste and focus (BMUX-18 increment)

`src/bpaste.c/h` ports the pinned `src/input/paste.zig` transformation. It replaces
NUL, BS, ENQ, EOT, ESC, DEL and the pinned terminal-control byte set with spaces.
Other bytes are preserved, including UTF-8 text and tabs. Mode 2004 frames the
result with CSI `200~` / `201~` and preserves newlines. Without that mode, LF
becomes CR, so CRLF becomes CRCR as in the pinned implementation. The C encoder
accepts binary input, allocates nothing, checks size overflow and output capacity
before writing, and permits overlapping buffers through `memmove`. The maximum
added frame size is 12 bytes. Low-level `bpaste_encode` frames even empty data;
the terminal wrapper suppresses an empty paste, matching the higher-level paste
request's behavior. Invalid input/capacity leaves output unchanged and length zero.

```lua
local bytes = t:paste(clipboard_text) -- host sends the returned bytes once
local heuristic = t:paste_safe(clipboard_text) -- optional policy input
local focus_bytes = t:focus(false) -- false = lost, true = gained
```

`paste` accepts a string of at most 32 MiB, independently of the 4096-byte keyboard
event bound. Lua allocates a buffer and copies its encoded result to a string;
the core never owns or modifies the original Lua string. The binding rechecks
the live terminal after allocation, which can run finalizers. `paste_safe` is
the pinned, mode-aware heuristic: LF is flagged in unbracketed mode, and the
7-bit bracket terminator is flagged in either mode. It is separate from encoding
and does not authorize PTY writes or introduce an approval flow. This port
provides the encoder; clipboard readers, MIME selection, Kitty paste-event OTP
grants and higher-level host policy are not imported from `terminal/paste.zig`.

Mode 1004 enables [focus reports](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-FocusIn-FocusOut):
`focus(true)` returns CSI `I`, `focus(false)` returns CSI `O`, and disabled
reporting returns an empty string. Successful calls record host focus even when
reporting is off; insufficient C output capacity changes neither focus nor bytes.
The method accepts actual host transitions and does not infer or deduplicate
them. Enabling 1004 sends the current focus through the automatic reply sink,
as the pinned stream handler does, including repeated enables. Explicit focus
calls return bytes separately from that sink. New terminals start focused;
the embedder should set the actual pane/window state when attaching a view.

Focus belongs to the host view, so Boggart preserves it across RIS while
disabling focus reporting and bracketed paste. This deliberately differs from
the pinned full reset's default focus flag: a child's reset must not turn an
unfocused pane into a focused one. Mouse/input negotiation and keyboard stacks
still reset as documented above. Paste/focus modes remain global across screen
switches. `input_state()` additionally copies `focused`, `focus_reporting` and
`bracketed_paste`.

`tests/c/paste.c` verifies exact framing/newline/Unicode vectors, all byte values,
overlap, size overflow, every insufficient frame capacity and the optional
heuristic. Native tests verify mode enable replies, actual focus events, atomic
capacity failure, alternate screens, reset and 1–17-byte stream chunks. Lua tests
cover binary replacement, large pastes, strict validation and closed objects.
CLI/studio parity fingerprints paste output and focus output/replies.

Studio key/mouse/paste/focus routing remains BMUX-18 work. The studio still has
its fixed key table and old parser; native resize/reflow and the libuv PTY path
must replace that path before negotiated input can become authoritative without
duplicating parsing or grid ownership. These native APIs do not claim live
Studio input integration.
