# BMUX-108: responsive project indexing

The initial project scan blocked one UI coroutine for hundreds of milliseconds.
The scanner now builds a replacement graph/list in short cooperative slices,
retains the previous published list, and swaps in the complete result. Root,
working-directory and list-owner changes cancel staged work. A reconciliation
pass after watch installation catches files changed during the traversal; it
also stops before writing into a changed project owner.

Checkpoints consider elapsed time every 32 traversal operations and yield after
2 ms or 128 operations. This is not a hard 2 ms frame bound: one filesystem call,
Lua sort, watch transition or other native work cannot be preempted. Existing
small incremental refreshes retain their previous behavior. Reconciliation adds
metadata I/O and staging temporarily retains both graphs. Total indexing CPU,
completion time and post-change resource scaling are not established by the
startup-only comparison below. First terminal readiness can precede a published
project index; traversal and watcher maintenance continue in the background.

## Controlled comparison

Apple M5 Max, Darwin 25.6.0, Metal, RelWithDebInfo/no sanitizer. Twenty fresh
server/Studio process pairs after one excluded warmup, per side; initialized
private shared home, fresh named Bmux session, real 80x24 PTY, same project and
1000x800-point window. No startup/coroutine tracing in these timing runs. No
builds, tests or stack profilers ran concurrently. Ordinary desktop activity was
not pinned or eliminated; captures ran before then after, without randomized
order. These are this workload's measurements, not a universal speed guarantee.

To control the change, both sides use the **same copied native executable** and
same asset tree under `/tmp/bmux-compare.nIzuxu`, with only `data/core/init.lua`
changed between sides. The old source comes from `43ba29c`; the new source is
this change. The identical executable contains embedded assets, but the explicit
filesystem data tree takes precedence. `diff -rq` confirmed only the scanner
source differed before the substitution. The parent records and validates the
actual child core source and bundled font hashes, alongside the shared native,
helper, sampler and build identities. OS-selected fallback faces are not
fingerprinted. See the [before report](2026-10-16-bmux-project-scan-before.json)
and [after report](2026-10-16-bmux-project-scan-after.json).

Run the documented [system command](../termbench-system.md) with
`BMUX_SYSTEM_STUDIO` pointing to the isolated copy,
`BMUX_SYSTEM_HOME_PROFILE=shared-existing`, `BMUX_SYSTEM_STARTS=20`, and
`BMUX_SYSTEM_STARTS_ONLY=1`. Leave both trace options unset. Copy the asset tree
and native executable once, restore the old core with
`git show 43ba29c:studio/data/core/init.lua`, capture, then replace just that file
with the current source and capture again. Use separate output JSON files.

| Uninstrumented boundary | Before p50 | After p50 | Before p95 | After p95 |
| --- | ---: | ---: | ---: | ---: |
| Studio spawn to terminal present | 714.057 ms | **343.135 ms** | 1129.969 ms | 437.675 ms |
| Full server/setup/Studio start | 893.914 ms | **506.208 ms** | 1283.075 ms | 651.032 ms |

Studio median readiness is **51.95% lower** in this matched capture. This is an
interactive-readiness improvement, not completed-index startup or reduced total
work. Full startup still exceeds the provisional 100 ms target. No cmux/Ghostty
comparison or physical display latency is claimed. Final capture logs:
`build/bmux-profile/scan-before.log`, `build/bmux-profile/scan-after-final.log`;
both exit 0. Independent checks pass for all 20+20 clocks/RGB pixels, actual
old/new core hashes, identical common binary/helper/build/font hashes and
nearest-rank quantiles.

## Attribution and correctness

`BMUX_SYSTEM_COROUTINE_TRACE=1` requires `BMUX_SYSTEM_STARTUP_TRACE=1`. It records
up to 128 startup coroutine resume spans with bounded yielded stack traces,
restores the original resume function at the join callback, reports the total
count and rejects truncated captures. It is benchmark-only attribution; its
clock/stack overhead is excluded from the uninstrumented comparison above.
The [old scanner trace](2026-10-16-bmux-scan-coroutines-before.json) identifies
`project_scan_thread` taking **504.809, 453.878, 447.041 ms** in single resumes.
The [final sliced trace](2026-10-16-bmux-scan-coroutines-after.json) records the
candidate separately; these spans cover startup through the join callback,
not later indexing completion or a whole-session frame latency bound.
Its largest scanner-checkpoint resume spans are **0.798, 0.818, 1.001 ms**;
the largest resume across any captured startup coroutine is 2.089 ms. These
three attribution trials explain the removed blocking slice, not a p99 budget.

The deterministic native Studio regression uses 800 synthetic entries, actual
scanner coroutines and the normal node/list accounting. It verifies complete
sorted multi-root output, yielding before publication, root/list-owner/CWD
cancellation, changes during traversal, and owner changes during reconciliation.
It [failed before the fix](profiles/2026-10-16-project-scan-before.txt) because
the first resume published the entire list without yielding; native process
exit 1. The final regression passes in normal and ASAN/UBSan builds.

Final checks: **8/8 normal, 10.59 s**, **8/8 ASAN/UBSan, 18.54 s** in
`build{,-asan}/bmux-project-scan-final-verified.log`. These cover measurement
accounting, real 1/10/100-pane workflow, actual native input, server layout,
Fleet, RGB presentation, key-to-presentation correctness and the scanner cases.
Bounded normal and ASAN dummy-SDL coroutine/identity smokes also exit 0
(`build/bmux-profile/coroutine-smoke.log`, `build-asan/bmux-coroutine-smoke.log`). No new
intermittent attachment failure occurred in these final runs; **BMUX-107 remains
open**, and its earlier failure was not erased or treated as fixed.
