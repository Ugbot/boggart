# System termbench

`tools/termbench/system.lua` measures real separate server/Studio processes,
native PTYs, the full control policy and the normal SQLite journal. Its C
sampler is a development executable; no sampler or Python dependency is added
to the product.

```sh
cmake --build build -j8
env -u SDL_VIDEODRIVER \
  BOGGART_HOME="$PWD/build/termbench-system-home" \
  BMUX_SYSTEM_STUDIO="$PWD/boggart-studio" \
  BMUX_BENCH_FIXTURE="$PWD/build/termbench_pty" \
  BMUX_SYSTEM_SAMPLER="$PWD/build/termbench_sample" \
  BMUX_BENCH_BUILD_LABEL=RelWithDebInfo-none \
  BMUX_SYSTEM_REPORT="$PWD/build/bmux-system.json" \
  ./boggart --eval tools/termbench/system.lua
```

Run from the repository root with builds/tests stopped. The window must use the
actual renderer. CTest uses dummy SDL and short intervals for correctness only.
The native sampler supports macOS and Linux; this capture verifies macOS.

| Environment option | Default | Bounds |
| --- | --- | --- |
| `BMUX_SYSTEM_STARTS` | 20, after one warmup | 1–200 |
| `BMUX_SYSTEM_PANES` | `1,10,100` | 1–3 scenarios, each 1–100 |
| `BMUX_SYSTEM_IDLE_SAMPLES` | 3 | 1–20 |
| `BMUX_SYSTEM_IDLE_MS` | 5000 | 100–60000 |
| `BMUX_SYSTEM_SETTLE_MS` | 1000 | 0–60000 |
| `BMUX_SYSTEM_RTT_SAMPLES` | 1000 | 1–10000 |
| `BMUX_SYSTEM_RTT_WARMUPS` | 100 | 1–1000 |

The executable/fixture/sampler/report paths above are required. Build labels
are annotations; recorded executable hashes identify what actually ran.

## Boundaries

Startup creates fresh private server and Studio homes/databases for each trial.
This is **first-use, separate-installation startup**, with warmed filesystem
caches. It includes first-run store initialization in both processes; it is not
a measurement of restarting an initialized, shared user home. The latter needs
its own profile before comparative restart claims or final startup targets.
No OS caches are flushed. Environment inheritance is limited to the graphics
session and a controlled PATH/HOME/SHELL; credentials/config are not inherited.

The server interval starts immediately before `uv.spawn` and ends at its first
decoded healthy reply. Socket observation uses a 1 ms timer. Socket creation can
precede listening, so safe startup health probes may retry; all that time and
the probe count are included. The Studio interval starts immediately before its
spawn and ends at the first RGB-validated terminal presentation API return.
The parent observes an atomically published ready file; that observation delay
is excluded from Studio timing. Full startup spans server spawn, health/PTY/tree
setup and Studio spawn through that terminal presentation.

This uses the existing opt-in native [presentation probe](termbench.md), not a
physical scanout measurement. The probe is disabled after the first valid
frame. The startup helper returns after all N views attach, leaving no benchmark
polling thread/timer during idle. A signal observer permits normal detach/quit.
The window is 1000x800 points; read-only PTYs stay exactly 80x24 with a history
capacity of 2000. Their C fixture paints one cell and blocks in raw `read`;
scrollback is empty. All N panes are in a balanced split tree, all N views remain
attached, and the first pane is zoomed visible. The project is this repository,
including normal Studio scan/watch activity, not an empty synthetic directory.

RSS is sampled separately for the server, Studio and each known fixture PID.
Role sums do not deduplicate shared pages. The coordinator, sampler, OS window
server and auxiliary processes outside those explicit PIDs are excluded.
CPU is a user+system delta over each PID's actual monotonic sample interval,
reported as percent of one CPU and summed by role. A PID identity change or a
backwards CPU counter fails the sample. On macOS, `proc_pid_rusage` CPU Mach ticks
are converted using `mach_timebase_info`; RSS is bytes. On Linux, `/proc/PID/stat`
CPU ticks use `_SC_CLK_TCK` and RSS pages use `_SC_PAGESIZE`. The sampler's CPU-burn
self-test catches a missing timebase conversion. See Apple's
[rusage collection](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)
and the Linux [proc documentation](https://docs.kernel.org/6.17/filesystems/proc.html).

Each timed health request opens a new UDS connection using the actual native Lua
client. Timing runs from request call through full response/JSON decoding in its
callback. Measured RTTs never retry or wait on a 1 ms polling loop/Studio frame.
All samples, per-PID snapshots, geometry, source identities and executable hashes
remain in the report. Both server and Studio must exit normally before results
are written. Failures clean up owned processes and emit no success report.

## First capture, 2026-10-16

Apple M5 Max, Darwin 25.6.0, Metal, RelWithDebInfo/no sanitizer, voice built on,
station built off. [Raw system report](benchmarks/2026-10-16-bmux-system.json).
Twenty startup samples after one warmup, fresh separate homes as defined above:

| Startup boundary | p50 | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Server spawn to healthy | 169.864 ms | 259.802 ms | 406.193 ms |
| Studio spawn to terminal present | 815.186 ms | 989.609 ms | 994.661 ms |
| Full server/setup/Studio start | 1011.669 ms | 1352.467 ms | 1405.999 ms |

Three five-second idle windows per scenario; RSS and CPU entries below are the
median role values. All N PTYs/views were resident/attached; one was visible.

| Panes | Server RSS | Studio RSS | PTY RSS sum | Server CPU | Studio CPU | PTY CPU sum |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 28.047 MiB | 165.109 MiB | 1.375 MiB | 0.053% | 0.875% | 0% |
| 10 | 40.203 MiB | 184.422 MiB | 13.750 MiB | 0.053% | 0.823% | 0% |
| 100 | 137.719 MiB | 321.047 MiB | 137.531 MiB | 0.053% | 0.884% | 0% |

Full-policy socket health, 1000 samples after 100 warmups per scenario:

| Panes | p50 | p95 | p99 | Maximum |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0.654 ms | 1.257 ms | 11.570 ms | 32.465 ms |
| 10 | 0.657 ms | 1.226 ms | 16.328 ms | 27.571 ms |
| 100 | 0.644 ms | 1.332 ms | 10.068 ms | 16.852 ms |

A sequential [current-build input capture](benchmarks/2026-10-16-studio-key-present-system.json)
recorded 200 RGB-validated key/presentation samples after 20 warmups: p50
2.844 ms, p95 19.167 ms, p99 23.127 ms. Subsequent validation readback was
0.701 ms median / 11.719 ms p99. Its controlling viewport was 172x34; the resource
scenario above intentionally retains read-only 80x24 fixtures. The earlier
BMUX-101 capture remains in the ledger as historical data. Single-run tail
variation does not establish a causal regression or improvement.

These measurements establish no cmux/Ghostty advantage. First-use startup and
full-policy RTT exceed the provisional 100 ms / 100 us targets. Shared initialized
home startup, matched application baselines and final budgets remain required
before performance claims. BMUX-11 owns comparative baselines.
