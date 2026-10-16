# BMUX-101 verification

BMUX-10 remains in progress: this increment supplies validated interactive
presentation instrumentation. Separate-process startup, 1/10/100-pane CPU/RSS
and full-policy socket RTT remain, followed by BMUX-11 comparisons.

- Normal RelWithDebInfo build: success. Focused CTest **12/12**, 6.63 s,
  `build/bmux-latency-verified.log`.
- ASan/UBSan build: success. Same focused CTest **12/12**, 9.08 s,
  `build-asan/bmux-latency-verified.log`. The C PTY fixture is instrumented too.
- Full server/controller/PTY/Studio dummy-renderer workflow repeated **10/10**,
  13.50 s, `build/bmux-latency-repeat-fixed.log`. Correctness only, no timing gate.
- Real macOS Metal renderer: exit 0, **200/200** RGB-validated samples after 20
  warmups. [Raw report](2026-10-16-studio-key-present.json),
  `build/bmux-latency-real-sdl.log`. Independent JSON check confirmed all RGBs,
  timestamp differences, positive readback durations and nearest-rank p99.
- Negative workflow: replace the fixture with `/bin/cat`, which never paints
  the expected RGB. Exit **1** on marker deadline and **no timing JSON** emitted;
  `build/bmux-latency-negative.log`. Its failure screenshot is diagnostic only.
- C fixture: strict C11 `-Wall -Wextra -Werror -fsyntax-only` passed.
- `git diff --check` passed.

Focused suites: `pty_transport`, `studio_uvbridge`, `renderer_fonts`,
`renderer_clusters`, `renderer_atlas`, `termbench_pty`, `termbench_measure`,
`studio_termbench_latency`, `studio_terminal_render`, `studio_terminal_clusters`,
`studio_bmux_layout`, `studio_present_probe`.

The native probe checks actual RGB, frame serial and monotonic timing; unchanged
cached scenes do not generate samples. Accounting tests reject old timestamps,
old frame serials, wrong RGB and invalid readbacks. Setup regression coverage
waits for real controller-resize geometry and the old scroll offset to settle.
The initial fixed six-frame wait failed intermittently (4 passes, then failure);
the stable-geometry condition passed ten consecutive complete workflows.

Measured boundaries and limitations are in [the ledger](../termbench.md).
The 2.659 ms median / 16.448 ms p99 is synthetic input to the SDL present API
return. Median subsequent GPU readback was 5.653 ms. Neither is a physical
scanout measurement or a comparative cmux/Ghostty performance claim.
