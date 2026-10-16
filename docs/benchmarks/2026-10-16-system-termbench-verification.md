# BMUX-102 verification

- Native process sampler, strict C11 `-Wall -Wextra -Werror` syntax check: pass.
- Normal focused suite **8/8**, 11.09 s, and ASan/UBSan **8/8**, 16.32 s:
  `build/bmux-system-and-burst-verified.log` and the matching `build-asan` log.
  These include the CPU timebase self-check, accounting, actual 1/10/100 PTY and
  Studio attachment workflow, native burst and teardown regressions.
- Final startup accounting smoke: normal **2/2**, 7.85 s; ASan/UBSan **2/2**,
  13.68 s, `build{,-asan}/bmux-system-final-smoke.log`.
- Additional normal-exit enforcement: ASan/UBSan **1/1**, 15.14 s,
  `build-asan/bmux-system-normal-exit-verified.log`.
- A longer real startup sweep exposed socket bind preceding listen readiness at
  trial 13; the incomplete run exited 1 and emitted no success report. Health
  readiness now retries only safe startup probes, including all retry time in
  startup. The timed RTT path remains single-request/no-retry. Final readiness
  smoke: normal **2/2**, 9.90 s; ASan/UBSan **1/1**, 13.63 s,
  `build{,-asan}/bmux-system-readiness-verified.log`.
- Complete real Metal system capture: exit **0**, 20 measured fresh-process
  starts after one warmup, all **1/10/100** PTYs/views attached, three five-second
  idle windows per scenario, **1000** RTTs after 100 warmups per scenario.
  `build/bmux-system-real-sdl.log`; [raw report](2026-10-16-bmux-system.json).
- Sequential real Metal key/presentation refresh: exit **0**, **200/200**
  RGB-validated samples after 20 warmups, `build/bmux-latency-system-real-sdl.log`;
  [raw report](2026-10-16-studio-key-present-system.json).
- Independent JSON checks passed for all process counts/roles, lifetime tokens,
  per-PID CPU/RSS arithmetic and intervals, startup timestamp differences,
  nearest-rank RTT p99, and every input pixel/timestamp/latency and input p99.

No builds/tests ran concurrently with either final real-renderer capture.
See [measurement definitions and limits](../termbench-system.md): the first
startup profile uses fresh separate homes/databases and warm filesystem caches;
it does not stand in for initialized shared-home restart time or physical
display scanout. Comparative cmux/Ghostty results remain outstanding.

This work found and verified two product fixes: [BMUX-103 pending transport
teardown](2026-10-16-transport-shutdown-verification.md), commit `8c98496`, and
[BMUX-104 pane-join bursts](2026-10-16-control-burst-verification.md), commit
`d294edb`.
