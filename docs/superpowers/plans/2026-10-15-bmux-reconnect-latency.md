# Bmux reconnect latency plan

**Goal:** Remove the measured native UDS transfer bottleneck without changing
attachment validation, authorization or server ownership (BMUX-73/32).

**Evidence:** Temporary overlay probes around actual daemon invocation,
capture and handler work measured 12–20ms per attachment handler versus ~94ms
to receive the snapshot body. Per-chunk client probes found 61 reads for a
492515-byte response: 60×8192 bytes plus a 995-byte tail, separated by client
loop turns. Both local socket buffers report 8192 bytes. Raising only the
client receive buffer to 256KiB still produces 61 chunks and ~115ms attach.
Raw ignored logs: `build/reconnect-probe-{baseline,chunks,recv}.log`.

**Design:** Request 256KiB kernel send/receive buffers on authenticated accepted
native UDS connections and on the connected native client before reading or
writing. These are best-effort performance hints; OS clamping/refusal keeps
the transport usable. TCP behavior, peer checks, Content-Length/SSE framing,
application queue/frame limits and independent attachment semantics stay as
defined in the current protocol. No polling or bypass of policy/evidence.

Primary reference: [libuv buffer sizing](https://docs.libuv.org/en/v1.x/handle.html#c.uv_send_buffer_size)
supports TCP/pipe/UDP on Unix and notes Linux may return twice the requested
size. Do not assert a universal exact kernel allocation/RSS value.

- [x] Extend `tests/terminal_client.lua` with opt-in `BMUX_RECONNECT_GATE=1`:
  assert both fresh attach through first validated stream replay and actual
  kill/reap/rejoin below 50ms. Capture the pre-fix failure.
- [x] Tune only accepted UDS handles in `src/lserve.c` after same-user peer
  verification; tune the connected client pipe in `lua/terminal/transport.lua`.
  Build normal; measure the same actual daemon fixture and response chunks.
- [x] Add a reproducible bounded probe fixture for server/client phase and
  chunk diagnostics. Compare baseline/fixed observations without logging
  request bodies, secrets, full screen data or skipping policy/evidence.
- [x] Run serial normal gate samples, normal and sanitizer transport/server/
  attachment/client regressions, C11 warning/attribution/diff checks. Sanitizer
  performance is reported separately; correctness must pass both builds.
- [x] Document measured results/limits in
  `docs/benchmarks/2026-10-15-reconnect-latency.md` and its JSON samples. Eight
  serial strict normal samples and both 26-suite regression sets pass.

Landing follows the user's standing commit/push instruction. Parent criterion
1450 can be linked and recorded from the eight strict actual-daemon samples;
Studio/cTUI attachment and the overall Bmux roadmap remain open.
