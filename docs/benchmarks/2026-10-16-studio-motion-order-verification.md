# SDL motion ordering

Studio coalesced all motion events until the end of the event batch. A release
in that batch cleared the dragged divider first, dropping the accumulated drag.
The loop now flushes adjacent motion runs before subsequent non-motion events,
and flushes the final run at batch end. Rendering still happens once per frame.

`tests/studio_bmux_tree.lua` injects a press, two motions and a release through
SDL in one batch. It checks the exact accumulated ratio and released drag state.
It failed before the change (`build/studio-local-drag-before.log`) and passed
afterward in normal and sanitizer builds. Test-only SDL injection now supports
motion coordinates/deltas with the same high-DPI conversion as existing clicks.

Final normal Studio/shared-layout gate: 31/31, 26.58 seconds,
`build/studio-layout-final-verified.log`. Targeted ASAN/UBSAN gate: 15/15,
18.10 seconds, `build-asan/studio-layout-final-verified.log`. Both include the
local drag regression, joined drag, native terminal input, IME/attachment flows,
vim and chooser behavior. Functional durations do not establish input latency.
