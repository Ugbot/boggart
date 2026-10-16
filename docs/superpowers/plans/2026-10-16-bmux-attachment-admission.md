# BMUX-107: bound initial attachment demand

Diagnosis: current ASAN reproduction times out with73/100 live panes. Client
boundary trace shows timed-out initial snapshots/stream requests receive zero
bytes. Server trace processes100 snapshots in8.965s (~89.645ms mean each), with
42.697ms mean native capture and the remainder in the normal policy/evidence
handler. Every request currently starts its5-second deadline together. This is
unbounded demand on serial snapshot work; raising backlog/deadlines is not the
fix. Preserve the production policy, evidence and normal SQLite journal.

Add a per-joined-layout handshake queue with four active initial attachments and
256 total outstanding tickets. A slot covers snapshot, validated initial stream
replay and image publication. Active pane input/resize, established streams and
other control operations do not pass through this queue. Network deadlines
start only when a queued handshake is submitted to transport, and stay5seconds.
Queued UI state is explicit. Queue close prevents new starts; pane close/retry
cancels its ticket and releases active admission after cancelling old requests.
Callbacks and completion must be reentrant/idempotent; no timer/poll drives it.

The queue module owns FIFO/capacity/accounting. Remote owns cancellation of its
actual transport/session and releases the ticket on success/error/stale epoch
or publication failure. Studio layout owns queue lifetime. Existing standalone
Remote callers can omit the queue and retain their current behavior.

Verify unit queue boundaries/cancellation/reentrant synchronous completion and
Remote integration with fake transports. Run the real100-pane workload before
and after, normally and ASAN, preserving failures. Add a benchmark-only60ms
capture delay for a deterministic5-second backlog test; label that synthetic
load and never use it for product performance numbers. Diagnostic overlays log
bounded path/timing/count metadata and no request bodies/tokens/payloads. Retain
normal run checks and native live controls; do not claim the earlier unrelated
startup/resource budgets or competitive comparisons are solved.
