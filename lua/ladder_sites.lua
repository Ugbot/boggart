-- ladder_sites.lua -- the decision sites that sit on the tier ladder
-- (lua/ladder.lua) outside tool choice (lua/toolroute.lua): swarm supervision,
-- the coding loop's failure triage, tracker classification and the story judge.
--
-- Every site is opt-in (`/ladder on <id>`) and the llm stage of each is exactly
-- what the call site did before, so a site that is off, unkeyed, unsure or
-- erroring behaves as boggart always has. Each wrapper below returns nil when it
-- has nothing to add, and the caller keeps its own default.
--
--   swarm.supervise  a stalled agent: progressing | stuck | looping | done | needs_human
--   coding.verify    a red verification run: code_bug | build_error | environment | flaky
--   tracker.classify kind + priority for a task created without them
--   story.judge      the 1..10 prose rating, jev rubric instead of a model turn
local ladder = require("ladder")

local M = {}

local function clip(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  return s:sub(#s - n + 1) -- the END of an output is where the failure is
end

-- ---- swarm.supervise ---------------------------------------------------------
M.STATUSES = {
  progressing = "making real progress: new files, edits, results, or clear forward steps",
  stuck       = "not making progress: planning or thinking without acting",
  looping     = "repeating the same actions or text without new information",
  done        = "the task looks complete and it is only restating or wrapping up",
  needs_human = "blocked on something only a person can supply: a decision, credentials, access",
}

local function transcript_tail(rec, chars)
  local msgs = rec and rec.session and rec.session.messages or {}
  local out = {}
  for i = math.max(1, #msgs - 6), #msgs do
    local m = msgs[i]
    local t = m.content
    if type(t) == "table" then
      local parts = {}
      for _, b in ipairs(t) do
        if b.type == "text" then parts[#parts + 1] = b.text or ""
        elseif b.type == "tool_use" then parts[#parts + 1] = "[tool " .. tostring(b.name) .. "]"
        elseif b.type == "tool_result" then parts[#parts + 1] = "[result] " .. clip(b.content, 300) end
      end
      t = table.concat(parts, " ")
    end
    out[#out + 1] = tostring(m.role) .. ": " .. clip(t, 600)
  end
  return clip(table.concat(out, "\n"), chars or 3000)
end

-- ---- coding.verify ------------------------------------------------------------
M.FAILURES = {
  code_bug    = "a test or assertion failed because the code under test is wrong",
  build_error = "the code did not compile or the build/config step failed",
  environment = "the machine is the problem: missing tool, path, permission, or network",
  flaky       = "intermittent or timing-related: a timeout, a race, a resource briefly unavailable",
}

local ENV_PATTERNS = { "command not found", "not found: ", "permission denied", "could not resolve host",
  "temporary failure in name resolution", "enotfound", "network is unreachable", "no space left on device",
  "cannot find -l", "no such file or directory.*build" }
local BUILD_PATTERNS = { "compilation terminated", "ninja: build stopped", "syntaxerror", "syntax error",
  "undefined reference", "undefined symbol", "cannot find module", "error%[e%d+%]" }
local FLAKY_PATTERNS = { "timed out", "timeout", "connection reset", "resource temporarily unavailable" }

local function matches(low, pats)
  for _, p in ipairs(pats) do if low:find(p) then return true end end
  return false
end

-- ---- tracker.classify ----------------------------------------------------------
local KIND_RULES = {
  { "^%s*test[%s:]", "test" }, { "^%s*add tests?", "test" }, { "^%s*spike[%s:]", "spike" },
  { "^%s*investigate", "spike" }, { "^%s*research", "spike" }, { "^%s*epic[%s:]", "epic" },
}
M.KINDS = {
  epic = "a large body of work spanning many tasks", story = "a user-visible capability",
  task = "a concrete unit of work", spike = "time-boxed research or investigation",
  test = "writing or fixing tests",
}
M.PRIORITIES = { "P1 drop everything: outage, data loss, security",
  "P2 important and soon", "P3 normal", "P4 nice to have", "P5 someday" }

-- ---- story.judge ----------------------------------------------------------------
M.PROSE_LEVELS = { "1 poor", "2", "3", "4", "5 workable", "6", "7", "8", "9", "10 excellent" }

local defined = false
function M.define()
  if defined then return end
  defined = true

  ladder.define{ id = "swarm.supervise", threshold = 0.8, sample = 0.1,
    help = "classify a stalled agent before nudging it",
    stages = {
      ladder.code(function(ctx)
        local rec = ctx.rec or {}
        if rec.done or rec.exited or rec.status == "done" then return "done" end
      end, "exited"),
      ladder.jev{
        name = "status",
        state = function(ctx) return transcript_tail(ctx.rec, 3000) end,
        questions = { s = { kind = "choice", options = M.STATUSES,
          instructions = "What is this agent doing, judging by the end of its transcript" } },
        map = function(a) return a.s.choice end,
      },
      -- the llm tier IS the existing heuristic: a stalled agent is "stuck"
      ladder.llm(function() return "stuck" end, "heuristic"),
    } }

  ladder.define{ id = "coding.verify", threshold = 0.85, sample = 0.1,
    help = "name why a verification run failed",
    -- the same failure again: the command plus the output's tail with the volatile
    -- bits (numbers, addresses, timings) masked
    key = function(ctx)
      local tail = clip(ctx.output, 300):lower():gsub("0x%x+", "#"):gsub("%d+", "#"):gsub("%s+", " ")
      return tostring(ctx.cmd) .. "|" .. tail
    end,
    stages = {
      ladder.code(function(ctx)
        local low = (ctx.output or ""):lower()
        if matches(low, BUILD_PATTERNS) then return "build_error" end
        if matches(low, ENV_PATTERNS) then return "environment" end
        if matches(low, FLAKY_PATTERNS) then return "flaky" end
      end, "patterns"),
      ladder.jev{
        name = "failure",
        state = function(ctx) return "COMMAND: " .. tostring(ctx.cmd) .. "\nOUTPUT (end):\n" .. clip(ctx.output, 6000) end,
        questions = { f = { kind = "choice", options = M.FAILURES,
          instructions = "Why did this verification command fail" } },
        map = function(a) return a.f.choice end,
      },
      ladder.llm(function() return nil end, "unclassified"),
    } }

  ladder.define{ id = "tracker.classify", threshold = 0.85, sample = 0.1,
    help = "kind and priority for tasks created without them",
    key = function(ctx)
      local t = tostring(ctx.title or ""):lower():gsub("[^%w]+", " ")
      return (ctx.want_kind and "k" or "-") .. (ctx.want_priority and "p" or "-") .. "|" .. t
    end,
    equal = function(a, b)
      return type(a) == "table" and type(b) == "table" and a.kind == b.kind and a.priority == b.priority
    end,
    stages = {
      ladder.code(function(ctx)
        local t = (ctx.title or ""):lower()
        for _, r in ipairs(KIND_RULES) do
          if t:find(r[1]) then return { kind = r[2] } end
        end
      end, "title rules"),
      ladder.jev{
        name = "kind+priority",
        state = function(ctx) return "TITLE: " .. tostring(ctx.title) .. "\nDESCRIPTION:\n" .. clip(ctx.description, 2000) end,
        questions = function(ctx)
          local qs = {}
          if ctx.want_kind then qs.kind = { kind = "choice", options = M.KINDS, instructions = "What kind of work item is this" } end
          if ctx.want_priority then qs.priority = { kind = "score", levels = M.PRIORITIES, minimum = 1,
            instructions = "How urgent is this work item (1 most urgent)" } end
          return qs
        end,
        map = function(a, ctx)
          local out = {}
          if a.kind then out.kind = a.kind.choice end
          if a.priority then out.priority = math.floor(a.priority.score + 0.5) end
          return next(out) and out or nil
        end,
      },
      ladder.llm(function() return nil end, "defaults"),
    } }

  ladder.define{ id = "story.judge", threshold = 0.7, sample = 0.1,
    help = "rate prose 1..10 with a jev rubric instead of a model turn",
    stages = {
      ladder.jev{
        name = "rubric",
        state = function(ctx) return ctx.prose end,
        questions = { r = { kind = "score", levels = M.PROSE_LEVELS, minimum = 1,
          instructions = "Rate this prose as a professional fiction editor would, counting against cliches, "
            .. "unnecessary exposition, purple prose, spelled-out subtext, poor rhythm, lack of specific detail, awkward diction" } },
        map = function(a) return math.max(1, math.min(10, math.floor(a.r.score + 0.5))) end,
      },
      -- the llm tier is the caller's own model call (ctx.call), as before
      ladder.llm(function(ctx)
        if not ctx.call then return nil end
        local ok, t = pcall(ctx.call, ctx.prompt)
        if not ok then return nil end
        local n = tonumber(tostring(t or ""):match("(%d+)"))
        if n and n >= 1 and n <= 10 then return n end
      end, "model"),
    } }
end

-- ---- wrappers (each returns nil when the ladder has nothing to add) -------------
local function run(id, ctx)
  M.define()
  if not ladder.enabled(id) then return nil end
  local ok, v, meta = pcall(ladder.run, id, ctx)
  if not ok then return nil end
  return v, meta
end

-- supervise(rec) -> status string, meta | nil (caller keeps "stuck")
function M.supervise(rec) return run("swarm.supervise", { rec = rec }) end

-- classify_failure(cmd, output) -> class string, meta | nil
function M.classify_failure(cmd, output)
  return run("coding.verify", { cmd = cmd, output = output })
end

-- tracker_classify(a, parent) -> { kind=?, priority=? } | nil. Only asks about
-- the fields the caller left out.
function M.tracker_classify(a, parent)
  local want_kind = (a.kind == nil or a.kind == "") and not parent
  local want_priority = a.priority == nil or a.priority == ""
  if not (want_kind or want_priority) then return nil end
  local v = run("tracker.classify", { title = a.title, description = a.description,
    want_kind = want_kind, want_priority = want_priority })
  if type(v) ~= "table" then return nil end
  return { kind = want_kind and v.kind or nil, priority = want_priority and v.priority or nil }
end

-- story_judge(prose, call, prompt) -> 1..10 | nil
function M.story_judge(prose, call, prompt)
  return run("story.judge", { prose = prose, call = call, prompt = prompt })
end

function M.install()
  if bog then bog.ladder_sites = M end
  M.define()
end

return M
