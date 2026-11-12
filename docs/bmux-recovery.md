# Recover saving for a named session

BMUX-100 completes the recovery controls for BMUX-33/97. In Studio, open
**Sessions → Recover saving; preserve original checkpoint**. In terminal Bmux,
press **Ctrl-B e**, then **v**.

The preview identifies the saved session, current layout/resource counts,
original byte count and the recovery file path. Confirm the exact saved-session
name to save the current in-memory layout and resume coalesced saving. Escape
cancels without writing a recovery file or replacing the checkpoint. Running
PTYs retain their identities and input leases.

Recovery inspects the current saved bytes, including external changes made while
the daemon was idle. A healthy unchanged session returns “recovery unnecessary.”
The action saves the currently owned state; it does not load the damaged document
or reconstruct execution owners. Imported terminals and agents retain their
inactive flags through recovery, later saves and subsequent daemon restarts.

## Preserved originals

Before replacing any saved data, the host exclusively creates:

```text
BOGGART_HOME/bmux-recovery/ID.checkpoint
BOGGART_HOME/bmux-recovery/ID.checkpoint.json
```

The first file contains the exact original bytes, including invalid UTF-8 and
embedded NULs. The JSON sidecar records session name, source host/revision,
original byte count, creation time and whether a checkpoint existed. An absent
key and an existing empty value both produce an empty raw file; `present` in the
sidecar distinguishes them. Files are 0600 inside an owned private directory.
Both files, their directory and its parent are synced before SQLite replacement.

The preview identifies the path before confirmation. Preserve this directory
when backing up Boggart's state. An archive can be copied and repaired in an
editor, then imported through the existing inactive-file workflow. Raw recovery
bytes are never interpreted as terminal input or commands.

Valid checkpoints remain bounded to 4 MiB; raw recovery copies allow up to
64 MiB so moderately oversized corrupt data can also be preserved. Larger
originals remain untouched and the recovery request reports its limit. Archive
write/sync failures leave the original saved data intact. A failed attempt may
leave an exclusive recovery file behind; later attempts use fresh IDs and never
overwrite those files.

## Ownership and conflicts

Preview pins exact original bytes, owner identity, layout host and revision.
Confirmation accepts only those preview identifiers. SQLite compares both the
checkpoint and owner in the same statement. A replaced checkpoint, changed
layout, lost lease, live rival or invalid owner record cannot be forced through
recovery. Invalid/unclaimed ownership remains blocked; select a different named
session rather than deleting the original owner's data.

Layout HTTP edits receive 409 during the recovery commit interval. Native PTYs
continue running. Success resumes journal subscriptions, including a journal
that was blocked before startup could install its observers. Subsequent layout
changes and native output save normally.

A preview is consumed once. There is no automatic mutation retry. After an
uncertain acknowledgement, **Refresh session status** observes recovery state
and identifies a completed archive without resubmitting the write. Rejoin
explicitly before another session mutation. Recovery archive metadata in status
belongs to the current daemon; the files and sidecar remain after restart.

## Native control contract

All routes require their ordinary `control:METHOD:PATH` capability and reject
query parameters. Existing `GET /layout/session` retains its previous wire
shape for older clients.

| Route | Result |
| --- | --- |
| `GET /layout/session/recovery` | Bounded owned preview; no archive or checkpoint write |
| `POST /layout/session/recover` | Archive originals and save current state under exact guards |
| `GET /layout/session/recovery/status` | Persistence status plus optional `last_recovery` metadata |

POST is a JSON object up to 4096 bytes:

```json
{"host_id":"joined-host","revision":7,"recovery_id":"preview-id"}
```

It accepts no checkpoint, argv, commands, executable path or archive destination.
The native client validates the acknowledgement against the preview and pins the
status host. Exact byte comparisons support SQLite TEXT and BLOB values.
Recovery status is observation only and does not invalidate a
preview or clear an uncertain mutation.

`repo:kv_compare_set(key, expected, replacement, owner_key?, owner_value?)` now
supports an optional owner guard in its single SQLite statement. Ordinary
journal writes and named imports use the same guard. Nil expected means absent;
nil replacement retains the existing conditional-delete semantics.

See [session controls](bmux-session-transfer.md), [journal](bmux-journal.md) and
[verification](benchmarks/2026-10-16-bmux-recovery-verification.md).
The [actual SDL confirmation](images/bmux-session-recovery.png) shows the full
saved name separately from the short input prompt.
