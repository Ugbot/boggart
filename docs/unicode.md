# Shared Unicode data (BMUX-19)

`src/bunicode.c/h` provides scalar widths, streaming extended grapheme boundaries,
and terminal grapheme widths. The immutable property table is compiled once into
`boggart_unicode`; lookup and segmentation allocate no memory. The table has
122 unique 256-scalar pages and occupies 71,168 bytes.

CLI, Studio, termctl and the terminal backend share this library through CMake.
`src/utf8width.h` retains compatibility names without embedding another table;
`tc_wcwidth` delegates to the same lookup. Terminal build identity includes the
kernel, interface, generated table and cell grapheme pool (29 compiled source/header hashes).

The version is deliberately Unicode **16.0.0**, matching the existing Boggart
width table. `THIRD_PARTY/unicode/manifest.json` records the official source URL
and SHA-256 for every input and conformance fixture. `THIRD_PARTY/unicode-LICENSE`
contains Unicode License V3. Git attributes preserve these exact bytes on Windows.
The generator reads vendored inputs, verifies hashes and reconstructs the
compressed table for every code point before emitting it. Compile-only builds
need neither Python, network access, nor Zig.

```sh
python3 tools/genwidth.py           # regenerate src/bunicode_data.h offline
python3 tools/genwidth.py --check   # verify hashes and reproducible output
python3 tests/genwidth_test.py      # malformed ranges, missing inputs, hash drift
ctest --test-dir build -R '^unicode$' --output-on-failure
```

The native test reads all 1,093 official GraphemeBreakTest cases and checks 2,774
boundaries. It also checks the width of every scalar, invalid values, emoji
selectors/modifiers/flags/ZWJ sequences, Hangul, Indic conjuncts, controls, and
10,000 regional indicators without state overflow. The normal and ASan/UBSan
tests passed. A migration comparison across all 1,114,112 code points found no
width differences from the old shared table.

`bunicode_grapheme_break` implements Unicode 16 UAX #29 GB3–GB13, including InCB
consonant/linker prefixes, extended-pictographic Extend/ZWJ prefixes, and RI parity.
Zero-initialize its state and pass each scalar exactly once; it reports the
boundary before the scalar. A logical end of text is always a boundary. Invalid
scalars force boundaries and occupy one replacement cell. Standard segmentation
does not discard variation selectors.

The separate terminal width-effect kernel ports selected behavior from the pinned
Ghostty `src/unicode/grapheme.zig`: valid VS16/VS15 request two/one cells; invalid
selectors are consumed but ignored and preserve the prior break state and scalar.
Other nonzero contributions request two cells. Boggart generates the contribution
flag from scalar-zero width, Mc, and the Extend/ZWJ/SpacingMark/V/T break classes.
The scalar policy uses Mn/Me/Cf (except U+00AD), medial/final Jamo and controls as
zero; EAW W/F and default emoji presentation as two; ambiguous characters as one.
This is an explicit Boggart policy, not an assertion that the pinned uucode data
or every Ghostty width matches. An oracle must align Unicode versions and policy
before claiming parity. No uucode source or tables are copied.

`bunicode_grapheme_width` measures the first complete cluster in a scalar slice
and returns its consumed scalar count. It supports unbounded cluster length
without storing the text. A streaming terminal still needs cell ownership for
that text. Native grid wide-pair repair and bounded grapheme storage are now
implemented and used by the native printer and copied Lua snapshots. Mode 2027
defaults on; its legacy mode retains scalar printing and zero-width attachment.
Resize/reflow is BMUX-20. Renderer and string measurement
must switch to cluster units together so text layout agrees with painting.

The shared UTF-8 decoder accepts an explicit end pointer or a NUL-terminated
string. It rejects overlong encodings, surrogates, values beyond U+10FFFF and
truncated sequences, returning U+FFFD with one byte of progress per bad byte.
Explicitly sized strings preserve embedded NUL scalars. This intentionally
replaces the previous decoder's partial-codepoint/opaque-byte fallback.
Scalar string widths saturate at INT_MAX, prefix arithmetic cannot overflow,
and Lua column budgets clamp before conversion to C int. Existing `sys.width`
and `sys.wtake` continue to measure scalar units, matching the current Studio
renderer. A ZWJ emoji still measures four cells there; the explicit grapheme API
measures two. The renderer, native cells and consumers must migrate together.

Initial Unicode integration verification: full serial CTest passed 116/116 (110.93 s); focused normal and ASan/UBSan tests passed 18/18; CLI/Studio parity passed with 31 identical fields, including width and prefix vectors. Generator reproducibility, malformed-input checks and pinned Ghostty attribution passed. BMUX-19 remains in progress for printer and renderer integration.

Page ownership integration verification: full serial CTest passed 118/118 (111.43 s), focused normal and ASan/UBSan checks passed 20/20, CLI/Studio parity passed with 31 identical fields, and pinned attribution passed for 40 modules / 26 ported files. Tests exercise copy-on-write, the 64-suffix cap, exact refs after 30,000 mutations and steady memory through history recycling. This checkpoint preceded native printing and copied cluster text.

Native printer and copied-text integration verification: full serial CTest
passed 120/120 (113.95 s); focused normal checks passed 21/21 before the final
REP boundary correction, which the full suite covers; final ASan/UBSan checks
passed 21/21 (15.59 s). CLI/Studio parity passed with 32 identical fields.
Generator reproducibility and four validation tests passed; attribution passed
for 40 modules / 26 ported files; strict C99 warning and diff checks passed.
The original GC-close snapshot probe failed under ASan before the immutable
image change and passed afterward. Compiled identity remains 29 files.
BMUX-19 remains in progress for renderer/measurement agreement.
