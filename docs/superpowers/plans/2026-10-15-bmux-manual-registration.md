# Manual agent registration

BMUX-66 builds on BMUX-36/39. Add a private Unix socket to the existing bounded
C HTTP transport and a native `boggart ctl` client before Lua startup. Keep
HTTP routes shared with `lua/control.lua`; Studio's registration listener
exposes only its narrow manual-agent routes. Socket creation requires a private
owned directory, mode0600 and same-user peers. Never unlink an existing path or
a replacement pathname during teardown. Retire native handles before luv GC.

Each BMUX shell receives the socket path plus a revocable pane ID/capability.
`boggart ctl run --provider NAME -- executable argv...` registers a process,
inherits terminal stdio, launches literal argv, heartbeats its lease, and reports
actual exit/signal status. Fleet focus targets the capability's existing pane.
Expired leases become unreachable; pane close revokes registration. PID claims
are metadata, not cancellation authority. This supplies explicit manual wrapping
for arbitrary providers without editing user dotfiles or scraping screen text.

Verify real UDS requests/TCP compatibility, permissions, origin/token/peer rules,
collision/replacement handling, GC/exit lifetime and limits. Verify actual shell
wrapping, foreign commands, exit/failure/interrupt, stale/cross-pane contexts,
heartbeat loss and close revocation through the existing Fleet. Check normal,
sanitizer and real SDL behavior, measure UDS RTT separately from process startup,
record remaining benchmark/CLI/hook work, then commit and push.

Provider-specific hooks, all control verbs/completion, persistent server-owned
terminals and reconnect remain the broader BMUX roadmap. This listener belongs
to the running Studio; it is not a detach/reattach implementation.
