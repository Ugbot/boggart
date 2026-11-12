# Shared Unicode data (BMUX-19)

`src/bunicode.c/h` provides scalar widths, streaming extended grapheme boundaries,
and terminal grapheme widths. The immutable property table is compiled once into
`boggart_unicode`; lookup and segmentation allocate no memory. The table has
122 unique 256-scalar pages and occupies 71,168 bytes.

CLI, Studio and termctl string helpers share this library through CMake.
The native terminal printer uses the separate pinned SDK profile described below.
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

## Pinned terminal profile (BMUX-20, 2026-10-13)

`src/btunicode.c/h` now supplies the native printer's widths, grapheme boundaries
and width effects. Its immutable data comes from the actual pinned SDK property
lookup and all 1,620 reachable class/state transitions. The exporter captures
all 1,114,112 code points, then the offline generator checks complete ranges,
class/state encodings and pin/probe identities before compressing the data.
The compiled profile uses 124 unique pages and 80,384 bytes, including indices
and the 8 KiB transition table. Printing allocates nothing for Unicode lookup.

The SDK's locked uucode dependency contains Unicode 18 draft data dated
2026-06-29. This differs from the Unicode 16 policy of `bunicode` and the current
string/rendering helpers. In particular, U+05C8/U+05C9 are combining marks in
the SDK; treating them as new cells caused mixed-script feed snapshots to
diverge before any resize. The profile follows the pinned dependency rather
than claiming a released Unicode 18 standard. Renderer/measurement alignment
remains BMUX-19 work. Existing Unicode 16 APIs and their official test vectors
remain unchanged.

`tools/ghostty/probe_unicode_profile.py` builds in an isolated source copy after
verifying all 5,915 SDK archive files. It recomputes the uucode package hash with
`zig fetch` into a separate verification cache and records every dependency-file
SHA256. The dependency lock selects uucode commit
`9d55524551411b493cca41ca06363625d90aff1e`. Normal product builds use checked-in
C data and do not require Zig, Python or network access. The Ghostty, uucode MIT
and Unicode notices accompany the data in `THIRD_PARTY`.

```sh
python3 tools/ghostty/probe_unicode_profile.py \
  --work-root /private/tmp/bmux-unicode-profile \
  --archive /private/tmp/bmux-ghostty-source.tar.gz \
  --global-cache-dir /private/tmp/bmux-zig-global \
  --output tests/fixtures/ghostty-unicode-profile.json
python3 tools/ghostty/unicode_fixture.py --check
python3 tests/ghostty_unicode_profile_test.py
```

The small C-ABI SDK corpus adds combining-mark, legacy attachment and
Indic-linker regressions: 46 cases / 215 snapshots pass. Byte-split tests include
the new marks and linker. The unchanged large corpus now matches 76 of 79
snapshots; all three remaining failures are the final managed-page-capacity
growth step. This is a narrower compatibility result, not complete terminal,
renderer or application parity.

Checkpoint verification: normal CLI/Studio builds pass; full serial CTest passes
127/129 in 115.22 s. Failures are the three large compatibility mismatches and
`mining_jobs` foreground_max 135.424 ms against its unchanged 100 ms bound;
an isolated mining rerun passes (0.84 s). The final ASan/UBSan focused run passes
five tests and reproduces the three compatibility mismatches without sanitizer
diagnostics (11.11 s). The profile's four offline guards, unchanged Unicode 16
generator/four guards, six SDK fixture guards, seven compiled harness checks,
four benchmark identity guards, SDK fixture recaptures and strict C11 warning
checks pass. CI and release workflows run the new offline profile checks.
Attribution verifies 44 SDK modules / 32 ported files. This is no timing or
memory improvement claim; the previous benchmark reports describe their own
frozen source identities.
