# BMUX-104: 100-pane connection bursts

The system benchmark created 100 real native PTYs and layout views, but only
65 Studio attachments became live. Remaining initial connects failed before
HTTP admission. `lserve.c` admitted up to 256 live connections while calling
`uv_listen` with a backlog of 64. This made a simultaneous pane join exceed the
accept queue even though it fit the existing live-connection budget.

The independent native test `tests/control_unix_burst.lua` queues 100 connects
before entering the accept loop. **Before the fix it failed with 36 connection
refusals** (`build/bmux-control-burst-before.log`). The backlog now uses the
existing `MAX_CONNS` bound (256). Authentication, permissions, message bounds
and the live-connection limit are unchanged; OS backlog caps still apply.

Verification:

- Normal focused CTest **8/8**, 11.09 s,
  `build/bmux-system-and-burst-verified.log`.
- ASan/UBSan focused CTest **8/8**, 16.32 s,
  `build-asan/bmux-system-and-burst-verified.log`.
- Native burst: all **100/100** connections receive a valid health reply.
- Full system smoke: **1/10/100** actual resident PTYs and attached Studio
  views reach readiness; one pane is visible via zoom. The native per-PID
  sampler observes the server, Studio and every fixture process. Each Studio
  client disconnects and exits normally (BMUX-103 regression retained).

Suites: `termbench_measure`, `termbench_sample`, `termbench_system`,
`control_unix`, `terminal_transport_shutdown`, `terminal_transport_workers`,
`control_unix_burst`, `studio_transport_shutdown`.

The smoke uses dummy SDL, short intervals and three RTT samples. These results
prove workflow/capacity correctness, not production performance or cmux parity.
BMUX-102 retains the full real-renderer measurement gate.
