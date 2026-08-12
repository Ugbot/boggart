# Workspace — git for coders, the same safety without it

Agentic tools are built for coders: they assume a git repo, and their whole
safety story (undo, review, branch isolation) is git. boggart wants to serve both
domains (`comparisons.md` §4) — a coder in a repo *and* a non-coder in a folder of
contracts, spreadsheets and notes — so it needs those guarantees for **both**,
and the non-coder must never have to learn git to get them. **That is the massive
gap in other tools, and closing it is the point of this document.**

The move: treat what git gives a coder as four **capabilities**, not one tool,
and give each a git backend *and* a git-free backend behind one interface. A
non-coder gets versioned, undoable, collision-safe editing of ordinary files;
git is simply the backend that kicks in when there's a repo.

| Capability | git backend (a repo) | git-free backend (any folder) |
|---|---|---|
| **Isolation** — agents don't share a tree | a **worktree per agent** | a per-agent working copy (shadow dir) or a scoped subtree |
| **Checkpoint / undo** — turn it back | hidden-ref snapshot per turn | content-addressed snapshot of touched files in the store |
| **Review** — what changed | `git diff` vs the checkpoint | line diff of snapshot vs current |
| **Collision-avoidance** — two agents, one file | worktrees (physical) + claims | **claims** (the shared edit blackboard) |

Same tools regardless of backend: `checkpoint` / `restore` / `history` / `diff`
and `claim` / `release` / `claims`. A `workspace` capability detects the backend
(`.git` present → git; else → snapshots) and dispatches. The coder gets native
git semantics; the non-coder gets the same safety and never sees a commit.

---

## 1. Collision-avoidance — the shared edit blackboard (built)

`lua/claims.lua` ships now, with `tests/claims.lua`. It is the backend-agnostic
piece, so it was built first: a shared, in-process registry of which agent is
editing which file. In a swarm the actors are coroutines in one process, so the
registry is genuinely shared between them.

- `claim(path, mode)` — `write` is exclusive, `read` is shared; a conflict
  returns the current holder so the agent picks other work instead of colliding.
- `release(path)` / `release_all(agent)` — the latter wired to
  `swarm:actor_stopped` so a dead agent never holds a file hostage.
- Paths are normalised so `./src/a` and `src/a` are the same claim.

It is **advisory** — it coordinates, it does not physically lock. Physical
isolation is a worktree (§2). Claims cover what worktrees do not: agents
deliberately sharing one tree, and **non-git files, where there are no worktrees
to hand out** — which is exactly the non-coder case. This is the shared sibling
of the per-agent blackboard (`lua/blackboard.lua`): that one holds an agent's
private beliefs, this one holds the shared truth every agent reads.

*Next:* have the `edit`/`write` tools auto-claim (write) the path and warn on a
foreign holder, and refresh on the `file:write`/`file:edit` events.

---

## 2. Isolation — a git worktree per agent (gold skill)

For code, the strongest collision-avoidance is that agents never share a working
directory. A worktree gives each swarm child its own checkout of the same repo;
they cannot step on each other, and results merge back through git. The plumbing
is verified (see §4). This becomes a **gold skill** plus a `gold.git` helper:

- **`gold.git`** — a blessed helper over `sys.exec("git ...")`: `worktree_add`,
  `worktree_remove`, `checkpoint`, `restore`, `diff`, `current_branch`,
  `is_repo`. Blessed because model-written tools should compose one careful git
  wrapper, not re-shell `git` a dozen inconsistent ways (the `gold` doctrine).
- **`skills/git_worktree.lua`** — a skill bundle (instructions + a permitted tool
  set) for the coordinator↦child pattern: coordinator opens a worktree per child,
  each child works isolated in its own directory, the coordinator collects/merges
  and removes the worktree. The skill encodes the *lifecycle* (add → work →
  collect → remove, and always remove on failure) so an agent cannot leak
  worktrees.

