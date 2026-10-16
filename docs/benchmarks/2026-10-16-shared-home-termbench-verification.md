# BMUX-105: production home profiles

The first BMUX-102 capture (`f833cf9`) used fresh separate server/Studio homes.
That includes two first-run databases and must not be labeled ordinary process
restart cost. The harness now defaults to a private shared home initialized by
the excluded warmup, with fresh processes and fresh named Bmux sessions each
trial. A separate same-user first-use profile creates one new shared home per
pair. The historical separate-home profile remains explicitly selectable.

Studio reports its actual HOME/store path; the parent compares the resolved
store with the requested shared/per-process store. Source and binary hashes
remain in every report. No real user home/config/credentials are reused.

Verification:

- Normal final shared-home CTest **2/2**, 9.29 s,
  `build/bmux-system-shared-home-verified.log`.
- ASan/UBSan final shared-home CTest **2/2**, 12.88 s,
  `build-asan/bmux-system-shared-home-verified.log`.
- Complete real Metal initialized-home capture: exit **0**, 20 measured starts
  after one warmup, actual **1/10/100** attached PTYs/views, three five-second
  CPU/RSS windows each, 1000 RTT samples after 100 warmups each.
  `build/bmux-system-shared-real-sdl.log`;
  [raw report](2026-10-16-bmux-system-shared.json).
- Complete real Metal first-use shared-home startup-only capture: exit **0**,
  20 measured starts after one warmup; resource data is deliberately empty and
  `startup_only=true`. `build/bmux-system-shared-new-real-sdl.log`;
  [raw report](2026-10-16-bmux-startup-shared-new.json).
- Independent JSON checks confirm profile identities, actual shared store
  paths, all startup timestamps/first RGB pixels, resource/PTY counts and
  nearest-rank RTT quantiles. Capture source/binary identity checks passed.
- Original `separate-new` profile: two fresh process pairs (one warmup, one
  sample), dummy SDL startup-only smoke exits **0**;
  `build/bmux-system-separate-profile-smoke.log`.

Real captures ran sequentially with builds/tests stopped. Definitions, actual
figures and limitations are in [system termbench](../termbench-system.md).
Initialized-home full startup measured 788.129 ms median; Studio's own startup
was 685.566 ms median. This identifies the next profiling target, not a proven
cause or comparative performance advantage. The elevated one-pane Studio
CPU/RSS cohort is retained and explicitly flagged for profiling.
