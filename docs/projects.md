# boggart — projects

**Status: plan, agreed 2026-09-04.** The intent below was settled by interview,
not inferred; where a decision is still open it says so and proposes one.

## Context

Everything boggart knows is global. Memory is one FTS5 table, sessions are one
table, skills are files in one directory, search is whatever repo you happen to
be standing in. That is fine with one body of work and wrong with two: ask about
a character and you get another story's cast, ask about "the auth module" and you
get the wrong codebase. It gets worse the more boggart remembers, which is the
opposite of how memory should age.

A **project** is the unit of context. It owns roots, and it scopes what boggart
knows and where it works.

## The model

- A project is **named**, not a directory. It owns **zero or more roots**
  (directories). Where a root is a git repo, git is used — worktrees, status,
  checkpoints — and where it is not, everything else still works. A story
  project is as real as a codebase.
- **`global` is itself a project**, not a separate tier: it is the loose chat
  you have when you are not working on anything in particular.
- **Every project can read `global`; no project can read another project.**
  Results from the current project rank above results from `global`, and a
  `global` hit is labelled as such so you can see where an answer came from.
- The current project defaults to **`global`**. You are never forced to create
  one, and someone who never says the word "project" gets today's behaviour with
  one name attached to it.

### The `global` leak, acknowledged

If `global` is loose chat, real project content will land in it, and a later
project can surface it. That is **accepted**: ranking handles it (own results
first, `global` labelled and below), and the remedies are the operations below —
assign that chat to a project, or forget the memory.

## What a project scopes

| Thing | Scoping | Default for new items |
|---|---|---|
| **Memory** | project-only, `global` readable underneath | the current project; promotion to `global` is explicit |
| **Chats / sessions** | belong to one project | the current project; **reassignable** |
| **Skills** | a skill lists the projects it serves | global unless keyed to a project |
| **Tools** | already project-scoped (`tools_dir("project")`) — unify onto project identity | current project |
| **Search / `code_index`** | over the project's roots | — |
| **Roots and worktrees** | the project owns them; a worktree added for a branch becomes another root | — |

## Storage: one home, one direction

The rule from the model catalog holds: **the store is the truth, a file is the
exchange format.** Schema in `lua/store.lua`, operations in `src/lrepo.c` — the
seam that file exists for.

```sql
projects(name TEXT PRIMARY KEY, label, roots TEXT /*json*/, created, updated)
-- existing tables gain a project column
sessions(..., project TEXT)      -- reassignable; NULL means global
memory(...,   project TEXT)
-- and a skill names the projects it serves, rather than a join table
skills(key TEXT PRIMARY KEY, ..., projects TEXT /*json list*/)
```

**No join table.** A skill carries its project list; nothing carries a skill
list. One direction of reference, one place to edit, no pair of foreign keys to
drift apart.

## The manifest: how a project travels

Skills stay in boggart. The repo carries a **shopping list**, so a project
brings its skills back on another machine.

`.boggart/project.json`, committable and diffable:

```json
{ "name": "nightjar",
  "roots": ["."],
  "skills": ["nightjar-voice", "tdd"],
  "tools":  ["scene-lint"] }
```

On opening a project boggart **reconciles** and reports:

```
nightjar expects 3 skills — have tdd; missing nightjar-voice, scene-lint
```

It **never auto-installs** and **never writes skill bodies into your repo**.
That report is precisely the shopping list the future sync tooling consumes.

Prose instructions stay where they already are (`CLAUDE.md` / `BOGGART.md`, via
`lua/claudemd.lua`); the manifest is machine-readable and is not a second place
to write English.

## Roots as the boundary

A project's roots are where it works: `code_index`/`code_search` cover them,
`@file` completes within them, `bash` starts in the first one.

**Enforcement reuses what exists** rather than inventing a second mechanism:
`perm.lua`'s `external_directory` guard already asks before touching anything
outside the workspace. Projects supply *what the workspace is*; the permission
engine remains the thing that refuses. No new C.

## Operations the interview named

- **Assign a chat to a project** — retroactive; a session moves, its memories
  move with it.
- **Forget, scoped to a project** — remove a memory (or a match) from this
  project without touching `global` or anything else.
- **Promote a memory to `global`** — the only way project knowledge becomes
  universal.

## Surfaces (all three)

| Surface | Switch | See it |
|---|---|---|
| REPL | `/project` (list), `/project <name>`, `/project new <name> [root…]` | the prompt line |
| cTUI | the same `/project`, plus the footer | footer segment |
| studio | a status-bar element opening the **anchored dropdown** (`core/menu.lua`, with headings + hints — already built) | status bar; the recents rail filters to the project |
| control plane | `GET /projects`, `POST /projects`, `POST /projects/<name>/adopt` | — |

**Open decision (proposed):** when `cd` lands inside exactly one project's
roots, switch to it automatically; when it matches several or none, stay put and
say so. Flag if you would rather switching were always explicit.

## Migration

Everything that exists today becomes `global`: sessions, memories, and the
current digest-keyed project tool directories are adopted rather than moved.
Nothing is split retroactively — you move what you care about with the assign
operation. A store from a newer boggart is already refused by `store.lua`.

## Phases

1. **Tables + ops** — `projects`, the `project` columns, `skills.projects`; C
   operations; migration to `global`. Invisible.
2. **Current project + resolution** — memory/session reads and writes honour it;
   `global` fallback with own-first ranking.
3. **Roots** — search, `@file` and `bash` follow the project; worktrees register
   as roots.
4. **Skills + manifest** — project-keyed skills, `.boggart/project.json`, the
   reconcile report.
5. **Operations** — assign, forget, promote.
6. **Surfaces** — `/project`, the footer, the studio dropdown and filtered rail,
   the control routes.

## Verification

- `tests/projects.lua` — creation, roots, current-project resolution, the
  `global` fallback and its ranking, "no project can read another".
- Memory: a project write is invisible to a sibling project and visible to
  neither before promotion nor after forgetting.
- Sessions: assignment moves a chat and its memories; the recents list filters.
- Manifest: reconcile reports present/missing without installing anything;
  round-trips through export/import.
- Migration: an existing store lands wholly in `global` with nothing lost.
- `ctest` in full, plus `core-parity` and `ui-discover` (new commands need menu
  homes).

## Out of scope

The sync-between-machines tooling itself; auto-installing missing skills;
per-project model configuration; multi-user or team projects; retroactively
splitting existing history.
