-- gittools.lua -- the model-facing tools over the C `git` capability.
--
-- The git tooling itself is C (src/lgit.c, the `git` global): spawning git,
-- the refs/boggart/ ref policy, the untracked-safe checkpoint. These are the
-- thin Lua wrappers that put that capability in front of the MODEL as ordinary
-- tools (the model calls tools, not C functions), gated by the git_worktree
-- skill. Keep them thin: the policy lives in C, on purpose, where the agent
-- cannot rewrite the safety net.
local M = {}

-- boggart runs in the project directory, so "." is the repo. A future workspace
-- capability can widen this to an explicit root.
local function repo() return "." end

local function have_git()
  return type(_G.git) == "table" and type(_G.git.checkpoint) == "function"
end

local function sanitize(label)
  if type(label) ~= "string" or label == "" then return tostring(os.time()) end
  return (label:gsub("[^%w_%-%.]", "_"))
end

M.tools = {
  checkpoint = {
    description = "Snapshot the whole working tree (including new files) to a hidden "
      .. "git ref, so this point is restorable. Touches nothing else -- not HEAD, not "
      .. "your branch, not the index. Returns a sha. Take one before a risky edit and "
      .. "at the end of a turn.",
    input_schema = { type = "object",
      properties = { label = { type = "string", description = "a name for this checkpoint" } } },
    run = function(a)
      if not have_git() then return "Tool error: [host_capability_error] git capability unavailable" end
      local ref = "refs/boggart/checkpoints/" .. sanitize(a.label)
      local sha, err = git.checkpoint(repo(), ref)
      if not sha then return "Tool error: [host_capability_error] " .. tostring(err) end
      return string.format("checkpoint '%s' -> %s (%s)", sanitize(a.label), sha:sub(1, 12), ref)
    end,
  },

  restore = {
    description = "Undo: reset the working tree to a checkpoint sha (or any git ref) "
      .. "without rewriting history or moving your branch. Use checkpoint first, and "
      .. "git_diff to see what would change.",
    input_schema = { type = "object",
      properties = { sha = { type = "string", description = "a checkpoint sha or ref" } },
      required = { "sha" } },
    run = function(a)
      if not have_git() then return "Tool error: [host_capability_error] git capability unavailable" end
      if type(a.sha) ~= "string" then return "Tool error: [validation_error] restore requires 'sha'" end
      local ok, err = git.restore(repo(), a.sha)
      if not ok then return "Tool error: [host_capability_error] " .. tostring(err) end
      return "restored working tree to " .. a.sha:sub(1, 12)
    end,
  },

  git_diff = {
    description = "Show what changed in the working tree versus a checkpoint sha, a "
      .. "ref, or HEAD (the default).",
    input_schema = { type = "object",
      properties = { ref = { type = "string", description = "sha/ref to diff against (default HEAD)" } } },
    run = function(a)
      if not have_git() then return "Tool error: [host_capability_error] git capability unavailable" end
      local out, code = git.diff(repo(), a.ref)
      if out == nil then return "Tool error: [host_capability_error] " .. tostring(code) end
      return out ~= "" and out or "(no differences)"
    end,
  },

  worktree = {
    description = "Isolate parallel work: op=add makes a separate checkout at 'path' "
      .. "(from 'ref', default HEAD) that cannot collide with other agents; op=remove "
      .. "tears one down (always remove what you add); op=list shows current worktrees.",
    input_schema = { type = "object",
      properties = {
        op = { type = "string", description = "add | remove | list" },
        path = { type = "string" },
        ref = { type = "string" },
      }, required = { "op" } },
    run = function(a)
      if not have_git() then return "Tool error: [host_capability_error] git capability unavailable" end
      if a.op == "list" then
        local out, code = git.worktree_list(repo())
        if out == nil then return "Tool error: [host_capability_error] " .. tostring(code) end
        return out ~= "" and out or "(no worktrees)"
      elseif a.op == "add" then
        if type(a.path) ~= "string" then return "Tool error: [validation_error] add needs 'path'" end
        local ok, err = git.worktree_add(repo(), a.path, a.ref or "HEAD")
        if not ok then return "Tool error: [host_capability_error] " .. tostring(err) end
        return "worktree added at " .. a.path
      elseif a.op == "remove" then
        if type(a.path) ~= "string" then return "Tool error: [validation_error] remove needs 'path'" end
        local ok, err = git.worktree_remove(repo(), a.path)
        if not ok then return "Tool error: [host_capability_error] " .. tostring(err) end
        return "worktree removed at " .. a.path
      end
      return "Tool error: [validation_error] op must be add | remove | list"
    end,
  },
}

return M
