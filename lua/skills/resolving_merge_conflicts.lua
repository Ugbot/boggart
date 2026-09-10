-- skill: resolving_merge_conflicts -- finish in-progress merge/rebase (model-invoked).
-- Adapted from mattpocock/skills engineering/resolving-merge-conflicts.
return {
  description = "Resolve an in-progress git merge or rebase conflict hunk by hunk "
    .. "by intent; never --abort. Use when git reports conflicts.",
  invocation = "model",
  fallback = "core",
  tools = { "read", "write", "edit", "bash", "list", "git_diff" },

  -- before: is a merge/rebase even in progress, and which files conflict? Both
  -- are code (git status --porcelain). No conflict -> short-circuit with zero
  -- model turns; otherwise thread the conflicting files into the turn.
  before = function()
    local status = bog.C("bash")({ command = "git status --porcelain=v1 2>/dev/null" })
    local conflicts = {}
    for line in tostring(status):gmatch("[^\n]+") do
      -- porcelain conflict codes: UU DD AU UA DU UD AA
      local xy, path = line:match("^(..) (.+)$")
      if xy and xy:match("[UDA][UDA]") and (xy == "UU" or xy == "AA" or xy == "DD"
          or xy == "AU" or xy == "UA" or xy == "DU" or xy == "UD") then
        conflicts[#conflicts + 1] = path
      end
    end
    if #conflicts == 0 then
      return { done = "no merge/rebase conflict in progress (git status is clean of unmerged paths)" }
    end
    return { set = { conflicts = conflicts } }
  end,

  -- verify: the tree carries no conflict markers and git sees no unmerged
  -- paths. Runs as code in finally, so a "done" that left markers behind
  -- raises instead of passing.
  verify = function()
    local check = bog.C("bash")({ command =
      "git diff --check 2>/dev/null; git ls-files -u 2>/dev/null | head -1" })
    if type(check) == "string" and check:match("%S") then
      return "conflict markers or unmerged paths remain:\n" .. check
    end
    return true
  end,

  instructions = function(ctx)
    local files = (ctx and ctx.conflicts) or {}
    local list = #files > 0 and ("Conflicting files: " .. table.concat(files, ", ") .. ".")
      or "See `git status` for conflicting files."
    return [[
# Resolving Merge Conflicts

Always resolve; never `git merge --abort` / `git rebase --abort` unless the user
explicitly asks to abandon.

]] .. list .. [[


## STEP 1 — Understand each side
For each conflict, understand why each change was made (commit messages, PRs,
issues). Do not invent new behaviour.

## STEP 2 — Resolve hunk by hunk
Preserve both intents where possible. Where incompatible, pick the one matching
the merge's stated goal and note the trade-off in a short comment or the final
summary. Stage resolved files as you go.

## STEP 3 — Automated checks
Discover the project's checks (typecheck, tests, format) and run them with
`bash`. Fix anything the merge broke.

## STEP 4 — Finish
Stage everything and complete the merge/rebase (`git commit` / `git rebase
--continue`) until clean. Summarize conflicts resolved and checks run.
]]
  end,
}
