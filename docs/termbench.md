# Terminal performance ledger

BMUX targets a terminal multiplexer with cmux capabilities and lower overhead.
`termbench` measures repeatable parse/grid throughput in the native C terminal
core and the previous Lua reference. BMUX-9 supplies this harness. BMUX-101 adds
validated server-to-Studio presentation timing below; BMUX-102 adds
[separate-process startup, 1/10/100-pane resources and socket RTT](termbench-system.md).
Comparisons remain BMUX-11 work. Startup profiles and measured boundaries must
match before drawing comparative conclusions.

## Server-to-Studio presentation latency (BMUX-101)

`tools/termbench/studio_latency.lua` runs a real server-owned C raw-PTY fixture,
joins the production layout, takes its controller lease, injects SDL key/text
events, and waits for the corresponding RGB cell in a successfully presented
frame. A native, opt-in script probe timestamps immediately after
`SDL_RenderPresent`, then validates one pixel from the retained scene texture.
No sampling/timing/readback occurs in ordinary sessions. It records every input,
timestamp, latency, frame serial and readback cost. Old frames, wrong pixels and
failed readbacks cannot satisfy a sample. Setup waits for real geometry and
scrolling to settle; an unchanged cached frame is not counted as a new present.

```sh
cmake --build build -j8
env -u SDL_VIDEODRIVER \
  HOME="$PWD/build/testhome/termbench-latency-real" \
  BOGGART_HOME="$PWD/build/testhome/termbench-latency-real/.boggart" \
  SHELL=/bin/sh BMUX_BENCH_FIXTURE="$PWD/build/termbench_pty" \
  BMUX_LATENCY_SAMPLES=200 BMUX_LATENCY_WARMUPS=20 \
  BMUX_BENCH_BUILD_LABEL=RelWithDebInfo-none \
  BMUX_LATENCY_REPORT="$PWD/build/studio-key-present.json" \
  BOGGART_STUDIO_SCRIPT="$PWD/tools/termbench/studio_latency.lua" \
  ./boggart-studio .
```

Run uncontended from the repo root, with the actual window renderer. The C
fixture is POSIX-only. `BMUX_LATENCY_FPS` optionally overrides production frame
pacing (default 60); samples allow 1–10000 and warmups 1–1000. Normal GC remains
enabled. The report includes both executable hashes, fixture/script/font
hashes, compiled terminal/renderer identities, machine and geometry. The
controller resizes the initial 80x24 PTY to the actual visible pane, which is
reported. The server uses the full control policy and named SQLite journal.

