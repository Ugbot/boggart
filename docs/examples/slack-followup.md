# Fixture-backed Slack follow-up

[`examples/workflows/slack_followup.lua`](../../examples/workflows/slack_followup.lua)
is ordinary authored Lua source. The host registers its exact bytes with
`workflow.register{id=...,version=...,source=...,durable='replay-v1',capabilities=pins}`,
then calls `workflow.start(id,{authority=current_authority,context={config=config}})`.
The example exercises authored registration, not ordinary-request routing or
automatic promotion. It makes no claim that the current mining compiler can
synthesize this entire source package.

`config` contains `campaign`, `cohort`, `period`, `channel`, `window={start,finish}`,
`now`, a dense unique `expected` recipient sequence, `reminder`, `report_target`,
`model_provider`, `policy`, and `capabilities`. Each capability role maps to a host
capability ID whose exact version is pinned in the registration. Durable capability
descriptors must include implementation revisions; provider/source revisions should
identify the actual implementation and source. Current authority is supplied on every
start and resume. Configuration contains data, not credentials.

Policy contains `ignored='hold'|'remind'`, `ambiguous='hold'`, integer
`max_model_calls` (0–16) and integer `max_tokens` (1–4096). Unknown model decisions
hold the recipient. Only the exact interpretation `replied` changes an ambiguous
reply's status, and it can only suppress a reminder. Interpretation reserves one
call for an optional narrative report. A zero budget skips models entirely. The
host must enforce real provider token/cost ceilings through capability estimates,
bounded metrics and the common policy/quota admission layer; a Lua argument alone
is not a spending boundary.

The host supplies these narrow capability contracts:

| Role | Arguments and result |
| --- | --- |
| `bind` | `{key,intent}` atomically binds stable campaign identity to canonical intent; returns `{accepted,reason?}`. Changed recipients, window, channel, reminder, policy, model/provider binding or report target refuse reuse. |
| `source` | `{channel,window,expected,recipient?,now}` returns `{available,people,observed_at,provenance,atomic_conditional_send}`. Each person has `kind`, `revision`, optional ambiguous `text`. Kinds are `missing`, `ignored`, `ambiguous`, `replied`, `opted_out`. The host applies channel/window scope and reads current replies and opt-outs. |
| `send` | `{key,intent,recipient,channel,window,revision,reminder}` returns `{status,receipt?,reason?}`. Atomically reconcile/deduplicate the stable key and enforce the latest recipient reply/opt-out precondition before dispatch. Supported factual statuses: `confirmed`, `pending`, `uncertain`, `failed`, `denied`, `replied`, `opted_out`. |
| `model` | Interpretation receives `{task='interpret',provider,text,max_tokens}` and returns `{classification}`. Report receives `{task='report',provider,rows,counts,max_tokens}` and returns `{text}`. |
| `progress` | `{key,report}` durably records progress, returning `{reference}`. It must be idempotent or support authoritative reconciliation for interrupted writes. |
| `artifact` | `{target,report}` writes an authorized report artifact and returns `{reference}`; same interrupted-write requirement as progress. |

The logical campaign key length-prefixes campaign/cohort/period; each recipient
operation appends its length-prefixed recipient ID. Workflow execution IDs remain
separate. Sorted recipients make order immaterial. Observation time is excluded
from intent so a later duplicate trigger can resolve current replies without
creating a second reminder. The host must bind every argument to the authorized
intent and derive policy resources from actual channel/recipient/artifact targets.
A model cannot add recipients or authorize messaging.

A fresh read immediately precedes each candidate send. **That read alone does not
close the reply-arrives-before-send race.** The host must enforce conditional send
and durable idempotency at its actual effect boundary, including concurrent workers
and process restarts. If it cannot make that guarantee, it must return
`atomic_conditional_send=false`; the workflow records pending and sends nothing.
This document does not claim that native Slack provides such an atomic primitive.
A real adapter needs a demonstrated backend protocol, not merely two HTTP calls or
a database lock around a separate remote request.

`runstore` persists each capability invocation before dispatch. An uncertain effect
halts the durable execution with `reconciliation_uncertain`; pending progress was
written before dispatch and remains inspectable. Resume requires current authority
and exact dependency identities, and uses the adapter's authoritative reconciliation
hook. A new trigger must also consult the persistent logical recipient ledger.
Unknown outcomes must remain uncertain and must never cause a blind resend. This is
separate from the execution-specific runstore operation ID. Replay can reuse old
source reads; consequently the send adapter must recheck current state even when
replayed arguments contain an older revision. Revocation remains effective.

Reports contain factual recipient rows/counts, effect receipts, provenance, model
call counts, progress and artifact references. `complete` is false when any row is
ambiguous, ignored, unavailable, pending, uncertain, failed or denied. Complete
means every listed participant is replied, opted out or confirmed reminded; it does
not mean everyone submitted an update. Model narrative is untrusted prose and
never overwrites structured facts. `verify` checks structural coverage; acceptance
fixtures independently check recipient statuses and counts. Reporting is local to
the configured artifact adapter, not a Slack message.

`tests/workflow_slack.lua` supplies synthetic adapters, SQLite campaign/effect/
progress/artifact ledgers and bounded synthetic model calls. Conditional fixture
send uses `BEGIN IMMEDIATE` to serialize the precondition/deduplication/receipt
transaction. The fixture artifact is a SQLite record; production may supply an
authorized file/object artifact adapter. No Slack account, real message, private
logs or paid model is used. Enabling real sends requires actual workflow
configuration and user authorization.

Run the suite with an isolated profile via the repository harness:

```sh
python3 .superpowers/sdd/run_lua.py workflow_slack workflow
```

The two explicit cohort/period expectations measure 4 actual synthetic model calls
against 11 actual synthetic baseline calls. The baseline completes the same task:
it models each participant's reply classification (including ambiguous replies),
rechecks current replies/opt-outs, conditionally sends missing reminders, and
passes factual rows/counts to its report model before persisting the report.
Separate `:baseline` campaign and artifact identities prevent its effects from
deduplicating the workflow's effects. Both reports and both sets of actual reminder
increments and durable receipts are checked against the same manually enumerated
expectations. The baseline explicitly permits one model call per participant plus
one report; the workflow permits two calls for these fixtures.

The reusable fixture exposes `f.baseline(config) -> report, actual_model_calls,
baseline_config` for independent qualification. This is a call-count result for
those fixtures, not a provider cost or latency claim. Recovery, failures and
repeated triggers incur additional evidenced calls outside that comparison.
