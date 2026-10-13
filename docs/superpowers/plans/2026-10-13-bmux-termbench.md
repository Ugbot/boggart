# BMUX terminal benchmark implementation plan

**Goal:** Implement BMUX-9 as the first measurement tool for the existing BMUX
roadmap, then use the same workloads against the C terminal core.

**Architecture:** A deterministic workload generator and a headless runner share
a small backend interface: `new(opts)`, `feed(bytes)`, `snapshot()`, `close()`.
The first adapter loads the actual studio Lua parser in an isolated environment
with inert window/PTY dependencies. Timings include parsing, grid writes,
scrollback and normal garbage collection; construction, workload generation,
snapshot validation and JSON encoding happen outside the timed interval.

**Constraints:** Keep the C99 product build; preserve the existing CLI `term`
module. Do not copy cmux source. Report unsupported features explicitly. This
benchmark establishes throughput and stream-fragmentation evidence, not VT
conformance or keypress-to-pixel latency.

## Deliverable: headless throughput benchmark (BMUX-9)

- [x] Add `tests/termbench.lua`, initially failing because the runner and adapter
  do not exist. Cover corpus determinism, byte counts, ANSI/UTF-8 split boundaries,
  actual grid contents, bounded scrollback, options, and regression-budget failure.
- [x] Add `tools/termbench/scenarios.lua`: plain text, dense SGR, Unicode,
  scrolling and alternate-screen traffic, repeating complete units to the byte
  target without cutting off UTF-8 or an escape sequence.
- [x] Add `tools/termbench/backends/lua.lua`: load the existing terminal view
  without opening a window, spawning a shell, or changing `package.loaded`.
  Normalize snapshots to a JSON-compatible table containing screen, scrollback,
  cursor, attributes and pending parser state.
- [x] Add `tools/termbench/runner.lua`: precompute chunks, check whole-stream vs
  fragmented snapshots, warm once, time fresh terminals with `uv.hrtime`, report
  median throughput and all samples, and enforce explicit per-scenario budgets.
- [x] Add `tools/termbench.lua`: CLI options after `--`, human/JSON reports,
  optional JSON output and budget files, nonzero exit on invalid inputs or gates.
- [x] Register the headless `termbench` Ninja target and CTest suite in
  `CMakeLists.txt`; document commands, schema, feature limits and ledger in
  `docs/termbench.md`.
- [x] Run `cmake --build build`, `ctest --test-dir build --output-on-failure`,
  `ninja -C build termbench core-parity`; review the patch and commit with BMUX-9
  and DCO sign-off. Record tracker evidence after verification.

## Follow-on work

BMUX-10 adds instrumented latency/startup/RSS/control measurements. BMUX-11
records comparable cmux/Ghostty baselines on this machine and sets final targets.
BMUX-12 adds CI regression gates and the optional upstream oracle. BMUX-13 pins
and attributes Ghostty before the parser/storage ports begin. These remain
separate acceptance gates; a Lua benchmark does not satisfy them.
