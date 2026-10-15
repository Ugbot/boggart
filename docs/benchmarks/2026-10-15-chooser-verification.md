# Bmux chooser submission (BMUX-79)

The SDL event loop can deliver text input and Enter before CommandView updates.
Submission previously consumed the suggestions for the old query, so typing
`Boggart TUI` could launch Codex. Empty fuzzy queries also ranked short labels
first rather than preserving the declared default.

CommandView now refreshes a changed query before moving, completing or
submitting. Completion records its new text and document revision, preserving
an explicit keyboard selection. Empty modal queries retain declaration order.

`tests/studio_chooser.lua` failed before the fix on declared default order
(`build/chooser-before.log`). It now exercises real SDL events for same-frame
text/Enter, text/Tab/Enter, explicit arrow selection and unmatched queries.
`studio_fleet_agents` confirms selected provider metadata reaches the launcher.

Verification on macOS arm64, normal and ASAN/UBSAN builds:

```
ctest --test-dir build -R '^(studio_chooser|studio_fleet_agents|studio_terminal_attached)$' --output-on-failure
ctest --test-dir build-asan -R '^(studio_chooser|studio_fleet_agents|studio_terminal_attached)$' --output-on-failure
```

Both passed 3/3: normal 6.68 seconds, sanitizer 8.96 seconds. Logs:
`build/chooser-verified.log`, `build-asan/chooser-verified.log`.
The attached terminal regression covers selection/focus alongside live native
PTY input and attachment lifecycle. No performance claim follows from these
functional test durations.
