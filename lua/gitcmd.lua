-- gitcmd.lua -- deterministic slash commands for common git tasks, with a MODEL
-- FALLBACK: run the plain git command directly (fast, no tokens), and only when
-- it fails hand the situation to the agent to resolve. Simple stuff stays simple;
-- the model is spent only when there is actually judgement to apply (a rejected
-- push, a rebase conflict, a missing commit message).
--
-- run(name, arg) returns one of:
--   { text = "..." }   -- show this and we're done
--   { run  = "prompt" } -- hand this prompt to the front-end's turn driver
--   nil                 -- not a git command handled here
local M = {}

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function trim(s) return (tostring(s or ""):gsub("%s+$", "")) end

function M.run(name, arg)
  arg = trim(arg)

  if name == "status" then
    return { text = trim(sys.exec("git status --short --branch", 30).out) }

  elseif name == "diff" then
    local o = trim(sys.exec("git --no-pager diff " .. arg, 30).out)
    return { text = o ~= "" and o or "(no unstaged changes)" }

  elseif name == "commit" then
    if arg == "" then
      -- no message given: this genuinely needs judgement, so go straight to the
      -- model to write one from the diff and commit.
      return { run = "Stage all changes (git add -A) and commit them with a "
        .. "concise, conventional commit message you write from the diff. "
        .. "Then show `git log --oneline -1`." }
    end
    local r = sys.exec("git add -A && git commit -m " .. shq(arg), 60)
    if r.code == 0 then return { text = trim(r.out) } end
    return { run = "This git commit failed:\n\n" .. trim(r.out)
      .. "\n\nResolve it and commit the staged changes with this message: " .. arg }

  elseif name == "push" then
    local r = sys.exec("git push " .. arg, 120)
    if r.code == 0 then return { text = "pushed.\n" .. trim(r.out) } end
    return { run = "git push failed:\n\n" .. trim(r.out)
      .. "\n\nDiagnose and resolve it -- set the upstream, pull --rebase if the "
      .. "remote moved, or tell me exactly what to do." }

  elseif name == "sync" then
    local r = sys.exec("git pull --rebase " .. arg, 120)
    if r.code == 0 then return { text = "synced.\n" .. trim(r.out) } end
    return { run = "git pull --rebase failed:\n\n" .. trim(r.out)
      .. "\n\nResolve it (conflicts, a diverged branch, etc.) so the branch is up to date." }
  end

  return nil
end

M.commands = { "status", "diff", "commit", "push", "sync" }

return M
