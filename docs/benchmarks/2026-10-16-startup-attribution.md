# BMUX-106: Studio startup attribution

The final trace isolates the largest interval **after the first ordinary frame
and before the join coroutine begins**: median 397.779 ms. Joining the layout
then takes 12.750 ms median. This identifies startup background work/coroutine
scheduling as the next investigation; it does not prove which coroutine or
native call causes the delay. Renderer initialization is 8.106 ms median.

## Reproduce

Build normally, finish normal/sanitizer checks, then run the command in
[system termbench](../termbench-system.md) with:

```sh
BMUX_SYSTEM_HOME_PROFILE=shared-existing
BMUX_SYSTEM_STARTS=20
BMUX_SYSTEM_STARTS_ONLY=1
BMUX_SYSTEM_STARTUP_TRACE=1
```

Pass these as environment variables to the documented command. The native
`BOGGART_STUDIO_STARTUP_TRACE=1` is forwarded only to Studio. It prints fixed
phase names and `uv_hrtime` timestamps to stderr. The callback is captured by
the bootstrap and removed from globals before loading core. Ordinary sessions
perform no phase clock reads or trace writes. Benchmark-only wrappers capture
the first step, begin/end draw, presentation and join milestones; each first-step
or begin-frame wrapper restores the original function immediately.

The coordinator checks exact C phase ordering/completeness, timestamps inside
spawn-to-present, and benchmark milestones inside the observed process lifetime.
Raw stamps and source/binary hashes are in the
[final report](2026-10-16-bmux-startup-phases.json). Clock/stderr/probe overhead
perturbs startup; these are attribution results. The uninstrumented BMUX-10
captures remain the latency baseline. Spawn-to-main includes process launch and
loader work; it is not a pure loader measurement. First presentation refers to
the SDL API boundary with RGB validation, not physical scanout.

## Final real Metal capture

Apple M5 Max, Darwin 25.6.0, RelWithDebInfo, no sanitizer, twenty fresh processes
after one excluded warmup, initialized private shared home. No builds, tests or
stack sampling ran during this final capture. Exit 0;
`build/bmux-profile/startup-phases-complete.log`.

Studio spawn-to-terminal present: **686.551 ms p50, 785.393 ms p95**, maximum
787.936 ms. Independent phase quantiles below do not add to the total quantile.
Every interval includes the preceding phase's trace-write overhead.

| Interval ending at | p50 | p95 |
| --- | ---: | ---: |
| main entry, from parent spawn | 7.632 ms | 8.869 ms |
| SDL video initialized | 54.110 ms | 58.625 ms |
| window created | 33.068 ms | 36.776 ms |
| renderer initialized | 8.106 ms | 13.652 ms |
| native libraries opened | 1.001 ms | 3.539 ms |
| agent harness booted | 35.756 ms | 41.984 ms |
| assets registered | 0.030 ms | 2.494 ms |
| core required | 0.907 ms | 1.073 ms |
| core initialized | 58.316 ms | 73.769 ms |
| event loop entered | 0.025 ms | 2.167 ms |
| first validated terminal present | 489.066 ms | 567.524 ms |

| Finer interval | p50 | p95 |
| --- | ---: | ---: |
| event-loop entry to first step | 0.010 ms | 0.017 ms |
| first step to first begin-frame | 6.447 ms | 9.109 ms |
| first begin-frame to end-frame entry | 14.505 ms | 14.838 ms |
| first end-frame call | 10.188 ms | 11.319 ms |
| first end-frame return to join coroutine's request | **397.779 ms** | **431.847 ms** |
| join request through callback | 12.750 ms | 21.217 ms |
| join callback to validated terminal present | 48.081 ms | 99.001 ms |

This first frame is the normal initial Studio frame, before the terminal join.
End-frame includes presentation/cache work. The long post-frame interval
includes intervening frames and startup threads, so it must not be labeled
socket latency, pure sleep, or a particular subsystem without further evidence.
The next change should isolate cooperative scheduler/startup-thread attribution
and retain this same uninstrumented benchmark. An SDL/Metal replacement is not
supported by these measurements.

## Native stack samples and the earlier CPU anomaly

The [sampled workload report](2026-10-16-bmux-sampled-system.json) preserves the
pre-trace executable/source identities (`9267a4b` harness) and known PIDs. Its
one-pane Studio CPU windows were **1.099%, 1.326%, 0.959%** of one CPU, with five
seconds per window. The five-second
[idle sample](profiles/2026-10-16-idle-one-pane.sample.txt.gz) targets Studio PID
24052 from that report. Its main thread has 2606/2640 sampled stacks in
`f_wait_event`; the uv bridge waiter is mostly in `poll`. These include sleeping
stacks and are not CPU-time percentages. They do not reproduce or explain the
previous 7.290% cohort, which remains preserved in the BMUX-105 report.

Commands used (PIDs were verified as owned before attaching):

```sh
/usr/bin/sample boggart-studio 1 1 -wait -mayDie -file startup-warmup.sample.txt
/usr/bin/sample 24052 5 1 -mayDie -file idle-one-pane.sample.txt
/usr/bin/sample boggart-studio 1 1 -wait -file startup-metal.sample.txt
```

The first startup attempt produced an
[empty call graph](profiles/2026-10-16-startup-empty.sample.txt.gz) when the
short-lived process ended; it is not usable attribution. Retrying without eager
symbol loading captured the excluded warmup of an intermediate milestone run,
PID 39440, with the same native Studio binary as the final trace. The
[Metal startup sample](profiles/2026-10-16-startup-metal.sample.txt.gz) contains
Lua execution, subprocess launch and libuv/kevent waits. Its short, partial
startup coverage and unresolved Lua frames do not identify a specific startup
thread. It was not collected during the final twenty-sample capture. Intermediate
phase reports are retained compressed under `profiles`; only the final report
has all step/draw milestones and the current helper source identity.

## Verification and unresolved failure

- Initial C instrumentation/accounting/probe checks: normal **3/3**, 20.90 s;
  ASan/UBSan **3/3**, 22.65 s. Logs:
  `build{,-asan}/bmux-startup-trace-verified.log`.
- Final milestone/accounting/full 1/10/100-pane workflow: normal **2/2**,
  11.69 s; ASan/UBSan **2/2**, 23.83 s. Logs:
  `build{,-asan}/bmux-startup-final-verified.log`.
- An intermediate ASAN run failed: only **65/100** attachments became live;
  others hit the normal five-second control deadline. The
  [failure log](profiles/2026-10-16-asan-100-pane-deadline.log) and
  [stalled-process sample](profiles/2026-10-16-asan-stalled-100-pane.sample.txt.gz)
  are retained. That sample targets ASAN PID 34834 about 29 s after launch,
  not initial startup. It is not the Metal startup profile. Subsequent ASAN
  workflow plus focused 100-connect burst passed **2/2**, 18.53 s;
  `build-asan/bmux-startup-burst-recheck.log`.
- **BMUX-107 remains open** for the intermittent attachment deadline. The
  passing recheck does not establish a fix. No deadlines were enlarged and no
  measured requests were silently retried.

Matched cmux/Ghostty baselines and final numeric budgets remain BMUX-11. Neither
application was found in `/Applications`; no comparison is inferred from that
absence or from these Boggart-only measurements.
