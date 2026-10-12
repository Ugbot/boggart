# The tier ladder: code -> jev -> llm

> **Optional.** Jev, a TypeSafe key, or any other extra model is never required. With every
> site off (the default) boggart is unchanged; with a site on and no key, only the code tier
> runs and the rest falls through to your chat model. A planned local judge is in
> [local-judge.md](local-judge.md).

Every place the runtime asks "what next?" can be answered by a stack of stages, cheapest
first. A stage returns a verdict and a confidence, or abstains; the first stage that is
sure enough wins and everything else falls through.

| tier    | what                                                             |
|---------|------------------------------------------------------------------|
| `code`  | pure Lua: rule, predicate, verify command, hardened memo.        |
| `local` | retrieval with no model (`skillrouter`, `learning.route`).       |
| `jev`   | a typed question to System One via `judge.jev_only`.             |
| `llm`   | the existing path. Always last, always accepted.                 |

## Contract

- **Everything is opt-in.** A site is off until `/ladder on <id>`; an off site runs only its
  `llm` stage, which is exactly what the caller did before the ladder existed.
  `/ladder off` is a master switch. Jev needs `TYPESAFE_API_KEY` (`/auth key typesafe <k>`).
- **Fall through, never fail.** A jev error, no key, `/judge off|chat`, a throwing stage, or
  confidence below the site's threshold moves on to the next stage. `meta.tried` says why.
- **Measured.** With probability `sample` a routed verdict is also put to the `llm` stage and
  the agreement recorded (`telemetry.kpis().ladder[site]`: n, tiers, escalated, agree,
  disagree). The caller still gets the routed verdict.
- **Authority never moves.** Routing narrows or decides *what* runs; the permission gate,
  allow-sets and approvals still decide *whether* it runs.

## Sites

| id                | stages                         | what it does                                               |
|-------------------|--------------------------------|------------------------------------------------------------|
| `tool.triage`     | jev > llm                      | once per user turn: a clear "needs no tools" offers none   |
| `tool.narrow`     | jev > llm                      | offer the ranked likely tools + read/write/edit/bash/grep/glob |
| `tool.force`      | jev > llm                      | one clear next tool: `tool_choice` names it (all 3 wires); a model that ignores it is asked once more unforced |
| `tool.skip`       | jev > llm                      | no model turn when the call's arguments are decidable (none required, or enum/boolean via Jev); never bash/write/edit |
| `swarm.supervise` | code > jev > heuristic         | classify a stalled agent (progressing/stuck/looping/done/needs_human) before the watchdog nudges |
| `coding.verify`   | code > jev > none              | name why a verification run failed (code_bug/build_error/environment/flaky) |
| `tracker.classify`| code > jev > defaults          | kind and priority for tasks created without them           |
| `story.judge`     | jev > model                    | the 1..10 prose rating from a Jev rubric instead of a model turn (off by default territory: turn on deliberately) |

Tool choice shares one ranked Jev question per model round between narrow/force/skip
(`lua/toolroute.lua`); candidates are pre-selected by local term overlap and an explicit
"(none)" option lets Jev abstain. `toolroute.pre(fn)` puts any other classifier ahead of them.

## Settings (kv, shared by TUI and studio)

```
/ladder                              list sites and their state
/ladder on|off [<site>]              master or one site
/ladder threshold|sample <site> <0..1>
```

`config.ladder.master`, `config.ladder.<id>.enabled|threshold|sample`
(defaults: on, off, 0.85 [per-site default overrides], 0.05 [0.1 for non-tool sites]).

## Hardening

`/harden` folds proven decisions down the ladder. A site that defines `key(ctx)` can have a
verdict that a lower tier gave, and the `llm` sample agreed with, `min_obs` (3) times in a row
for the same key, answered by **code** thereafter (`meta.memo`). The memo is rechecked against
the ladder at `recheck` (5%); a disagreement drops the entry, `max_bad` (3) of them switch the
site's hardening off and forget the memo (the rollback). `ladder.confirm(meta, good)` lets a
caller with ground truth (a verify passed, the user accepted) feed it directly.
Keyed sites: `tool.triage`, `coding.verify`, `tracker.classify`.

```
/harden                       what is hardened, per site
/harden on|off [<site>]       master or one site (the kill switch)
/harden clear <site>          forget a site's memo
/harden obs <n>               observations required before promotion
```

### Workflows

Every workflow capability call records a `tier` (`code`, `jev`, `llm`) on its invocation
(`workflow.tier_of`: declared via `workflow.set_tier`, else `model.*` = llm, `jev.*`/`judge.*` =
jev, rest = code), and `harden.tiers(snapshot)` summarises a run. `harden.propose(alignment, opts)`
compiles aligned traces (`mining.compile`), names each residual model decision, and, given a typed
Jev spec for it, registers a `wf.<capability>` ladder site (jev, then the original capability).
`harden.admit(candidate, report, registry, id, version)` runs the evidence gate
(`learning.promote.check`) and registers the candidate **inactive**: activation, qualification and
monitor rollback remain the learning registry's, so harden never makes a workflow run by itself.
Nothing is compiled whose effects the traces do not fully determine (the compiler refuses it).

## Files

`lua/ladder.lua` core, settings, memo · `lua/toolroute.lua` tool sites · `lua/ladder_sites.lua`
swarm/coding/tracker/story sites · `lua/harden.lua` `/harden` + workflow side ·
`lua/judge.lua` `jev_only` · `lua/telemetry.lua` `ladder` records ·
`lua/api.lua` router hook, `tool_choice`, unforced retry, skip execution ·
tests: `tests/ladder.lua`, `toolroute.lua`, `ladder_sites.lua`, `harden.lua`.

## Caveats

- Jev's own benchmark accuracy is vendor-claimed ~68%; defaults are conservative (0.85-0.95
  thresholds) and the agreement samples exist to tune them. Watch `kpis().ladder`.
- Changing the offered tool set between turns changes the prompt prefix (cache); narrowing only
  applies above 12 tools.
- A synthesized (`tool.skip`) call reaches the transcript as an assistant `tool_use`; it is
  bounded to 3 per user turn and never repeats the same tool in a turn.
