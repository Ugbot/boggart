-- skill: resolving_merge_conflicts -- finish in-progress merge/rebase (model-invoked).
-- Adapted from mattpocock/skills engineering/resolving-merge-conflicts.
return {
  description = "Resolve an in-progress git merge or rebase conflict hunk by hunk "
    .. "by intent; never --abort. Use when git reports conflicts.",
  invocation = "model",
  fallback = "core",
  tools = { "read", "write", "edit", "bash", "list", "git_diff" },
  instructions = [[
# Resolving Merge Conflicts

Always resolve; never `git merge --abort` / `git rebase --abort` unless the user
explicitly asks to abandon.

## STEP 1 — See state
`git status`, list conflicting files, skim recent history (`git log --oneline`).

## STEP 2 — Primary sources per side
For each conflict, understand why each change was made (commit messages, PRs,
issues). Do not invent new behaviour.

## STEP 3 — Resolve hunk by hunk
Preserve both intents where possible. Where incompatible, pick the one matching
the merge's stated goal and note the trade-off in a short comment or the final
summary. Stage resolved files as you go.

## STEP 4 — Automated checks
Discover the project's checks (typecheck, tests, format) and run them with
`bash`. Fix anything the merge broke.

## STEP 5 — Finish
Stage everything and complete the merge/rebase (`git commit` / `git rebase
--continue`) until clean. Summarize conflicts resolved and checks run.
]],
}
