-- skill: handoff -- compact the session into a handoff doc for a fresh agent.
-- Ported from ai-grind handoff. The token-heavy part, gathering git state, runs
-- as CODE in before and is handed to the model, so the model spends its turn
-- writing the narrative rather than issuing a dozen git calls to reconstruct it.
return {
  description = "Write a handoff document for a fresh agent or session: what "
    .. "changed, where things stand, what to do next. Use when context is "
    .. "running out or handing work to someone else.",
  invocation = "model",
  fallback = { "core", "memory" },
  tools = { "bash", "read", "git_diff", "write" },

  before = function()
    local bash = bog.C and bog.C("bash")
    if not bash then return {} end
    local function sh(c)
      local out = bash({ command = c })
      if type(out) ~= "string" or out:find("^Tool error:") then return "" end
      return (out:gsub("^%[exit=%-?%d+[^%]]*%]%s*", "")):gsub("%s+$", "")
    end
    local branch = sh("git rev-parse --abbrev-ref HEAD 2>/dev/null")
    if branch == "" then return {} end
    local state = {
      branch = branch,
      status = sh("git status --short 2>/dev/null"),
      stat = sh("git diff --stat HEAD 2>/dev/null | tail -25"),
      recent = sh("git log --oneline -10 2>/dev/null"),
    }
    return { set = { git = state } }
  end,

  instructions = function(ctx)
    local g = ctx and ctx.git
    local block = g and (([[
Branch: %s
Uncommitted:
%s
Diffstat vs HEAD:
%s
Recent commits:
%s]]):format(g.branch, g.status ~= "" and g.status or "(clean)",
             g.stat ~= "" and g.stat or "(none)", g.recent))
      or "Gather git state yourself (branch, status, recent commits)."
    return [[
# Session handoff

Git state (already gathered in code):
]] .. block .. [[


Write a handoff doc a fresh agent can act on with no other context:
1. Goal and current status in two or three sentences.
2. What changed and why, keyed to the diffstat above.
3. The next concrete step, and any trap or open question.
4. Suggested skills or files to read first.
Redact any secret or key before writing. Save to `.scratch/handoff-<date>.md`
and reply with the path.
]]
  end,
}