This measures **synthetic key to application presentation API return**, not
physical display scanout or randomized human arrival. Injection occurs from a
core coroutine after a frame. GPU readback follows the timestamp and is excluded
from the current sample; its cost can perturb subsequent frames. In particular,
SDL may submit work before the GPU completes it. Do not interpret this as a
photon latency, add it to unrelated draw timings, or compare it with another
terminal measured at a different boundary. See the official
[present](https://wiki.libsdl.org/SDL3/SDL_RenderPresent) and
[readback](https://wiki.libsdl.org/SDL3/SDL_RenderReadPixels) contracts.

Initial real Metal capture, 2026-10-16, Apple M5 Max, Darwin 25.6.0,
RelWithDebInfo/no sanitizer, 60 fps, 172x34 viewport, 200 samples after 20 warmups:

| Metric | p50 | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Synthetic key to present return | 2.659 ms | 5.246 ms | 16.448 ms | 17.960 ms |
| Subsequent one-pixel validation readback | 5.653 ms | 6.171 ms | 6.256 ms | 7.621 ms |

[Raw samples and identities](benchmarks/2026-10-16-studio-key-present.json).
Nearest-rank quantiles; p95 requires at least 20 samples and p99 at least 100.
This is one Boggart capture and establishes no cmux/Ghostty advantage. CTest's
three-sample dummy-renderer run checks correctness only and emits no p95/p99.

```sh
ninja -C build termbench
ctest --test-dir build -R '^termbench$' --output-on-failure
BOGGART_HOME=build/termbench-home ./boggart --eval tools/termbench.lua -- --json --output build/termbench.json
BOGGART_HOME=build/termbench-home ./boggart --eval tools/termbench.lua -- --bytes 4194304 --samples 5 --chunk 4096
BOGGART_HOME=build/termbench-home ./boggart --eval tools/termbench.lua -- --backend termbench.backends.lua --output build/termbench-lua-comparison.json
```

Run from the repository root. `--help` lists all options. The Ninja target needs
no window server, PTY, child shell, Zig or external terminal installation, and
uses an isolated Boggart home. The JSON report includes machine/OS identity,
runtime versions, time, dimensions, chunk size, parser/corpus SHA-256 hashes and
every timed sample.

## What is measured

Five deterministic, vtebench-style workloads repeat complete units up to at
least the requested byte count:

| Scenario | Traffic |
| --- | --- |
| `plain` | Large text output with CR/LF, like `cat` |
| `dense-sgr` | Frequent attributes, 16/256-colour and RGB SGR |
| `unicode` | Multibyte scripts, wide characters, combining and ZWJ sequences |
| `scroll` | Sustained row output and scrollback eviction |
| `alt-screen` | Alternate-screen switches, clears, cursor addressing and scroll regions |

The runner precomputes feed chunks, validates whole-stream versus seven-byte
and requested-size chunks, warms once, then measures fresh terminals with
`uv.hrtime`. Construction, snapshot comparisons, JSON encoding, and full GC
before each sample are outside the interval. Normal GC during parsing remains
enabled. The interval includes grid writes and scrollback, not rendering or PTY
transport. MB/s means decimal megabytes per second, calculated from actual
bytes fed and the median elapsed time; all elapsed samples remain in the JSON.

The Lua reference backend loads the exact v1 Studio parser frozen at
`tools/termbench/reference/terminalview-v1.lua` before native pane integration
(origin commit `93772f7`, SHA256
`74b819186f68abd48ee7db85fbe12ef50cd9fcc148d11b022f35a020880a38b7`).
It uses inert UI dependencies in a separate Lua environment and is identified
as `studio-lua-reference`; it does not represent the current production pane.
It implements only the historical toy
behaviour: alternate screen, scroll regions, 256/RGB colour, wide-cell layout and
grapheme clustering are missing. Reports retain throughput for those streams
while listing missing features; `--require-features` rejects them. Agreement
between chunk sizes verifies streaming consistency, not VT conformance. The
Ghostty differential oracle and application conformance tests have their own
BMUX gates.

## Backend interface and budgets

The default `termbench.backends.native` adapter uses `require("terminal")` in
both front ends. Its feed call goes directly to the C parser/grid, with no Lua
callbacks per byte. It supports the tested alternate screen, scroll regions
and 256/RGB SGR paths, wide-cell pairs and bounded grapheme layout. Its
snapshot copies complete cluster text, the active screen, styles, cursor/modes, scrollback and pending
parser diagnostics. Both adapters use a 2000-row history limit. The native
report records 29 source/header hashes compiled into the current executable, and the
adapter rejects a checkout that differs from those hashes before timing.

`--backend MODULE` selects a Lua adapter loaded from `tools/?.lua` or the normal
module path. Its interface is:

```lua
return {
  name = "backend-name",
  features = { alt_screen = true, scroll_regions = true, truecolor = true,
    color256 = true, wide = true, graphemes = true },
  new = function(opts) -- opts.cols, opts.rows
    return terminal -- :feed(bytes), :snapshot(), :close()
  end,
}
```

`snapshot()` returns a deterministic JSON-compatible value containing observable
screen, cursor, styles, scrollback and pending parser state. Backend names and
feature declarations identify what each measurement actually covers.

`--budgets PATH` reads an explicit JSON object, for example
`{"plain":{"min_mbps":0.1},"scroll":{"min_mbps":0.1}}`. Unknown scenario names,
invalid budgets, inconsistent snapshots and throughput below a supplied floor
fail the command. Floors must come from a recorded backend/machine baseline;
there is no invented speed floor for the existing Lua parser. Compare identical
corpora, dimensions, chunk sizes, GC policy and workload scope. Ghostty/cmux
end-to-end PTY throughput must not be labelled a parser-only comparison.

## Baseline status and phase gates

Development reference measured 2026-10-13 on this Mac (Darwin 25.6.0, arm64;
RelWithDebInfo build, Lua 5.5, libuv 1.52.1): 80×24, 4096-byte chunks,
three timed samples after warmup, approximately 1 MiB per scenario, GC enabled.
Parser source SHA-256:
`74b819186f68abd48ee7db85fbe12ef50cd9fcc148d11b022f35a020880a38b7`.
The complete local report is `build/termbench-lua-baseline.json`.

| Scenario | Bytes fed | Median ms | MB/s | Feature coverage |
| --- | ---: | ---: | ---: | --- |
| plain | 1,048,629 | 591.19 | 1.774 | current toy text/grid handling |
| dense-sgr | 1,048,608 | 564.15 | 1.859 | 256/RGB colour missing |
| unicode | 1,048,600 | 616.30 | 1.701 | wide/grapheme layout missing |
| scroll | 1,049,152 | 1,377.44 | 0.762 | current toy scrollback handling |
| alt-screen | 1,048,750 | 2,626.54 | 0.399 | alt-screen/scroll regions missing |

The Lua results are a development reference. Same-machine cmux/Ghostty parse
numbers and final performance targets are not yet measured. BMUX-10 now records
process startup, idle CPU/RSS at 1/10/100 panes, socket RTT and validated
key-to-presentation p99; see [system results](termbench-system.md) and the
presentation capture above. No performance win over cmux or Ghostty is
established yet.

The roadmap's provisional goals remain: at least Ghostty parse throughput,
cold start below 100 ms, idle RSS below one quarter of cmux, control RTT below
100 µs, and renderer p99 below 8 ms with 120 fps flood scrolling. BMUX-11 sets
final numeric budgets from comparable measurements; later phase gates must
also prove features, terminal correctness and detach/reattach behaviour.

## Native C development measurement

Measured sequentially on 2026-10-13 on the same Mac/configuration described
above, after full tests and sanitizer jobs finished: 80×24, 4096-byte chunks,
three samples, approximately 1 MiB per scenario, normal GC. Construction,
snapshots and encoding remain outside the timing interval. The Lua reference
and native core were measured with the same rebuilt executable. Corpus hashes,
byte counts and harness options were checked for equality before comparison.
Complete reports, including all samples and compiled source hashes, are saved
in [native report](benchmarks/2026-10-13-terminal-c.json) and
[Lua reference report](benchmarks/2026-10-13-terminal-lua.json).

| Scenario | Native median ms | Native MB/s | Lua MB/s | Scope |
| --- | ---: | ---: | ---: | --- |
| plain | 8.45 | 124.050 | 2.150 | text/grid; native 57.7× reference throughput |
| dense-sgr | 8.04 | 130.416 | 2.589 | native 256/RGB supported; Lua lacks them |
| unicode | 6.03 | 173.866 | 2.505 | both lack wide/grapheme layout |
| scroll | 12.25 | 85.658 | 1.533 | grid/history; native 55.9× reference throughput |
| alt-screen | 46.59 | 22.512 | 1.063 | native alt-screen/regions supported; Lua lacks them |

Plain and scrolling show a substantial improvement over the previous Lua
byte path. Other rows record workload timings with their differing feature
coverage. These are parse/grid measurements, not shell-to-pixel performance or
a comparison with cmux/Ghostty. The studio still uses its Lua parser until
BMUX-21 integration; no live-terminal speed improvement is claimed here.


Link ownership verification (BMUX-17), measured separately after the full test
and parity runs, uses the same 1 MiB scenario targets, 4096-byte chunks and 80x24
geometry with five samples. The source-identified
[link ownership report](benchmarks/2026-10-13-terminal-links.json) records plain
117.913 MB/s, dense-SGR 126.271, Unicode 142.233, scroll 96.685 and alternate screen
24.822. Whole/fragmented grids agree. At that checkpoint Unicode width/graphemes
were unsupported;
these measurements describe native parse/grid work, with no cmux/Ghostty or
live-rendering speed claim. The earlier native artifact retains its original
13-file build identity; it is a historical measurement, not the current source.


Native Unicode printing checkpoint (BMUX-19): the
[Unicode report](benchmarks/2026-10-13-terminal-unicode.json) uses five samples,
1 MiB scenario targets, 4096-byte chunks, 80x24 geometry and 29 compiled source
hashes. All five workloads pass `--require-features` and whole/fragmented grids
agree. Mode 2027 is enabled and snapshots preserve complete cluster text.

| Scenario | MB/s |
| --- | ---: |
| plain | 49.223 |
| dense-sgr | 57.821 |
| unicode | 41.121 |
| scroll | 26.339 |
| alt-screen | 9.744 |

This is a headless parse/grid baseline after wide-pair and grapheme ownership
integration. Throughput is lower than the earlier link-ownership report; no
performance improvement or cmux/Ghostty speed parity is claimed. Studio still
needs the native PTY/parser and renderer integration.


Default-style hot-path optimization (BMUX-60):
[before](benchmarks/2026-10-13-default-style-before.json) and
[after](benchmarks/2026-10-13-default-style-after.json) use seven samples with
the same 1 MiB targets, 80x24 geometry, 2000 history rows, 4096-byte feeds and
normal GC. The 29-file compiled identities differ only in `src/lpage.c`; every
corpus hash, feature check and whole/fragmented equality check agrees.

| Scenario | Before MB/s | After MB/s |
| --- | ---: | ---: |
| plain | 15.065 | 54.460 |
| dense-sgr | 49.402 | 62.390 |
| unicode | 35.375 | 51.526 |
| scroll | 27.448 | 49.422 |
| alt-screen | 9.611 | 19.600 |

Default style ID 0 is permanent and uncounted. Cell retain/release and row
clearing now bypass style-pool calls for that ID; non-default styles, links and
graphemes retain their existing validation and ownership rules.

The [profile and pilot evidence](benchmarks/2026-10-13-default-style-analysis.json)
records a five-second macOS CPU sample (3,765 thread samples, 937 at style
retain/release) and eleven-sample C comparisons. DTrace timed out without
samples, so it supplies no performance evidence. The isolated C pilot improves
every workload; the normal runner's pre-change plain-text samples are highly
variable (21–119 ms), so its apparent plain-text gain is not a reliable estimate
of the optimization. Scroll and alternate-screen gains also appear in the
isolated pilot. Raw timings are retained in both sets of reports.

To reproduce the C pilot, build the chosen revision normally, generate the
1 MiB corpora using `tools/termbench/scenarios.lua`, and compile the
[preserved harness](benchmarks/2026-10-13-default-style-harness.c) with:

```sh
clang -O2 -g -std=c99 -Isrc docs/benchmarks/2026-10-13-default-style-harness.c build/libboggart_vt.a build/libboggart_unicode.a -o /tmp/bmux-core-bench
/tmp/bmux-core-bench /tmp/bmux-plain.bin 11 1
```

Each output line is one elapsed feed time in nanoseconds, after one unscored
warmup. Screen creation and destruction are outside timing. The profile used
the same harness with `plain.bin 1 300` and macOS `sample <pid> 5 1 -mayDie`.
The temporary candidate replaced only the page object; the official after
report uses the normal product build. This measures parse/grid work and does
not establish PTY, GPU, cmux/Ghostty or keypress-to-pixel performance.

Verification: full serial CTest 120/120 (122.32 s), ASan/UBSan focused 21/21
(16.85 s), CLI/Studio parity 32 identical fields, strict C99 warnings and
pinned attribution checks. Exact ownership, Unicode and GC snapshot tests
remain unchanged and pass.