Worktrees and claims compose: worktrees remove collisions *physically* for code;
claims coordinate the cases that remain (a shared tree, or non-git files).

---

## 3. Checkpoint / undo — the same guarantee, two backends

Every turn ends with a checkpoint so any change is reversible — the idea worth
borrowing from t3code, generalised so it does not require git.

- **git backend (verified).** Snapshot the working tree to a **hidden ref**
  (`refs/boggart/checkpoints/<session>/<turn>`) without touching HEAD, the branch,
  the index or the working tree — via `git stash create` (or, to include
  untracked files, a temp-index `git add -A` + `write-tree` + `commit-tree`; see
  the caveat in §4). Store the sha per turn in the session/journal. `restore`
  checks the tree out from that sha; `diff` diffs against it. Hidden refs keep
  `git branch` and the user's history clean.
- **git-free backend.** For a folder with no repo, a checkpoint is a manifest of
  `path → content-hash` for the files a turn touched, with contents
  content-addressed into the store (SQLite blobs / the data dir). `restore`
  rewrites those files; `diff` is a line diff of the snapshot against current.
  Touched-only keeps it cheap; the journal already records what a turn wrote
  (`file:write`/`file:edit` events carry the paths), so the manifest is nearly
  free.

Both surface as the same `checkpoint`/`restore`/`history`/`diff` tools. The
non-coder types "undo the last change" or "what changed since this morning" and
never learns that one backend is git and the other is a blob store.

---

## 4. Verified plumbing

Run against a throwaway repo, so the gold skill rests on real commands:

- **Non-destructive checkpoint**: `git stash create` captures the dirty tree to a
  commit object; `git update-ref refs/boggart/ckpt/<id> <sha>` stores it. HEAD,
  the branch, the index and the working tree are all untouched, and the ref does
  **not** appear in `git branch -a`.
- **Restore**: `git restore --source=<sha> --worktree --staged -- .` returns the
  tree to the checkpoint (including re-adding a file deleted since).
- **Diff**: `git diff <sha>` / `--stat` against the checkpoint.
- **Worktree**: `git worktree add/list/remove` create and tear down an isolated
  checkout cleanly.
- **Caveat**: `git stash create` captures tracked + staged changes but **not
  purely-untracked files**. To checkpoint a brand-new file, snapshot through a
  temp index (`GIT_INDEX_FILE=<tmp> git add -A && git write-tree && git
  commit-tree`) instead — `gold.git.checkpoint` should do this so "undo" never
  silently drops a newly-created file.

---

## 5. The non-coder experience (why this matters)

Concretely, a non-coder points boggart at `~/Contracts/` and says "tidy up the Q3
agreements." With this layer and *no git, no repo, no commits*:

- every turn is checkpointed, so "undo that" and "put the pricing table back how
  it was" just work;
- "what did you change?" is a plain diff;
- if two agents run (one normalising formatting, one fixing figures), the **claims
  blackboard** stops them both writing `invoice-Q3.xlsx` at once;
- nothing above required the user to know what a branch, a commit, or a worktree
  is.

That is the capability parity: the safety a coder takes for granted, delivered to
someone who has never opened a terminal — which is the part other agentic tools,
being git-first, simply do not offer.

---

## 6. Status and phasing

- **Built:** `lua/claims.lua` + `tests/claims.lua` — the shared edit blackboard,
  backend-agnostic. Git checkpoint/worktree plumbing verified (§4).
- **Next (git backend):** `gold.git` helper; the `checkpoint`/`restore`/`diff`
  tools over hidden refs; the `git_worktree` gold skill for swarm isolation;
  auto-claim on `edit`/`write`.
- **Then (git-free backend):** the snapshot store (touched-file manifests,
  content-addressed) behind the same tools; backend auto-detection in a
  `workspace` capability.
- **Later:** studio surfaces — a per-turn checkpoint timeline with restore, and a
  live view of the claims blackboard during a swarm run (`draw_panel`).
