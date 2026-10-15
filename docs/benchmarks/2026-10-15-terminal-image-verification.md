# BMUX-75 native terminal image verification

The native renderer now accepts a bounded immutable replica image without a
client PTY/parser or new runtime dependency. Native row layout, hashing,
measurement, shaping and retained frame commands are shared with local panes.

`tests/studio_terminal_image.lua` compares actual SDL screenshot bytes between
local and replicated sources: CJK, combining text, ZWJ emoji, flags, heart,
wide cells, bold/italic, colors, decorations, links, bounded history, resize
reflow and alternate/primary screen. It verifies unchanged/equal row reuse,
one-row capture, late malformed row rejection, sparse arrays, cell/byte limits,
and unchanged pixels after rejected updates. Lifetime cases include queued
commands after source/context/font closure, finalizer closure during staging,
and nested apply preserving the inner committed image.

The C termcache test also checks resolved-value capture against native capture
and invalid width rejection. Review covered staging cleanup/refcounts,
reentrancy guards, owned text roots, array/byte bounds and renderer ownership;
no native source borrow crosses a Lua allocation.

Normal and ASan/UBSan RelWithDebInfo builds completed. Final affected sets
passed **11/11 normal in 3.01s** and **11/11 ASan/UBSan in 6.66s**, including
the final queued-font closure case. Logs are under the ignored build
directories, `terminal-image-verification-final.log`. C11 strict syntax checks
(`-Wall -Wextra -Werror`) pass for the image and resolved-row capture modules.

```sh
ctest --test-dir build \
  -R '^(termcache|studio_terminal_image|studio_terminal_native|studio_terminal_render|studio_terminal_clusters|studio_grid_text|studio_agent_clusters|studio_color_emoji|studio_grapheme_edit|terminal_replica|terminal_input_events)$' \
  --output-on-failure
# Repeat with --test-dir build-asan.
```

BMUX-34 remains in progress: this evidence proves the native image source,
not the still-pending visible remote attachment UI.
