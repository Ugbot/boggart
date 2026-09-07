# The team story: boggart as a colleague

Status: plan of record (2026-09-07). Tracker: BTEAM.
Settled by interview; research inputs at the bottom.

## What this is

Boggart grows from a single-user kernel into a member of a team: it
collaborates with other boggarts and with people, it acts inside external
systems under its own name, and the whole arrangement scales from one person
with three machines to an org, without changing shape.

Four tests, from the interview. Every design call below answers to all four:

1. **One binary, whole stack.** Any role in the team topology, including the
   team server, is a boggart. Nothing requires a second product to run.
2. **It rewrites itself.** The team layer is Lua over C seams, editable at
   runtime. Teams extend their own collaboration the way one user extends
   their own tools.
3. **Reliability contracts.** Every team action is journaled, attributable,
   replayable, and gated. Work you can trust unattended is the wedge.
4. **The compound team.** Skills, memory, and review findings move between
   members, so the team's capability compounds. Sharing is the moat.

## The protocol: moot

The collaboration layer is a protocol, not a service. Working name: **moot**
(an assembly; rename at will). It must be simple enough that a file is a
valid implementation and complete enough that Gestalt can speak it later.

### Principals

One table, three kinds, lifted from llm-station-remote's best idea:

    principals(id, kind human|agent|machine, name, pubkey, created)

A person, a boggart, and a host are the same row type. Existing tables gain a
`principal` column through the additive `ensure_column` path: sessions,
journal, records, claims, memory. Attribution becomes a fact, not a guess.
Agents keep their integer runtime ids; the principal is who the run belongs
to.

Identity is **per surface**: a bindings table maps a principal to its account
on each surface (github login, slack id, station routing id). On GitHub and
in chat a boggart acts as itself, a named bot. For credentials and payment it
acts on behalf of its sponsor human. Sponsorship is a row: humans answer for
their agents, and an agent's effective authority is the floor of its own and
its sponsors' (the llm-station-remote ceiling rule).

### Artifacts

Everything exchanged is an addressed, signed document with sync lineage:

    { kind, id, from, to?, hlc, site, body, sig }

Kinds, in delivery order:

- **handoff**: task + context markdown + next steps + artifact links + TTL.
  The llm-station-remote shape, proven good.
- **skill-pack**: a skill or tool WITH its body, signed by its author.
  Distribution the project manifest deliberately refuses; moot supplies it
  with the trust model below.
- **review**: structured findings (the spawn-with-schema verdicts that
  already exist) addressed to a change: repo + ref + per-file findings.
- **claim**: advisory file/path lease, the existing claims model with a
  principal attached, so collision avoidance works across machines.
- **memory**: a shared memory entry with tier and scope, so team knowledge
  survives the person who learned it.
- **session-share**: an invitation plus an event-stream cursor; live
  collaboration rides the bus, not a new mechanism.

`hlc` + `site` exist from day one so any backend can sync any other. The
sync algorithm is ai-grind's station engine, ported: row identity map,
canonical hashes for echo suppression, two-phase create, watermarks,
auto-pause on repeated failure. Local wins by default. That design has 55
tests and survived production use; the CRDT op-log hub it replaced stays
dead.

### Bindings (more than one, always)

1. **File/git** (the easy one): `.boggart/team/` holds artifact JSON, one
   file per artifact, append-only per site. Sync is git, or a shared folder,
   or rsync. Two people with a repo have a team. Offline works. Merge is the
   sync algorithm applied at read.
2. **Hub** (the central one): the control plane grows `/team/*` routes on
   `boggart serve`: push/pull artifacts by watermark, principal registry,
   SSE with per-client topic filters. The hub is a boggart; the SaaS story
   is a hosted hub with the store's vtable pointed at Postgres. No second
   codebase.
3. **Gestalt** (the scale one, later): artifacts map 1:1 onto its doc_store
   kinds; its identity tables carry principals; its Yjs rooms carry live
   sessions. Gestalt becomes a moot backend when its tenancy and storage
   authz land, and the protocol requires nothing from it before then.

A boggart may speak several bindings at once. The file binding is also the
export format of every other binding: leaving a hub is a pull.

### Trust tiers for skill-packs

Skills are code with authority. Three dials, one model:

- **mine**: full authority, as today.
- **crew**: signed by a known principal; runs sandboxed (the panel-sandbox
  capability model, extended with declared capability grants) until the
  human blesses it to full. Blessing is recorded.
- **registry**: always sandboxed, capabilities from a manifest, never
  blessable to full without a human reading the diff.

