# TypeSafe (System One / Jev): a typed judge, not a chat model

TypeSafe's System One model answers **questions about state** and returns
**numbers**: a probability, a choice with a distribution, a rubric level with
a distribution. There is no transcript, no tools, no streaming, no text to
parse. That makes it the wrong shape for `/model` and the right shape for
every place boggart currently asks a chat model a yes/no, pick-one, or
how-bad question and then regex-parses the prose.

Docs: <https://docs.typesafe.ai>. Wire recorded here as of 2026-09.

## The wire

```
POST https://api.typesafe.ai/v1/systemone     Authorization: Bearer $TYPESAFE_API_KEY
GET  https://api.typesafe.ai/v1/models
```

Request: `{ state, model, questions }` where `state` is a string, object or
array; `model` is `jev-latest` (alias; also `jev-1.13.0`, `jev-preview`);
`questions` is a map of caller-chosen ids to one of:

| type     | `criteria`                                   | answer                                             |
|----------|----------------------------------------------|----------------------------------------------------|
| `noul`   | optional `{true=, false=}`                   | `{ noul = p }` 0..1                                |
| `choice` | required map `option -> description`, ≤255   | `{ choice, confidence, probabilities }`            |
| `score`  | required ordered array of 2..10 levels       | `{ score, confidence, legend, probabilities }`     |

`instructions` and every description are *EntryType*: string, object, array
or null. Structured rubrics (a taxonomy, a schema, a DB row) are sent as JSON,
not flattened into prose. `score` may fall between integer levels (it is the
expectation over the distribution).

Errors: 401 key, 422 validation, 429 rate limit, 529 overloaded (back off).
Limits: 64k tokens/request, 32k for state + the longest question; 250k
tokens/s, 1200 req/min; text only. Output tokens are not billed.

## The Lua surface

Two layers. `typesafe` (C, `src/ltypesafe.c`) is the codec: validation to
the API's own rules before a byte leaves, and typed decoding. `bog.typesafe`
(`lua/typesafe.lua`) is the policy: transport over the existing async curl
path, retries, the provider row, and small constructors.

```lua
local ts = bog.typesafe

local a, meta = ts.ask{
  state = ticket_text,                      -- or state_json = '<raw JSON>'
  model = "jev-latest",                     -- optional
  timeout = 60,                             -- optional, seconds
  questions = {
    dept   = ts.choice("Which team should handle this",
                       { billing = "Payment issues", technical = "Bugs", sales = "Pricing" }),
    anger  = ts.score("How frustrated the customer appears",
                      { "Calm", "Frustrated but civil", "Very angry" }),
    urgent = ts.noul("The message conveys urgency"),
  },
}
if not a then return nil, tostring(meta) end   -- meta is the err here

a.dept.choice            -- "technical"
a.dept.confidence        -- 0.78
a.dept.probabilities     -- { technical = 0.85, billing = 0.15, sales = 0 }
a.dept.ranked[1]         -- { option = "technical", p = 0.85 }   (sorted desc)
a.anger.score            -- 1.0 (may be fractional)
a.anger.legend[1]        -- "Frustrated but civil"   (INTEGER keys, not "1")
a.anger.probabilities[1] -- 1.0
a.anger.ranked[1]        -- { level = 1, p = 1.0 }
a.urgent.noul            -- 1.0
meta.model, meta.usage.input_tokens, meta.usage.output_tokens, meta.status
```

Also:

- `ts.one(state, question, opts?) -> answer, meta | nil, err` — one question.
- `ts.models() -> table | nil, err` — `GET /v1/models`, decoded.
- `ts.available() -> bool` — module present and a key exists.
- `ts.ensure_provider()` — registers the `typesafe` provider row if the
  catalog predates it (see *Keys* below). Called by `ask` itself.
- `ts.RETRY = { attempts = 5, base_ms = 500, max_ms = 8000 }`; `ts.TIMEOUT = 60`.

The C module, when you want the pieces:

- `typesafe.encode{ state= | state_json=, model=?, questions= } -> json | nil, err`
- `typesafe.decode(body [, status]) -> answers, meta | nil, err`
- `typesafe.endpoint()`, `typesafe.models_url()` — `TYPESAFE_BASE_URL` overrides the host.
- `typesafe.has_key() -> bool` — never the key.
- `typesafe.limits()` — the numbers above, as a table.
- `typesafe.error(kind, message [, status])` — the error constructor.

**Nothing raises.** Every failure is `nil, err` where `err` is
`{ kind, message, status? }` with a `__tostring` (the message). `kind` is the
policy vocabulary: `auth | validation | rate_limit | overloaded | http |
parse | transport`. `ask` retries `rate_limit`, `overloaded` (and 502/503)
and transport failures with jittered exponential backoff that *yields* under
the scheduler, so a rate-limited judge stalls nobody else. `Retry-After` is
not honoured: `src/lhttp.c` does not surface response headers.

## Keys

```
export TYPESAFE_API_KEY=...        # or, in the REPL:
/auth key typesafe <key>
```

Keys: <https://console.typesafe.ai/keys>. The credential is the `typesafe`
slot in `src/lauth.c` and never enters Lua; `lhttp.c` attaches the Bearer
header when a request names the slot. lauth only honours a slot for a host
the `providers` table registers for it, so `lua/models.json` seeds a
`typesafe` provider row (`wire = "systemone"`, `auth = "bearer"`, no model
rows). A store seeded before that row existed gains it lazily on first `ask`.

