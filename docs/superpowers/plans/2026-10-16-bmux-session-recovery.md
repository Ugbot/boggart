# Bmux explicit session recovery implementation plan

Execute inline on feature/bmux-termbench under the existing session-restore
design and BMUX-100. Preserve the original bytes; never force an owner claim.

**Goal:** Resume saving a blocked, owned session from its current in-memory
layout, with a private recoverable copy of the exact original checkpoint.

**Architecture:** Extend native SQLite compare/set with an optional owner guard
checked in the same statement. A journal preview pins original bytes, owner,
host and layout revision. Explicit confirmation writes/syncs an exclusive
private recovery file, then uses guarded CAS to replace the checkpoint. No
runtime restore, PTY restart, layout reconstruction or command replay occurs.

## Constraints

- C/Lua, existing SQLite, libuv and shared session controls.
- Preview and mutation have separate bounded native control routes. Mutation
  accepts only host/revision/preview token; it accepts no checkpoint or commands.
- Refuse unclaimed, replaced, live-rival or invalid ownership. Owner corruption
  remains blocked; choosing another session never deletes the original.
- Archive creation precedes replacement. Write/sync failures and CAS conflicts
  leave the original checkpoint intact. Archives are exclusive 0600 regular
  files in an owned private recovery directory; cap raw data at 64 MiB.
- Nil/empty/binary originals stay distinguishable through preview/receipt
  metadata; recovery files preserve raw bytes, without parsing or executing them.
- Successful recovery rebinds journal subscriptions if startup was blocked,
  resumes coalesced saving, and preserves inactive-import eligibility flags.
- No automatic mutation retry. An uncertain acknowledgement is resolved by
  status observation; the preview already identifies the recovery file path.

## Steps

- [x] Extend `repo:kv_compare_set` / `bog.store.kv_compare_set` with optional
  owner key/value guards; test absent/update/delete and stale guards across two
  actual SQLite connections, including binary expected values.
- [x] Add preview/recover journal methods and shared raw archive writing with
  fsync/ownership checks. Test corruption, missing values, owner/data/revision
  conflicts, storage failure, archive preservation and restored subscriptions.
- [x] Add authenticated preview/recover routes and strict shared native client
  contracts. Keep host pinning and uncertain-write behavior; expose archive
  information through status after the explicit action.
- [x] Add a clearly worded recovery preview/confirmation in Studio Sessions and
  native Ctrl-B e. Show saved session name, original bytes, archive path and
  that the current layout will become the checkpoint. Escape performs no write.
- [x] Exercise both actual frontends, damaged-byte preservation, a subsequent
  save and real daemon restart. Check inactive imports stay inactive and live
  PTYs keep their PIDs throughout recovery.
- [x] Build normal/sanitizer targets, run relevant broad and final focused gates,
  verify actual SDL rendering, review, document, commit and push. Close BMUX-100,
  BMUX-97 and BMUX-33 only after their remaining requirements are proven.
