# Provider events implementation plan

Continue the approved common-Fleet design with observational Claude hooks.
C/Lua only, existing native HTTP-over-UDS client and registry. Do not edit user
provider configuration or let reports confer approval/process authority.

1. Add `lua/providerevents.lua`, a bounded observer shared by manual and managed
   adapters. `new(provider)` returns an observer with `apply(event,stamp)`,
   `poll()` and `status`; normalize only supported provider events, bind session
   identity, reject older reports and isolate subagent reports from root status.
2. Add event-only tokens to `manualfleet`: `observe(rec,pane)` creates a reporter
   for an already owned record; registration also returns an event token.
   `/bmux/agents/notify` authenticates that token separately from the wrapper
   lease. Heartbeats preserve reported phase; exit/revoke invalidate reports.
3. Native `ctl run` passes only event identity/token to its actual child, replacing
   any inherited reporter context. `ctl notify --provider claude` reads bounded
   stdin, projects safe metadata, sends an observational report and produces no
   decision/stdout. A hook failure must not block the provider.
4. Generate a private Claude plugin in `agenthooks`, inject it into automatic and
   managed Claude launches, preserve existing plugins and utility/opt-out paths.
   Verify CLI argument parsing with the installed provider; never bypass trust.
5. Wire managed TerminalView reporters into the existing Fleet adapter, preserving
   one record/owner and native process outcome precedence. Show reported status
   and attention without manufacturing prompt/approval controls.
6. Exercise pure observer/auth tests, actual native hook subprocesses, wrapper and
   launcher fixtures, malformed/oversized/stale input, process loss, and an actual
   provider hook-loader probe that does not call a model. Normal + sanitizer + SDL
   checks, then update evidence/tracker, review, signed-off commit and push.

Codex hook trust/transport differs; inspect official documentation rather than
overwriting legacy notify configuration. Other provider adapters, subagent
semantic Fleet records and approval routing remain separate work. Reports may
be delayed/missing; label them as reported activity, not current execution proof.
