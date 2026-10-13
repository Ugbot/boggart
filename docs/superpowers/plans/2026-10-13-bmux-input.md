# BMUX-18: terminal input encoders

Implement the approved C-port roadmap's keyboard and mouse encoders. The C
interfaces accept normalized events and explicit options; terminal methods
obtain negotiated modes from the core. Encoding allocates nothing and returns
complete bytes, no bytes for intentionally suppressed events, or an explicit
invalid-input/capacity failure. It never partially writes a report or changes
motion state on failed encoding. Lua copies output strings; the caller sends
them to the PTY outside parser callbacks. IME text and raw physical key events
remain separate so composed text cannot be sent twice.

1. Port `src/input/mouse_encode.zig` to `src/bmouse.c/h`. Normalize coordinates
   to signed terminal pixels at the host boundary, avoiding renderer/platform
   dependencies. Retain X10/normal/button/any event policies, X10/UTF-8/SGR/urxvt/
   SGR-pixel formats, modifiers, wheel/extra-button codes, clamped cell positions,
   out-of-viewport drag/release behavior and cell-motion deduplication. Bound
   dimensions and integer arithmetic; test protocol bytes and output capacity.
2. Extend `bterm` with mouse modes 9/1000/1002/1003 and format modes
   1005/1006/1015/1016. Negotiation uses the C stream, survives feed fragmentation,
   and resets on RIS. Add Lua `mouse(event)` and `input_state()` methods with
   strict validation, plus full C/Lua/sanitizer/parity coverage.
3. Port keyboard behavior to `src/bkey.c/h`: legacy C0/Alt handling, cursor and
   keypad application modes, function keys, modifiers, backarrow/NumLock,
   modifyOtherKeys mode 2 and all Kitty flags (disambiguation, events, alternate
   keys, all keys, associated text). Define unshifted/base-layout codepoints,
   modifier sides and consumed modifiers, composing/IME text and release/repeat
   actions explicitly. Read all nested key tables and notices before copying;
   derive compact Kitty functional definitions from the primary protocol to avoid
   importing Foot's table without its required notice. Record every translated
   source and source-derived file in the pinned ledger.
4. Implement bounded per-screen Kitty push/pop/set/query state and modifyOtherKeys
   negotiation, plus relevant DEC key modes in the native dispatch. Queries use
   the existing reply sink. Add `key(event)`, `paste(text)` and focus helpers with
   protocol-vector tests for the whole parser-to-encoder path, reset, alt-screen
   isolation, malformed sequences, IME and Unicode.
5. Replace `KEY_SEQ` and hand-coded Ctrl letters in terminalview.lua with the
   shared encoder, preserving reserved pane shortcuts and the studio's text/IME
   event contract. Route mouse press/release/motion/wheel to the encoder only
   when reporting is active, otherwise retain normal UI scrolling/selection.
   Avoid adding a second byte parser or duplicate native grid to the old view.
   Full native output/PTY integration remains BMUX-21; if that integration is
   required to make studio negotiated input authoritative, keep BMUX-18 open
   until its fixed-table replacement is verified there.
6. Verify each complete increment with C tests, the Lua terminal suite, relevant
   ASan/UBSan suites, both builds, full regression suite and CLI/studio parity.
   Update `docs/terminal-core.md`, source identity and attribution, attach tracker
   criteria/commits, and close BMUX-18 only when keyboard, mouse and actual studio
   routing satisfy the story. The broader goal remains all BMUX roadmap phases.

Mouse coordinate convention follows the pinned encoder: cell reports are
one-based after clamping, while SGR pixels preserve signed terminal coordinates
without cell clamping. The host accounts for pane origin/padding/scaling before
calling. Model validation rejects unsupported button numbers and meaningless
press/release events with no button; motion may carry no button.

Progress:
- [x] Mouse encoding and native negotiated state + Lua API.
- [x] Keyboard encoding, notices, flags and native protocol negotiation.
- [x] Paste/focus helpers.
- [ ] Host input integration on the native resize/PTY path.
- [ ] Studio key/mouse routing and removal of the fixed table.
- [ ] Story acceptance evidence and completion.

Mouse increment evidence (2026-10-13): CLI and studio builds pass; full serial
CTest passes 111/111 in 64.61 seconds; terminal ASan/UBSan checks pass 10/10 in
2.90 seconds; CLI/studio core parity matches all 27 fields. The pinned attribution
check validates 31 modules and 18 ported files. Full-suite verification exposed
an existing mining settlement test's fixed 100 ms worker wait; a separate test
fix polls for the actual locked settlement and asserts the database error before
checking recovery. The foreground latency bound remains unchanged. No live
studio mouse/keyboard integration or whole-story completion is claimed.

Keyboard increment evidence (2026-10-13): both builds pass; focused terminal
tests pass 12/12 (4.89 seconds), terminal ASan/UBSan checks pass 12/12 (5.85
seconds), full serial CTest passes 113/113 (83.44 seconds), and CLI/studio core
parity matches 28 fields. Attribution validates 36 pinned modules and 20 ported
files, with the Foot notice hash and derivative header included. The compiled
backend identity now includes 22 source/header files. Strict invalid UTF-8 and
C1 associated-text filtering are documented adaptations. Kitty functional
numbers derive from the primary protocol; `kitty.zig` stays studied. Studio
still uses its old input/output path; paste/focus helpers and routing are pending.

Paste/focus increment evidence (2026-10-13): both builds pass; focused terminal
tests pass 14/14 (7.27 seconds), ASan/UBSan terminal checks pass 14/14 (8.67
seconds), full serial CTest passes 115/115 (147.97 seconds), and CLI/studio core
parity matches 30 fields. Attribution validates 40 pinned modules and 22 ported
files; compiled identity includes 24 source/header files. Focus mode enables
emit the current host focus, and host focus survives RIS. The paste transform
and optional heuristic remain separate. These helpers complete native input
encoding; live Studio routing still requires the single native parser/grid,
Unicode width/graphemes (BMUX-19), resize/reflow (BMUX-20) and libuv PTY (BMUX-21).
