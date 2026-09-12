-- skill: finish_branch -- integrate finished work: merge, PR, or clean up.
-- Ported from ai-grind finishing-a-development-branch. The git-environment
-- detection and the "is there anything to finish" check run as CODE in before,
-- so the model is handed the right menu instead of probing for it turn by turn.
return {
  description = "Finish a development branch: verify tests, then merge, open a "
    .. "PR, or clean up. Use when the work is complete and needs integrating.",
  invocation = "model",
  fallback = { "core", "git_worktree" },
  tools = { "bash", "read", "git_diff" },

  -- Detect the workspace and whether there is anything to finish. Pure git
  -- reads, each guarded so a non-repo degrades to a prose fallback.
  before = function()
    local bash = bog.C and bog.C("bash")
    if not bash then return {} end
    local function sh(c)
      local out = bash({ command = c })
      if type(out) ~= "string" or out:find("^Tool error:") then return "" end
      return (out:gsub("^%[exit=%-?%d+[^%]]*%]%s*", "")):gsub("%s+$", "")
    end
    local branch = sh("git rev-parse --abbrev-ref HEAD 2>/dev/null")
    if branch == "" then
      return { done = "not a git repository; nothing to finish here." }
    end
    -- Worktree vs plain repo: the two git dirs differ inside a worktree.
    local gd = sh("cd \"$(git rev-parse --git-dir)\" 2>/dev/null && pwd -P")
    local gc = sh("cd \"$(git rev-parse --git-common-dir)\" 2>/dev/null && pwd -P")
    local worktree = (gd ~= gc and gc ~= "")
    -- Base branch: prefer main, else master.
    local base = sh("git rev-parse --verify -q main >/dev/null && echo main "
      .. "|| (git rev-parse --verify -q master >/dev/null && echo master)")
    if base == "" then base = "main" end
    local ahead = "0"
    if branch ~= base then
      ahead = sh("git rev-list --count " .. base .. ".." .. branch .. " 2>/dev/null")
      if ahead == "" then ahead = "0" end
    end
    if branch == base then
      return { done = "on the base branch '" .. base .. "'; make a feature branch first." }
    end
    if ahead == "0" then
      return { done = "'" .. branch .. "' has no commits ahead of '" .. base
        .. "'; nothing to finish." }
    end
    return { set = { branch = branch, base = base, ahead = ahead, worktree = worktree } }
  end,

  instructions = function(ctx)
    ctx = ctx or {}
    local head = ctx.branch and (("Branch `%s`, %s commit(s) ahead of `%s`%s.")
      :format(ctx.branch, ctx.ahead or "?", ctx.base or "main",
              ctx.worktree and ", in a worktree" or ""))
      or "Detect the branch, base, and whether you are in a worktree."
    return [[
# Finish a development branch

]] .. head .. [[


1. Verify first. Adopt `verify_complete` (or run the test command) and confirm
   green. If tests fail, stop and report the failures. Do not proceed.
2. Present the integration options for this environment and let the user pick:
   - Merge into the base branch (fast-forward or no-ff).
   - Open a PR (push the branch, `gh pr create`).
   - Keep the branch; clean up scratch files only.
3. Execute the choice. In a worktree, offer to remove the worktree after merge.
   Never delete the base branch or force-push it.
]]
  end,
}
