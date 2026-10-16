# BMUX-106: attribute startup before optimization

The existing Bmux plan calls for profiling Studio startup and the anomalous
one-pane resource cohort after BMUX-10 instrumentation. This increment changes
measurement only; it selects no product optimization or performance budget.

1. Sample the actual Metal server/PTY/Studio workload with macOS `sample`, using
   only owned PIDs. Keep sampling separate from uninstrumented latency gates.
   If short-lived startup exits before usable stacks, preserve that limitation.
2. Add an opt-in C startup trace using the same `uv_hrtime` clock as the parent:
   main entry, SDL initialization, window, renderer, libraries, agent harness,
   assets, core require/init, event-loop entry. No tracing in ordinary sessions.
   Keep its Lua callback private to the bootstrap and restrict phase names.
3. Extend the existing C/Lua coordinator to preserve phase timestamps and deltas
   through the validated first terminal present. Account for spawn-to-main
   separately; it includes loader/launch costs and is not pure dyld time.
   Reject missing, duplicated, reordered or out-of-bound timestamps.
4. Verify accounting and full 1/10/100-pane workflow normally and under ASAN;
   capture initialized-home actual Metal startup attribution only after builds
   and tests finish. Preserve raw samples and source/binary identities.
5. Record attribution, failed capture attempts and remaining uncertainty.
   Uninstrumented BMUX-10 captures remain the timing baseline. The phase trace
   includes clock/stderr-write overhead; a post-loop interval includes joins,
   scheduling and first drawing, not just renderer cost.

Matched cmux/Ghostty baselines remain BMUX-11. Neither application was found in
`/Applications` during this pass; no competitor latency or memory is inferred.
