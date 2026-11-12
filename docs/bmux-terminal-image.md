# Native attached terminal images

Studio can render a validated `terminal.client` replica through the same C
glyph, shaping, color emoji and retained row pipeline as a local terminal:

```lua
local image = renderer.terminal_image()
image:apply(session:view())
local context = renderer.new_terminal(font, image, theme)
session.on_update = function(view) image:apply(view) end
context:draw(x, y, cell_width, cell_height, first_row, last_row)
```

Rows are indexed over the supplied history tail followed by the visible screen.
The source does not own a PTY or VT parser, and does not reconstruct ANSI output.
The client replica validates protocol identities, cursors, UTF-8, state and
process fields. The image consumes its borrowed **read-only** row convention:
never mutate an accepted row table in place. Unchanged row identities avoid
recapture; fresh equal rows preserve native draw-cache identities as well.

`apply` checks dense arrays, dimensions 1..4096, a maximum of 256 history rows,
32768 total cells, per-cell text up to 65535 bytes, native cell/style ranges,
and an 8MiB packed image limit. It copies resolved text/styles into owned native
rows. A staging failure leaves the prior image and generation intact and frees
staged rows immediately. A generation guard rejects an outer update if a Lua
finalizer closes or updates the image during staging.

`image:stats()` reports total rows, columns, history count, packed bytes,
generation, captures and closed state. `image:close()` releases the source;
queued frame commands retain rows independently. `__gc` and `__close` also
release the source. The renderer rejects drawing a closed source or font.

This supplies the rendering foundation for BMUX-34. The
[Studio attached pane](bmux-studio-attachment.md) uses it for its visible
attach/control flow. See
[verification](benchmarks/2026-10-15-terminal-image-verification.md).
