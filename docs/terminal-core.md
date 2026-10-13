# C terminal parser (BMUX-14)

`src/lvt.c` owns byte parsing, not a window, PTY, screen or Lua state. Its
`lvt_parser` contains all mutable storage for one stream; the transition table
is immutable. The module requires C99, calls no allocator and has no global
mutable state. `boggart_vt` is compiled with both front ends; consumers will
land with grid dispatch and PTY integration in BMUX-15/16/21. The studio still
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
