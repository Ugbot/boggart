# BMUX-107: bound initial attachment demand

The reproduced timeout came from submitting 100 snapshot requests together to a
serial server. Each request's five-second network deadline started immediately.
Under ASAN, the server took 8.965 seconds across those 100 handlers; later requests
expired while waiting for server work. The client counters show zero response
bytes on the failed requests, rather than a partial-body or replay-parser stall.

The current-source reproduction failed on its first run, with 73/100 live panes
([log](profiles/2026-10-16-attachment-deadline-reproduced.txt)). Earlier failures
at 65 panes were not a fixed connection cap. A diagnostic run preserved the normal
policy, evidence, named SQLite journal and native UDS transport. Its
[server trace](2026-10-16-attachment-server-before.json) records 100 attachment
handlers at 89.645 ms mean (42.697 ms capture, 0.072 ms expiration); the remainder
includes normal admission/evidence and route work. The
[client trace](2026-10-16-attachment-client-before.json) and
[diagnostic failure](profiles/2026-10-16-attachment-diagnostics-before.txt)
preserve that separate capture. These are instrumented diagnostic observations,
not latency budgets or competitive measurements.

## Change and ownership

Each joined Studio layout owns one FIFO admitting **four initial handshakes**,
with **256 total outstanding tickets**, including active ones. A slot covers the
initial snapshot, validated first stream event and native image publication.
Extra views report `queued`. Established streams, input, resize, controller
leases, Fleet commands and other control requests do not use the queue.

`terminal.attach_queue` owns bounded FIFO/accounting and reentrant completion.
The Remote owns its transport/session: it cancels those before releasing active
admission, and releases admission on success, failure, stale epoch or publication
error. Layout disconnect stops new starts and rejects queued work, then closes
its views to cancel active handshakes. Queued cancellation opens no socket.
Standalone Remote callers can omit the admission object and retain their prior
behavior. Every admitted network request still has its normal **5000ms** deadline;
no connection cap, authorization rule, evidence capture or persistence setting
was relaxed. Total time waiting in the admission queue is separate from that
network deadline and may exceed five seconds for a large layout.

## Deterministic native regression

The private diagnostic server overlay can add an explicit **60ms per capture**
delay, including capture calls during initial stream setup. With 100 panes this
forces more work than an unpaced five-second burst can complete. The original
code fails with this load
([before log](profiles/2026-10-16-attachment-paced-before.txt)); both normal and
ASAN candidate runs pass while keeping the production network deadline.
The permanent CTest is `termbench_attach_burst`:

```sh
ctest --test-dir build -R '^termbench_attach_burst$' --output-on-failure
ctest --test-dir build-asan -R '^termbench_attach_burst$' --output-on-failure
```

This is correctness under synthetic load, not a product speed measurement.
Ordinary `termbench_system` has no injected delay or diagnostic overlay.
`BMUX_SYSTEM_DIAGNOSTICS=1` enables bounded client/server request counters and
durations in private benchmark homes. `BMUX_SYSTEM_ATTACH_DELAY_MS` accepts
0–1000 integer milliseconds and requires diagnostics. These flags do not modify
user homes or product defaults. Traces retain paths, byte/event counts and
clocks, never request bodies, authorization tokens or terminal payloads. Caps
are 512 records per process; request count/truncation are explicit in new traces.
The server saves its trace during normal stop; client trace is saved on ready
or failure. Source/build identities remain in the coordinator report.

## Verification

- Queue/Remote unit coverage: FIFO/capacity, idempotent finish/close, queued and
  active cancellation, synchronous completion, failed starts, throwing rejection
  callbacks, image-publication failure and stale callbacks while a successor
  owns admission. A 100-Remote fixture never starts more than four handshakes.
- Native transport/control/layout/Fleet verification: **13/13 normal, 42.40s**;
  **13/13 ASAN/UBSan, 76.80s** in
  the retained [normal](profiles/2026-10-16-attachment-verified-normal.txt) and
  [ASAN](profiles/2026-10-16-attachment-verified-asan.txt) logs. This includes ordinary 1/10/100-pane
  workflow, actual remote controls, session handling and server-backed agents.
- Initial paced 100-pane run passed normal **22.68s**, ASAN **33.20s**;
  `build{,-asan}/bmux-107-paced-after.log`.
- Final permanent paced regression, measurement accounting and queue edge cases
  passed **3/3 normal, 26.93s** ([log](profiles/2026-10-16-attachment-paced-normal.txt)).
- Five consecutive unmodified-load ASAN `termbench_system` runs passed
  (35.58s, 34.02s, 26.14s, 31.75s, 33.20s), including all 100 attachments each
  time. The queue unit also passed five consecutive runs. Combined elapsed
  time was 162.97s ([log](profiles/2026-10-16-attachment-asan-repeated.txt)).

Two registered paced ASAN runs completed all 100 attachments, then failed the
resource sampler because a fixture child had died before exec. Its macOS crash
report identifies ASAN StackStore/calloc through `_notify_fork_child` and
`os_unfair_lock` corruption, explicitly on the child side of fork before exec.
This separate native-spawn failure is tracked as **BMUX-109**; the sampler still
rejects dead owned PIDs. The [failed run](profiles/2026-10-16-attachment-paced-sampler-failure.txt),
[metadata-only crash excerpt](2026-10-16-attachment-paced-fork-crash.json) and
[client trace](2026-10-16-attachment-client-sampler-failure.json) are retained.
The latter contains 100 successful snapshots and 100 first stream events, with
zero client errors. This failure is included in the evidence, not counted as a
passing resource measurement. The unchanged recheck also rejected a dead owned
PID ([log](profiles/2026-10-16-attachment-paced-sampler-recheck.txt)); it was not
rerun until green. Its [readiness](2026-10-16-attachment-ready-after-asan.json),
[client](2026-10-16-attachment-client-after-asan.json) and
[server](2026-10-16-attachment-server-after-asan.json) records are retained.

The subsequent [BMUX-109 launch fix and verification](2026-10-16-pty-spawn-verification.md)
resolves that separate fork-child failure. It records three consecutive passing
paced ASAN workflows, including all owned fixture PIDs in resource sampling.

The final normal [coordinator report](2026-10-16-attachment-paced-normal.json),
[client trace](2026-10-16-attachment-client-after-normal.json) and
[server trace](2026-10-16-attachment-server-after-normal.json) preserve the
passing full workflow. An independent [trace audit](profiles/2026-10-16-attachment-audit.txt)
matches each snapshot start to its terminal's first stream event and sweeps
those intervals: both normal and ASAN peak at exactly four concurrent
handshakes, end at zero, and complete 100 snapshots/first events without errors.
It also verifies complete traces, frame color and recorded current file hashes.
The [audit script](profiles/2026-10-16-attachment-audit.lua) can be run from the
repository root with `BOGGART_HOME=/tmp/bmux-audit ./boggart --eval
docs/benchmarks/profiles/2026-10-16-attachment-audit.lua` against the captured
build identities. Embedded ASAN assets are identified through the built binary
in ordinary coordinator runs; this failed run's readiness audit checks its
recorded native/renderer source fingerprints and does not invent a coordinator
report after resource sampling failed.

The full-policy snapshot path remains expensive under ASAN. This fix bounds
demand and preserves deadlines; it does not claim to reduce server capture CPU,
meet the provisional RTT/startup budgets, or establish cmux/Ghostty superiority.
