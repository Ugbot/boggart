# Process-learning implementation progress

The active programme is [the full implementation plan](superpowers/plans/2026-09-21-boggart-process-learning.md),
tracked in devtools as **BRAIN-1**. This record contains verified implementation
work, not future promises. Tracker criteria and commit links are the execution
status authority.

## Completed on 21 September 2026

| Ticket | Change | Verification | Commit |
|---|---|---|---|
| BRAIN-11 | Restrictive immutable policy scopes and corrected legacy override precedence | Fresh native build; policy 36 checks, perm 81 checks, front suite; independent review approved | `8d38645` |
| BRAIN-12 | Shared SQLite quota reservation, reconciliation, restart and clock protection | Rebuilt-binary quota 52 checks and policy 36 checks; real writer and commit lock contention; independent review approved | `3623844` |
| BRAIN-13 | Common invocation gate across nested tools, CLI/cTUI, Studio and child agents; coroutine authority/budgets, structured results and single accounting | Full rebuilt-binary Lua suite 59/59; invoke 87 checks; CTest invoke repeated twice; independent review approved | `15198f9` |
| BRAIN-14 | Verifier failures propagate, cleanup remains visible, and nested tool/event budgets survive resets and caught errors | Rebuilt-binary callable 35, skills 95, luatool 42 and events 128 checks; independent review approved | `2c79885` |
| BRAIN-15 | Failed reload restores worker/module bindings and event registrations; session listing uses the actual store API and exposes errors | Rebuilt-binary lifecycle 114 checks, sessions 39 checks, real HTTP control 33 checks; independent review approved | `1470254` |

Build: `cmake --build build --target boggart -j 6` with `CCACHE_DIR` and
`CCACHE_TEMPDIR` pointing inside `build/ccache`, because the default cache
directory is outside the workspace sandbox. Tests ran through `./boggart
--eval tests/<suite>.lua`, each with an isolated temporary profile. No paid
model requests or real messaging workflows were used.

The existing user changes to judge/TypeSafe, models and completion were
preserved outside these commits. BRAIN-17 is implementing versioned capability
contracts next. Local control authentication and unattended-default hardening
remain open as BRAIN-16.

The broader 57-suite run passed 53 suites on its first pass. MCP and control
needed loopback permission for their mock servers; permitted reruns passed
72 and 33 checks. Events and luatool were rerun after the reviewed sticky-budget
fix was embedded and passed 128 and 42 checks. The subsequently registered quota
suite passed another 52 checks. This is combined suite evidence, not a claim
that one uninterrupted 58-suite command ran green. GUI interaction and other
platform qualification remain open programme work.

The final BRAIN-13 build passed all 59 registered Lua suites in one uninterrupted
run using isolated profiles and permitted loopback mock servers. `invoke` then
passed twice under CTest's reused test profile after its quota fixture changed
to a unique temporary database. Voice transcription was skipped because its
model was absent; the suite verified the clean missing-model behavior. Studio
coverage uses the existing stub-window harness, not a real GUI session. This
build includes the preserved user work and is not a clean-checkout release
qualification.
