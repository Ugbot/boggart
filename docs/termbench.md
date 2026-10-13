# Terminal performance ledger

BMUX targets a terminal multiplexer with cmux capabilities and lower overhead.
`termbench` establishes repeatable parse/grid throughput workloads before the C
terminal core lands. BMUX-9 supplies this harness; the other measurements and
comparative baselines remain BMUX-10 and BMUX-11 work.

```sh
ninja -C build termbench
ctest --test-dir build -R '^termbench$' --output-on-failure
BOGGART_HOME=build/termbench-home ./boggart --eval tools/termbench.lua -- --json --output build/termbench.json
BOGGART_HOME=build/termbench-home ./boggart --eval tools/termbench.lua -- --bytes 4194304 --samples 5 --chunk 4096
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

The first backend loads **the actual** `studio/data/core/terminalview.lua` parser
with inert UI dependencies in a separate Lua environment. It neither duplicates
the parser nor patches the running studio. It implements only the current toy
behaviour: alternate screen, scroll regions, 256/RGB colour, wide-cell layout and
grapheme clustering are missing. Reports retain throughput for those streams
while listing missing features; `--require-features` rejects them. Agreement
between chunk sizes verifies streaming consistency, not VT conformance. The
Ghostty differential oracle and application conformance tests have their own
BMUX gates.

## Backend interface and budgets

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
numbers and final performance targets are not yet measured. Cold start, idle
RSS at 1/10/100 panes, socket RTT and keypress-to-pixel p99 require BMUX-10
instrumentation. No performance win over cmux or Ghostty is established yet.

The roadmap's provisional goals remain: at least Ghostty parse throughput,
cold start below 100 ms, idle RSS below one quarter of cmux, control RTT below
100 µs, and renderer p99 below 8 ms with 120 fps flood scrolling. BMUX-11 sets
final numeric budgets from comparable measurements; later phase gates must
also prove features, terminal correctness and detach/reattach behaviour.
