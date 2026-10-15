# Attached terminal native image plan

**Goal:** BMUX-34 uses the existing native glyph/row renderer for replica cells,
without a local PTY, VT parser clone or synthesized ANSI stream.

**Contract:** `renderer.terminal_image()` creates a bounded native source;
`:apply(view)` atomically consumes the read-only replica row convention;
`renderer.new_terminal(font, image, theme)` uses the same draw/cache path as
native terminals. The source caches unchanged immutable row identities and
reuses equal native rows. Source rows are owned independently of Lua strings.
Geometry 1..4096, 32768 cells including <=256 tail rows, 8MiB packed image cap.

- [x] Add resolved-cell capture to `termgrid`; preserve exact native row layout
  and hashing, without accepting borrowed strings beyond capture.
- [x] Add `terminalimage.c/.h`: protected staging with eager cleanup on success
  and error, retained prior rows, generation guard against reentrant apply/close,
  immutable row identity caching and atomic publication. No native borrow crosses
  a Lua allocation. Add source identity/build registration.
- [x] Extend native terminal renderer to accept this image source and reuse the
  existing glyph/cache/queued-row ownership path.
- [x] Test native/image pixel parity (Unicode/styles/wide/history/reflow), cached
  updates, malformed late rows, source/font/renderer closure and finalizers.
- [x] Build/test normal and sanitizer, document evidence, commit/push under the
  standing instruction. BMUX-34 stays in progress for the actual remote-pane
  backend and visible attach/control actions; do not claim the UI complete.
