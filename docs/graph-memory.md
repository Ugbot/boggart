# Graph memory

Compaction into a knowledge graph. The context window becomes a rendered view
of a graph: the old part of a conversation is collapsed into records and an
outline of one-line stubs, the recent tail stays in full, and `expand` brings
any record back. Nothing is deleted, and compaction makes no model call.

## Turning it on

```sh
BOGGART_MEMORY=local ./boggart --headless < task.txt
./boggart --memory local -p "task"
```

| value | memory |
|---|---|
| `summary` | the prose-summary compaction (the default) |
| `local` | graph memory on the minimal SQLite backend: one graph per conversation in the local store, text search ranked by recency, no cross-session reads |
| `<name>` | graph memory on a backend an extension registered as `<name>` (`register_backend`), or a module `ctxgraph.backends.<name>` on the Lua path, e.g. `example` |

A value that is neither built in nor an installed backend ("memory tier
'<x>' is not built in (summary, local) and no backend named '<x>' is
installed") stops a headless or one-shot run with exit 2 before any request. The REPL prints why and stays on
`summary`. `BOGGART_COMPACT=summary|graph` and `BOGGART_GRAPH_BACKEND=<name>`
are lower-level overrides for experiments; `BOGGART_MEMORY` wins when they
disagree, and the conflict is logged. Sub-agents and forks inherit the tier.

`BOGGART_GRAPH_AUTOEXPAND=0` (or `sess.graph_autoexpand = false`) stops the
harness expanding records on its own.

## What a compaction does

The trigger and the kept tail are the same as summary compaction
(`lua/window.lua`). The messages before the tail are grouped into **steps**
(one model reply plus the results of its tool calls, never split), and by rule:

- `read`/`write`/`edit` → a **file** entity; writes and edits add a **version**
  (keyed by content digest when known, else by number);
- `bash` → a **command** entity; `pip`/`apt`/`npm install` → **package**;
  a test runner (`pytest`, `python -m pytest|unittest`, `npm test`,
  `cargo test`, `go test`, `make test|check`, `ctest`, `tox`) → **test**;
- a failed call → an **error** entity keyed by its first error line;
- an install's or a test's outcome and every exit status → a **claim** in
  state `reproduced` (the harness saw it); `note` adds `unverified` claims;
- reasoning → its own record under its step, never shown unless expanded;
- `spawn` → a **thread**, one per spawn call, keyed to the child's agent id;
  when an `await` result carries that child's answer, the thread is updated
  with it (its stub reads `-> agent N returned at step M: <first line>`, or
  `failed`, and `expand` shows the whole answer), even when the spawn was
  collapsed at an earlier compaction. A child's report is also recorded when
  the child exits, so its answer reaches the thread when the parent reads it
  only through `inbox` or never reads it (the stub then has no step:
  `-> agent N returned: ...`).

Steps are cut into **spans** at a shift in the entities being touched, at the
end of a retry run, at a spawn, at a new request, or at 12 steps / 8k tokens.

The first message becomes the **outline**: the request, then one line per
span, file, package, test, error, thread, repeated command and claim (exit
status claims are left out; they repeat their command's line), each with its
id. It is rebuilt only at a compaction, so between compactions the system
prompt, tools and outline are a byte-identical prefix and prompt caches keep
hitting; expansions are appended to the tail. Over its budget (8k tokens or
15% of the threshold) the least useful lines go first and a count says so.

## The live tail

Steps do not wait for a compaction to reach the graph. After each tool round
the harness ingests the round (and any prompt before it) as **live** steps:
their step, entity, claim and thread records are written at once, in one
`put_nodes`, so `graph_recall` and `expand` find what the tail did before
anything has been compacted. Live records are not collapsed: the outline does
not list them and auto-expand does not pick them (they are in full in the
tail), and the outline itself is not touched between compactions. The
compaction that later collapses those steps reuses their records rather than
ingesting the messages again. The live steps are kept as ranges of step
numbers in the graph's state (one JSON value under the meta key `graph`, with
the graph's counters and a fork's parent chain), and each step record carries
its step key, so this also holds after a resume. Core reads that state once
per process and writes it at most once per round, so a round costs one
`put_nodes` and one `meta` write, whatever the conversation's length.

Text that joins a step after its round was ingested (mid-turn steering, or
a prompt, merged into the round's tool-results message) is not lost: the next
live ingest, or the compaction that collapses the step, puts the step's record
again with the text in its body (`user (mid-turn):`) and raw messages, same id
and seq. The text stays with the step it was merged into, which is where the
transcript has it.

## Tools

| tool | does |
|---|---|
| `expand{id}` | a record in full: a span's steps, a step's messages and saved output, a file's versions and the steps that touched it |
| `graph_recall{query, limit?}` | text search over the records; stub lines with ids, newest first |
| `note{text, about?}` | an unverified claim, linked to a record or file path when given |

Offered only on a graph tier, after the base tool list (and in the `coding`
profile when it is on). None needs approval: they read or add to the
conversation's own graph. (`recall` is taken by durable memory.)

After each tool round the harness expands up to two collapsed records the
newest step names (an exact repeated error first, then a file path, then a
package), within about 4k tokens, as a marked `[harness: auto-expanded ...]`
text block on that round's results.

## Forks

A forked child (`spawn{fork=true}`) starts with its parent's outline, whose ids
name records in the parent's graph. The child reads through to the parent's
graph for ids it does not hold itself: `expand`, `graph_recall`, auto-expand and
the child's own later outlines see the parent's records as they were at the
fork (records the parent puts afterwards are not visible, and a parent entity
or thread the parent changes in place afterwards reads as it was at the fork). The view is
read-only: the child's notes and compactions go to its own graph, and a note
about a parent record names it in its frontmatter (`subject`, `subject_graph`)
without a link. The chain is stored in the child's graph state
(meta key `graph`), so it survives a resume; a child on a different backend
from its parent gets no view.

The child's copied transcript begins with the parent's live steps. Those stay
the parent's: the child's live ingest and its compactions match them, by step
key, against the parent's live steps at the fork and do not ingest them again,
so the child's first round ingests only that round. Until a compaction of the
child's collapses them they are live in the child's view too (in full in its
tail, not listed or auto-expanded); after it, their records are listed in the
child's outline as inherited lines. They are in no span of the child's graph.

## Backends

Storage sits behind a port, `lua/ctxgraph/backend.lua`: `put_nodes`,
`put_edges`, `get`, `children`, `referrers`, `versions`, `scan`, `search`,
`record_claim`, `set_claim_state`, `meta`, `export_bundle`. Records are
LOKF-shaped (id, type, title, stub, typed links, frontmatter, body or
body_ref, digest, claim state). A backend is registered with
`require("ctxgraph").register_backend(name, impl)`, or shipped as a module
`ctxgraph.backends.<name>` on the Lua path (`~/.boggart/lua/ctxgraph/backends/<name>.lua`)
that registers itself or returns its implementation. `tests/ctxgraph_backend.lua`
is the contract test; `BOGGART_GRAPH_CONTRACT=<name>` runs it against any
backend.

## Export

```sh
./boggart --eval tools/graph_export.lua -- <session-id> <out-dir> [backend]
```

writes one Markdown file per record (YAML frontmatter: id, type, title, stub,
digest, state, links by edge type, fields; then the body) and validates the
bundle: every file parses and every link resolves inside it. It prints one
JSON line `{ session, dir, files, links, ok, errors }`.

## Telemetry

| where | what |
|---|---|
| `sess.usage.graph` | `{ compactions, outline_bytes = {...per compaction}, expands_model, expands_harness, recalls, notes }` |
| events | `graph:compacted { session, compaction, steps, spans, records, outline_bytes, outline_lines, dropped }`, `graph:expand { session, id, by, bytes }`, `graph:recall { session, query_bytes, hits }`, `graph:note { session, id, about }`; `context:compacted` gains `mode` and `outline_bytes` |
| store `records` table | one row of kind `graph` per event above, payload `{ event, ... }`, stamped with run/agent ids like the turn spans (`lua/telemetry.lua`) |
