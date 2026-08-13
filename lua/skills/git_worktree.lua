-- skill: git_worktree -- isolate parallel agents in their own git worktrees, and
-- checkpoint every turn so any change is reversible.
--
-- The git *tooling* is the C `git` capability (src/lgit.c): checkpoints only ever
-- write hidden refs under refs/boggart/, and the worktree lifecycle is fixed
-- below the line the agent can rewrite -- a safety net the agent cannot cut. This
-- skill is the *policy* over that tooling, in Lua: when to branch work into a
-- worktree, and the discipline of always tearing one down.
return {
  description = "Run parallel work in isolated git worktrees, with per-turn checkpoints.",
  instructions = [[
Use this when several sub-agents will edit the same repository at once, or when a
change is risky and you want a clean undo.

Isolation (worktrees), via the `worktree` tool:
- Give each concurrent sub-agent its OWN worktree: `worktree op=add path=<dir>`
  makes a separate checkout that cannot collide with the main tree or another
  agent's. Have the child work only inside its worktree.
- ALWAYS tear one down when the child is done or has failed: `worktree op=remove
  path=<dir>`. A leaked worktree is a mess for the user. If you added it, you
  remove it -- including on error.
- `worktree op=list` shows what is checked out where.
- When agents must share ONE tree instead, coordinate with the claim/release
  tools (the shared edit blackboard) so two agents do not write one file at once.

Checkpoints (undo), via the `checkpoint` / `restore` / `git_diff` tools:
- Before a risky edit, and at the end of a turn, run `checkpoint label=<name>`.
  It snapshots the whole tree (including new files) to a hidden ref and touches
  nothing else -- not HEAD, not your branch, not the index -- and returns a sha.
- To undo, `restore sha=<sha>` resets the working tree to that checkpoint without
  rewriting history. `git_diff ref=<sha>` shows what changed since.
- Checkpoints live under refs/boggart/ and are invisible to `git branch`, so they
  never clutter the user's history.

Keep the user's own git workflow intact: do not commit to their branches, move
HEAD, or force-push as part of this skill. Checkpoints and worktrees are yours to
manage; the user's commits are theirs.
]],
  tools = {
    "checkpoint", "restore", "git_diff", "worktree",
    "read", "write", "edit", "bash", "list",
    "claim", "release", "claims",
    "spawn", "await", "send",
  },
}