Installing stays an explicit act in every tier. The manifest's rule stands:
nothing executes because it arrived.

## Boggart as a user of systems

Surfaces, in build order:

1. **GitHub**: webhook ingestion grows HMAC signature verification and
   payload parsing onto the existing `/hooks/` route; a Lua GitHub client
   (issues, PRs, reviews, checks) over the existing http layer; the bot
   identity from the bindings table. This unlocks both flagship flows below.
2. **CI**: `boggart review` and `boggart build` run as ephemeral jobs.
   One workflow file adopts boggart; state that must outlive the job is a
   moot artifact pushed to the repo's file binding or a hub.
3. **Chat** (Slack first): summonable in threads, reports progress, accepts
   handoffs conversationally. After GitHub proves the identity model.
4. **Station mesh**: already built. Boggart is a client of any station
   daemon, cross-workspace, with events on the bus. The mesh is how agents
   on different machines share code intelligence today.

## The flagship flows

### The reviewer (coderabbit, but yours)

`hook:github` pull_request event, or `boggart review` in CI: the existing
two-axis review swarm runs with station code intelligence, verdicts come
back as schema-validated findings, and the GitHub client posts them as a
review with line comments. Findings are also a moot review artifact, so the
team's review history is queryable and a second reviewer (human or agent)
sees what the first found. Local-first: code never leaves machines the team
does not own.

### The autonomous builder (aider level, then past it)

`boggart build <issue>` or an issue webhook. The pipeline, all existing
parts: plan against station's call graphs and search; a worktree per
attempt; an implementation swarm under gates and budgets; tests; a PR
through the GitHub client; then it stays on the PR, watching CI webhooks
and review comments, fixing and pushing until green or blocked. Both homes
from day one: the daemon owns long-running builds with warm memory; the CI
job serves adopters with zero infrastructure. Same skill, two entry points.

What puts it past the frameworks: the builder can write itself new Lua mid
build (a parser for this repo's test output, a deploy step, a panel showing
the build), and what it writes becomes a skill-pack the team keeps. A
langchain graph cannot grow a node; Tessl specs do not write their own
tooling; this does, under the trust tiers, with the journal recording every
step.

## Memory: the Gestalt model, ported

Gestalt's retention design moves into the store as Lua + SQL: four tiers
(working, episodic, semantic, procedural) with per-tier decay half-lives,
access-count promotion of episodic entries to semantic, consolidation of
expired working memory, and composite recall scoring (relevance, recency,
importance) over FTS5, with station's semantic_search as the vector arm
when a daemon is up. Team memory is the same table plus scope: project,
crew, org. Shared entries travel as moot memory artifacts. Gestalt itself
becomes the scale-out backend for the same interface when it is ready, and
nothing above the store notices the swap.

## What exists already (research summary)

Load-bearing and done: the authenticated control plane with full-bus SSE
(`lserve.c` + `control.lua`), the serve daemon with a serialized prompt
queue, generic webhook ingestion and persisted triggers, the journal and
records tables with agent lineage, permission policy as wire-settable data,
advisory claims, worktree isolation, the review swarm with structured
verdicts, the marks accept/revert UI, the station mesh, and per-project
manifests. Missing and now planned: a control-plane client, principals,
signature-verified webhooks, a GitHub client, skill distribution, sync, and
every multi-user concern. llm-station-remote contributes its schema and the
ai-grind sync engine design; its service is not adopted. Gestalt contributes
its memory model now and a backend later.

## Phasing

- **M0 Foundations**: principals + bindings + sponsorship tables; principal
  columns on sessions/journal/records/claims/memory; the moot artifact spec
  written as docs/moot.md with the file binding defined; git author
  attribution for agent commits.
- **M1 The builder and the reviewer** (the v1 in use next week): GitHub
  client in Lua; webhook signature verification + payload parsing;
  `boggart build` and `boggart review` skills; both CI and daemon homes;
  PR posting for review findings.
- **M2 Exchange**: the file/git binding end to end; skill-packs with trust
  tiers and signing; handoff artifacts; `boggart connect` (the missing
  control-plane client, also how one boggart drives another).
- **M3 The hub**: `/team/*` routes on serve; watermark push/pull; SSE topic
  filters; the sync engine port; a second machine joins a team by URL.
- **M4 Memory**: the tier/decay/promotion port; scoped team memory; memory
  artifacts over moot.
- **M5 Presence**: session-share artifacts; live shared transcripts over
  SSE replay; the chat surface.
- **Later**: Gestalt binding; hosted-hub SaaS posture; the public skill
  registry with the registry trust tier.
