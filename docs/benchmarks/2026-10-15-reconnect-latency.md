# Native Bmux reconnect latency — BMUX-73

The BMUX-32 normal-build protocol gate now passes in eight predeclared serial
samples: **28.279–41.692ms** from a fresh attachment request through validated
first stream replay, and **31.715–46.352ms** including killing/reaping the old
client and creating the replacement attachment. Every sample asserts both
durations below 50ms and verifies the same native PID, exact screen/scrollback
and synchronized independent viewers.

This is the native attachment protocol, not an attached Studio/cTUI view or
durable server restart. Those remain separate roadmap work. Measurements below
exclude application bootstrap from the protocol gate; complete cold-process
startup/file readiness is recorded separately and remains above 50ms.

## Cause and fix

At baseline `a5ff9f0`, the actual daemon's attachment handler takes about 12–20ms
including policy/evidence and native snapshot construction, while the client
waits about 94ms for the complete body. Probes around each client parser feed
found a 492515-byte response delivered in **61 reads**: 60×8192 bytes plus a
995-byte tail, mostly one per client loop turn. Both connected local socket
buffers report **8192 bytes** on this macOS host. Parser work on intermediate
chunks is only microseconds. The unchanged integration loop sleeps 1ms between
nonblocking pumps; small socket buffers force many extra turns. A frame-driven
client would also pay for those extra turns.

Increasing only the client receive buffer to 256KiB still produced 61 chunks
and 114.708ms attachment readiness. The candidate fix raises small buffers in
**both directions at both ends** using existing libuv calls: accepted native
UDS handles after same-user peer verification, and the connected Lua/libuv
client pipe before read/write. The requested size is 256KiB; existing larger
settings are preserved, and OS refusal/clamping is best-effort. This does not
change authentication, policy/evidence, framing, the 4MiB attachment frame cap,
the 8MiB queued-write bound or the transport's explicit deadline/lifecycle.
TCP socket settings and vendored libuv/luv are unchanged.

The same response then arrived in **8 reads**, seven 65536-byte chunks and one
33763-byte tail, across about 0.93ms of chunk arrivals. Both client buffers
reported 262144 bytes. A traced full run measured 34.284ms attachment readiness
and 35.475ms including client death/reap. Server capture and admission still run.
Nested server probe durations must not be summed as independent stages.

Primary API reference: [libuv send/receive buffer sizing](https://docs.libuv.org/en/v1.x/handle.html#c.uv_send_buffer_size),
which supports Unix pipe sockets and notes Linux reports doubled sizes. These
are requested kernel capacities, not portable exact allocations or RSS claims.

## Strict gate results

macOS arm64, existing normal build, eight serial runs selected in advance.
No concurrent build/sanitizer job from this session ran during this batch.
The host was shared; eight samples do not establish a general p99 guarantee.
All runs use the same actual-daemon fixture: 80×24 screen, native history
capacity 128, full nonempty 32-row attachment tail (4480 cells), 64 styled
Unicode initial lines, explicit controllers, dropped/malformed/post-effect-500
command responses, SIGKILL of an independent client process, resize/reflow,
multiple viewers and native exit/EOF. No fixture geometry or polling interval
was reduced to meet the target.

| Sample | Attach + validated replay | Kill/reap + rejoin |
| --- | ---: | ---: |
| 1 | 32.292ms | 33.916ms |
| 2 | 28.788ms | 32.806ms |
| 3 | 32.964ms | 42.317ms |
| 4 | 41.692ms | 46.352ms |
| 5 | 33.277ms | 34.712ms |
| 6 | 34.144ms | 44.347ms |
| 7 | 28.279ms | 31.715ms |
| 8 | 30.605ms | 35.902ms |
| Median | **32.628ms** | **35.307ms** |

Complete cold-process spawn through ready-image-file time was 94.332–215.679ms;
protocol work inside those new client processes was 26.427–28.600ms. Those
different boundaries are not substituted for the strict killed-client gate.
Machine-readable samples, source hashes and measurement boundaries:
[`2026-10-15-reconnect-latency.json`](2026-10-15-reconnect-latency.json).

The pre-fix strict test failed at 105.257ms attach/replay and 107.541ms
kill/rejoin (`build/reconnect-latency-red.log`). The first traced fixed run
passed (`build/reconnect-latency-green.log`). All eight serial raw logs are
ignored `build/reconnect-gate-1.log` through `-8.log`; no failed sample was
discarded/replaced from that batch.

## Verification and reproduction

Normal regressions: **26/26, 30.91s**. ASan/UBSan: **26/26, 34.86s**. These
include server/client/registry/process/watch/attachment transport, UDS/token
checks, targeted/global SSE isolation, slow-consumer closure at the unchanged
queue cap, malformed frames, cancellation, Fleet/provider/keyboard integration
and native Studio Bmux behavior. Sanitizer protocol timing was 103.732ms attach
and 110.169ms including client death/reap; sanitizer correctness passes, while
the performance gate is explicitly the normal profile.

A separate 1000-sample (100 warmup) control-health cost check observed registrar
median **14.500µs**, p99 **66.417µs**, and full-policy health median **975.500µs**,
p99 **3279.458µs**. The full-policy 100µs target remains unmet under BMUX-36.
Earlier measurements used a different host/load/store state, so these are not
a controlled attribution of the whole health-path change to socket tuning.
Raw logs: `build/reconnect-{registrar,control}-health.log`; data is also in the
JSON artifact above.

Both builds succeeded. C11 `-Wall -Wextra -Werror -fsyntax-only` for `lserve.c`,
the pinned Ghostty attribution verifier (44 modules/34 ported files) and diff
checks pass. This adds 18 product lines across C and Lua, plus test/probe/docs;
no new runtime, polling loop or subprocess HTTP client was introduced.

```sh
BMUX_RECONNECT_GATE=1 ctest --test-dir build -R '^terminal_client$' -V
BMUX_RECONNECT_GATE=1 BMUX_RECONNECT_TRACE=1 \
  ctest --test-dir build -R '^terminal_client$' -V
ctest --test-dir build-asan \
  -R '^(control_unix|serve_streams|terminal_(server|attachments|watch|push|transport|replica|client))$' \
  --output-on-failure
```

`BMUX_RECONNECT_TRACE=1` installs the test-only
[`terminal_server_probe.lua`](../../tests/fixtures/terminal_server_probe.lua)
overlay in the owned temporary daemon home and counts client chunks. It wraps
real invocation/evidence/capture/handler functions without replacing decisions.
It prints only stage labels, durations and byte counts/buffer sizes; bodies,
screen images and credentials are not logged. The initial raw temporary probes
are retained in ignored `build/reconnect-probe-{baseline,chunks,recv}.log`.
