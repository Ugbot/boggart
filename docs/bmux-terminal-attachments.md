# Bmux terminal attachment protocol

BMUX-70 adds coherent request/response attachment frames and explicit controller
leases to the [server-owned terminals](bmux-server-terminals.md). Each viewer
keeps an independent cursor and receives the same native cell data as a local
snapshot, including Unicode clusters, styles, links, wrapping and a bounded
scrollback tail. The server remains the sole parser/process owner.

BMUX-32 remains in progress. These routes do not yet supply native push/SSE
delivery, an attached Studio view, or evidence for its sub-50ms reconnect gate.

## Attach, update and detach

All routes use the existing native transport authentication and exact control
capability IDs. Terminal IDs and generations are the ones returned at creation.
Attachment IDs/tokens are separate random capabilities, never roster metadata.

| POST route | JSON fields |
| --- | --- |
| `/terminals/:id/attachments` | `generation`, optional `tail` (default 32, maximum 256) |
| `/terminals/:id/attachments/:attachment/updates` | `generation`, `attachment_token`, `after`, optional `control_token` |
| `/terminals/:id/attachments/:attachment/control` | `generation`, `attachment_token`, optional `control_token`, optional `takeover` boolean |
| `/terminals/:id/attachments/:attachment/detach` | `generation`, `attachment_token` |

Attach returns a frozen JSON frame with `v=1`, terminal `id`, `generation`,
`attachment_id`, `attachment_token`, `reader_seconds`, `after=0`, `cursor=1`,
`kind="snapshot"`, `cols`, `rows`, `screen`, `state`, `process` and `scrollback`.
`screen` is the native row array; each row contains `wrapped` and `cells`, with
the existing native text/width/flags/style/link fields. `state` supplies cursor,
modes and alternate-screen state. `scrollback={first,total,rows}` is the current
tail window, using one-based indices into retained native history.

Call updates with the last fully applied cursor. A changed frame has a greater
cursor and `after` equal to the prior cursor. `kind="delta"` supplies
`changes=[{index,row}, ...]` for changed visible rows, plus current state/process
metadata. A changed history tail replaces the entire `scrollback` object;
`scrollback=false` preserves the prior window. Geometry or alternate-screen
changes produce a complete `kind="snapshot"` instead. An unchanged response has
`kind="unchanged"` and the same cursor. Do not advance a cursor until the whole
response has been validated and applied.

Only one frozen response frame is retained per reader. Retrying its prior
`after` value returns the **exact cached bytes**, even if newer output exists.
Older or future cursors return 409; explicitly reattach to obtain a new full
image. Attach/capture checks native revisions before and after constructing the
frame, with no event-loop yield in between. It returns 409 rather than publish
a mixed image if the source changes during capture. Native damage flags are
never consumed for cursor tracking. Two readers cannot clear each other's work.

Readers expire after 30 seconds without valid activity by default. Update,
control and accepted commands renew the reader lifetime; detach/expiry drops
its cache and controller capability while leaving the PTY running. Terminal
close, eviction or server shutdown invalidates its attachments. Tokens are
local capabilities, not identities to persist in layouts or logs.

## One controller, explicit takeover

Initial attachment is read-only. The first successful attachment permanently
sets `attachment_controlled=true` for that terminal runtime. From then on,
legacy generation-only input/resize requests are refused, even after all
readers detach or expire. A viewer must explicitly acquire control.

The control route returns `control_token` and `lease_seconds` (default 10).
Renewal of an existing live controller requires its current control token.
Another reader receives 409 unless it explicitly sends `takeover=true`;
takeover and expiry replace the token and revoke the previous writer. A valid
updates request carrying the current control token renews the lease. Without
that token it is only reader activity. Capability policy can grant attach/update
routes without granting controller/input/resize routes; read-only attachment
tokens alone never confer those route permissions.

For controlled terminals, `/input` and `/resize` additionally require
`attachment_id`, `attachment_token`, `control_token` and `command_seq` alongside
the existing generation/text or generation/cols/rows fields. Sequences are
strictly increasing positive integers within the lease. Retrying the last
identical accepted command returns its prior result without writing or resizing
again. Reusing that sequence for different content, or replaying an older
sequence, returns 409. Failed native commands do not consume the sequence.
Deduplication retains only the last command/result for the current lease;
it is not a durable outbox across leases or server restarts. Lifecycle close
remains a separate explicit administrative route/capability.

## Bounds and implementation

Defaults: 128 readers per host, 32768 cells per attachment image, 256 requested
tail rows, 4MiB per encoded frame and 32MiB of retained frames. Admission reserves
space for the requested tail at the configured native history limit, so future
scrolling cannot silently exceed the cell bound. Controlled resize preserves
the bound for all active readers. Overlarge frames or exhausted cache capacity
return 503 without advancing the cursor or evicting another reader. Initial
capture failure leaves attachment/control admission unchanged. These are
logical/cache budgets, not measured RSS guarantees; native input queues and the
last controller command also have their existing separate bounds.

`terminal:row_versions(tail)` copies row generations before allocating Lua
result tables. It does not clear dirty flags. `lua/terminal/attachments.lua`
owns snapshots/cursors/leases; `terminal.registry` remains the PTY owner and
`terminal.routes` stays under `control` authentication/policy. No reader owns a
native terminal handle, and no per-reader polling timer was added.

See [verification](benchmarks/2026-10-15-attachment-cursors-verification.md).
