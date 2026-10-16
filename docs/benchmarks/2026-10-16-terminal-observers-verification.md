# Shared terminal observers (BMUX-88)

The server registry brokers up to eight trusted readiness listeners per terminal
through one native watcher. Attachments use the named `attachments` subscription;
Fleet owners can add their own listener without stealing it. A failed listener
is removed with a bounded diagnostic while other listeners remain active.

`tests/terminal_observers.lua` uses an actual shell, native attachment stream and
controlled Boggart child. It covers initial deferred delivery, shared updates,
subscriber failure/replacement, reader detach, idle behavior, subscriber bounds,
last unsubscribe, exactly-once final release and closing an owner from its release
callback. Shutdown rejects new owners from callbacks and releases channel watches.
The trusted open bootstrap establishes actual private IPC; public terminal options
continue to reject `control=true`.

The first new fixture used a local variable named `error`, shadowing Lua's error
function. The diagnostic assertion exposed this fixture mistake; renaming it
allowed the intended callback-error case to execute.

Normal and ASAN/UBSAN builds passed. The seven existing registry/server/push/watch/
attachment/client cases passed in `build/bmux-terminal-observers-tests.log` and
its sanitizer counterpart. The corrected new fixture passed in
`build/bmux-terminal-observers-recheck.log` and
`build-asan/bmux-terminal-observers-recheck.log`. Diff checks passed.

This supplies the observer/bootstrap seam for BMUX-87. Server agent launch,
network Fleet snapshots/control and attached-client agent views remain that
following increment.
