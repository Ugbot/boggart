# Planned: a local judge (a Jev-shaped model you run yourself)

Status: **queued, not built.** Today the `jev` rung of the tier ladder
([jev-ladder.md](jev-ladder.md)) talks to TypeSafe's hosted System One. That is optional
(boggart works without it), but it should not be the only way to get that rung. The goal is
the same rung served by a model on your own machine, with no key and no network.

## What "a local one" has to be

The ladder asks Jev typed questions and reads numbers back, never prose:

- `noul`: a probability for a yes/no statement
- `choice`: one of N options, with a probability per option
- `score`: a rating over 2..10 ordered levels, with a distribution

So anything that can answer those three shapes with calibrated probabilities can fill the rung.
Candidates named for this work: **kev** and **laya**. I do not have their interfaces yet, so
nothing below assumes details about them beyond "local, answers typed questions with
probabilities". Confirm what each exposes (a System One-compatible HTTP endpoint, a library,
or raw logits we have to read) before the adapter work starts.

## Design (so the ladder does not change)

The seam already exists: `judge.jev_only{state, questions}` returns answers in one shape
(`ranked`, `probabilities`, `confidence`), and every ladder site goes through it. The work is
a second **backend** behind it.

1. **Backend interface.** `judge` gains a small registry:
   `judge.backends.<name> = { available(), ask(spec) -> answers, meta }`. `hosted` wraps the
   current `bog.typesafe.ask`; `local` is new. `/judge backend hosted|local|auto` picks (kv
   `config.judge.jev_backend`, default `auto`: local if reachable, else hosted if keyed, else
   none). `/judge off|chat` keeps its meaning.
2. **Endpoint form first.** If kev/laya serve the System One wire (`POST /v1/systemone`), the
   local backend is just `typesafe.lua` with a different base URL and no key, which is a
   settings change (`config.judge.local_url`) rather than new code. The codec
   (`src/ltypesafe.c`) already validates and decodes that wire.
3. **Logit form, if they do not.** Otherwise a thin adapter turns each typed question into a
   constrained prompt and reads the option log-probabilities from the local server (the
   existing local model servers: OpenAI-wire llama.cpp-style at :8080, Anthropic-wire ds4 at
   :8000 — see the local-model-servers notes), normalizes them to `probabilities`, and derives
   `confidence` the same way Jev reports it. `noul` is the probability of "yes" against "no";
   `score` is a softmax over level tokens.
4. **Calibration is the real work.** A local model's token probabilities are not Jev's
   confidences, and cheap-model confidence is known to be miscalibrated. Before a local backend
   is trusted at the default thresholds, measure it on the ladder's own agreement samples
   (`kpis().ladder`) and set per-backend thresholds (`config.ladder.<id>.threshold` already
   exists per site; a per-backend offset is probably needed).
5. **No new failure modes.** Unreachable, slow or low-confidence falls through exactly as a
   Jev error does today. A local backend must never block the loop: it goes through the same
   async transport and timeouts.

## Tasks, in order

1. Find out what kev and laya actually expose (wire, library, or logits) and pick the form
   above. Everything else depends on this.
2. Backend registry in `lua/judge.lua`; move the hosted path behind it with no behavior change
   (existing `tests/judge.lua`, `tests/typesafe.lua`, `tests/ladder*.lua` must pass untouched).
3. `local` backend: endpoint form (URL + no key) or logit adapter.
4. `/judge backend` command, completion entry, `describe()` showing which backend answered
   (`meta.backend`), telemetry `ladder` records carrying it.
5. Calibration run: sample agreement vs the chat model on each ladder site; set thresholds;
   record the numbers in this document.
6. Make "no key, local reachable" the documented zero-config path for the Jev rung.

## Non-goals

- Replacing the chat model. The judge answers small typed questions; it does not generate.
- Making the local judge a requirement. Like the hosted one, it stays optional.