Why `wire = "systemone"`: the chat wires (`anthropic`, `openai`,
`responses`) are what `lua/api.lua` switches on and what `/model` routes to.
An unknown wire falls into the Anthropic default branch *if* a model row
names the provider — none does, so `/model` never offers TypeSafe and the
row exists only for the credential registry. `boggart models` lists it as
`typesafe  systemone  bearer`, which is the honest description.

## The decision router: `bog.judge`

Nothing in the runtime should call `typesafe.ask` directly. `lua/judge.lua` is
the seam: a caller states a small discrete decision and the router picks the
cheapest thing that can answer it -- jev when the decision is *simple* and a
key is present, the chat model on the utility route otherwise. Both paths
return the same answer shape, so the caller branches once.

```lua
local a, meta = bog.judge.decide{
  state = transcript_tail,
  questions = {
    done   = { kind = "noul",   instructions = "The task is complete with evidence" },
    status = { kind = "choice", instructions = "What is the agent doing",
               options = { working = "...", stuck = "...", done = "..." } },
    evidence = { kind = "score", instructions = "Quality of the evidence",
                 levels = { "none", "claims only", "partial", "verified" } },
  },
}
-- a.done.noul, a.status.choice/.confidence/.ranked, a.evidence.score
-- meta.via = "jev" | "chat", meta.escalated, meta.confidence
```

`decide{ state=, schema= }` takes a JSON Schema instead: `enum` -> choice,
`boolean` -> noul, bounded `integer` (2..10 values) -> score. A schema with a
free-text property is not simple and the chat model answers it whole -- the
same thing `spawn{ schema= }` would have produced, minus the agent.
Shorthands: `judge.choose(state, q, options)`, `judge.yes(state, q)`,
`judge.rate(state, q, levels)`. The `judge` tool exposes `decide` to the model.

**Simple** = every question is noul / choice (<=255) / score (2..10), the
state is under the jev budget, nothing needs free text.

**Confidence cascade.** Below `min_confidence` (default 0.6, `/judge min`)
jev's answer is re-asked of the chat model and chat wins; jev's numbers stay
in `meta.jev` so telemetry can compare them. A noul's confidence is its
distance from 0.5.

**Optional by construction.** `/judge auto|jev|chat|off`:

| backend | behaviour |
|---|---|
| `auto` (default) | jev when keyed and simple, else chat; cascades on low confidence; falls back to chat on any jev error |
| `jev` | insists; reports jev errors instead of falling back (for measuring) |
| `chat` / `off` | never touches jev |

With no `TYPESAFE_API_KEY`, `auto` is `chat`: an unkeyed install behaves
exactly as before this module existed. Tests: `tests/judge.lua` (both
backends stubbed).

## Where it could plug in

Candidates only; none is wired. Each is a place boggart currently asks a chat
model for a small decision and parses prose, or applies a heuristic where a
calibrated probability would do better.

- **`lua/route.lua` — intent routing.** "Which role/model should take this
  turn?" is a `choice` over the role catalog with a confidence to gate on;
  low confidence falls through to the default role instead of guessing.
- **`lua/skillrouter.lua` — skill selection.** A `choice` over skill names
  with their descriptions as the rubric (structured criteria, straight from
  the skill frontmatter). TypeSafe's own cookbook has this exact pattern
  (`cookbooks/skill_suggestion`).
- **`lua/choose.lua` — the model picker / fallback chain.** A `score` of
  "how much does this task need a frontier model?" to pick a rung on a
  cost/capability ladder before a token is spent.
- **`lua/gold.lua` — verification and judging.** Gold-standard comparison is a
  `score` against a rubric plus a `noul` "does the output satisfy the
  acceptance criterion?"; a distribution replaces a one-word verdict, and
  self-consistency (ask N times, average) is cheap at $0.042/M.
- **`lua/perm.lua` — tool-call guardrails.** A `noul` "is this bash command
  destructive / does it leave the workspace?" on the exact argv, gating the
  prompt rather than replacing it. The `llm_guardrails` cookbook is this.
- **Swarm supervisor triage (`lua/supervisor.lua`).** Classify an agent's
  last turn: `choice` {progressing, stuck, looping, done, needs-human} with
  confidence, feeding the watchdog instead of turn-count heuristics.
- **Reliability layer exit contract.** `noul` "did this turn actually finish
  the task it claims?" as an independent check on the agent's own exit
  report — the shape the 11/14 failure needed.
- **`lua/memory.lua` / recall.** `score` relevance of each candidate memory
  to the current prompt (a rerank, `cookbooks/rerank_typesafe`) before
  they are spliced into context.
- **Tool-result classification.** `choice` over {success, partial, error,
  needs-retry} on raw tool output, so the loop can branch without the model
  re-reading the whole thing.
- **Speculative fan-out.** Because questions are parallel within one call,
  ask every candidate question about a state at once (the `fan-out` pattern)
  and let the confidence decide which branch to take.

Tests: `tests/typesafe.lua` (headless — codec against the documented
quickstart request/response, validation, error envelopes, fail-closed
without a key). A live smoke is `TYPESAFE_API_KEY=... boggart --eval` with
the example above.
