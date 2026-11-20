-- skillrouter.lua -- find the right skill for a task: FTS5/bm25 search over the
-- skill corpus (name, description, tool names, instructions).
--
-- The scoring lives in SQLite, which boggart already vendors with FTS5: the
-- router's whole job is to flatten the LIVE skill set -- embedded defaults,
-- overlay files, anything define_skill/import_skill created this session --
-- into the store's skills_fts table and ask it. The table is a derived cache,
-- rebuilt per query: the corpus is dozens of rows, so a rebuild is cheaper than
-- an invalidation protocol, and a just-imported skill missing from results is
-- exactly the kind of quiet staleness this codebase refuses elsewhere.
--
-- The router answers "which skills fit this task?" -- for the model (the
-- find_skill tool), and for anything programmatic (a coordinator choosing what
-- to hand a child it is about to spawn).
local M = {}

-- Flatten the live skill set into rows for the store. Tool names keep their
-- underscores; FTS5's unicode61 tokenizer splits on them, so a prose query
-- ("git worktree") still meets an identifier-shaped name (git_worktree).
-- User-invoked skills are omitted from the default corpus so find_skill /
-- dispatch only surface model-reachable ways of working.
function M.corpus(opts)
  opts = opts or {}
  local include_user = opts.include_user == true
  local skills = bog.skills
  local rows = {}
  for _, row in ipairs(skills.list()) do
    local s = skills.load(row.name)
    if s then
      local inv = s.invocation or "model"
      if include_user or inv ~= "user" then
        -- A function `instructions` is COMPUTED AT ACTIVATION and may have side
        -- effects (local_gptoss starts a llama.cpp server and switches this
        -- session onto it). Building a search index must never trigger that, so
        -- only a plain-string `instructions` is indexed; a function is left out
        -- and the skill is matched on its name + description + tool names (the
        -- fields that exist to be searched anyway).
        local instr = s.instructions
        if type(instr) ~= "string" then instr = "" end
        rows[#rows + 1] = {
          name = row.name,
          description = s.description or "",
          -- `keywords` ride in the tools column (weight 2): routing words an
          -- author adds so a prose request ("draft the next chapter") meets a
          -- skill whose description is phrased differently.
          tools = table.concat(s.tools or {}, " ")
            .. (type(s.keywords) == "table" and (" " .. table.concat(s.keywords, " ")) or ""),
          instructions = tostring(instr or ""),
          source = row.source,
          invocation = inv,
        }
      end
    end
  end
  return rows
end

-- route(query, n, opts) -> { { name, score, description }, ... } best-first, or
-- nil, err when the store is not open (the one dependency this has).
function M.route(query, n, opts)
  if not bog.db then return nil, "store unavailable" end
  local rows = M.corpus(opts)
  bog.store.skills_reindex(rows)
  return bog.store.skills_search(query, n)
end

-- ---- the tool the model is offered -----------------------------------------

M.tools = {
  find_skill = {
    description = "Search the available skills by what you need done (FTS5 bm25 "
      .. "over names, descriptions, tool names and instructions). Returns the "
      .. "best matches with scores. Use before spawning a sub-agent, to pick the "
      .. "skills to grant it -- or to find a way of working you should follow. "
      .. "User-invoked skills (invocation=user) are hidden unless include_user=true.",
    input_schema = { type = "object",
      properties = {
        query = { type = "string", description = "what you need, in plain words" },
        n = { type = "number", description = "max results (default 5)" },
        include_user = { type = "boolean",
          description = "also search user-only skills (default false)" },
      }, required = { "query" } },
    run = function(a)
      if type(a.query) ~= "string" or a.query == "" then
        return "Tool error: [validation_error] find_skill requires 'query'"
      end
      local hits, err = M.route(a.query, tonumber(a.n) or 5,
        { include_user = a.include_user == true })
      if not hits then return "Tool error: [host_capability_error] " .. tostring(err) end
      if #hits == 0 then
        return "no skills match; `skills` lists everything that exists"
      end
      local out = {}
      for _, h in ipairs(hits) do
        out[#out + 1] = string.format("%-18s %5.2f  %s", h.name, h.score, h.description)
      end
      return table.concat(out, "\n")
    end,
  },
}

-- Ordinary request routing is separate from FTS skill discovery.
-- ---- auto-routing for the session's own agent ------------------------------
--
-- Off by default. When on, each new user turn of a session that has NO skills
-- set picks its skills by BM25 over that turn's text, so a story request loads
-- the writing skills (and only their tools and instructions) instead of the
-- whole registry. Explicit session skills always win; routing never overrides
-- a choice someone made.
--
-- Selection, all code, no model call:
--   * hits with a positive score, at least RATIO (80%) of the best, at most
--     MAX. 80%, not lower: "draft the next chapter" also scores handoff
--     ("what to do next") at 76% of story_kb;
--   * a turn with fewer than MIN_WORDS content words, or no hit, keeps the
--     previous set ("yes", "continue", "do it" stay on the same skills);
--   * hysteresis: while the best hit is already in the current set, the set
--     is kept as is, so the tool list (the head of the prompt cache) does not
--     churn turn to turn;
--   * the result always adds BASE (files + shell) and ALWAYS_TOOLS, so a
--     routed agent can still read, edit, remember and find another skill.
M.AUTO_KEY = "config.skills.auto"
M.RATIO = 0.8
M.MAX = 3
M.MIN_WORDS = 3
M.BASE = { "core" }
M.ALWAYS_TOOLS = { "find_skill", "skills", "remember", "recall", "forget" }
M.SKIP = { core = true, comms = true }

local function truthy(v)
  return v == true or v == "1" or v == "true" or v == "on" or v == "yes"
end

function M.auto_enabled()
  if M._auto ~= nil then return M._auto end
  local env = os.getenv("BOGGART_SKILL_ROUTE")
  if env and env ~= "" then return truthy(env) end
  local store = rawget(_G, "bog") and bog.store
  if store and store.kv_get then
    local ok, v = pcall(store.kv_get, M.AUTO_KEY)
    if ok and v ~= nil then return truthy(v) end
  end
  return false
end

-- set_auto(on) persists the choice (one setting across TUI, cTUI and Studio).
function M.set_auto(on)
  M._auto = on and true or false
  local store = rawget(_G, "bog") and bog.store
  if store and store.kv_set then pcall(store.kv_set, M.AUTO_KEY, M._auto and "on" or "off") end
  return M._auto
end

-- Function words never route: the corpus is short descriptions, so "next",
-- "where" or "now" in a request would otherwise pick whichever skill happens
-- to say "what to do next". Applied to auto-routing only; find_skill searches
-- what the model typed.
M.STOP = {}
for w in ([[the and for with this that these those from into onto over under
then than now next where when what which who whom whose why how here there
please could would should will shall can may might must just also again more
most some any all not yes yeah okay keep going continue carry let lets get got
make made use using want need help thing things stuff about after before
while its it's our your their them they you she her his him its are was were
been being have has had does did done let's]]):gmatch("%S+") do M.STOP[w] = true end

-- The words of a turn that may route it, lowercased, function words dropped.
function M.route_words(text)
  local out = {}
  for w in tostring(text or ""):lower():gmatch("[%a][%w_']+") do
    if #w >= 3 and not M.STOP[w] then out[#out + 1] = w end
  end
  return out
end

local function content_words(text) return #M.route_words(text) end

local function member(list, x)
  for _, v in ipairs(list or {}) do if v == x then return true end end
  return false
end

-- pick(text, current, hits) -> skills, why. Pure: `hits` is route()'s answer,
-- `current` the set in force (or nil). Exposed for tests.
function M.pick(text, current, hits)
  if content_words(text) < M.MIN_WORDS then
    return current, current and "short turn: kept" or "short turn: no routing"
  end
  hits = hits or {}
  local best = hits[1] and tonumber(hits[1].score) or 0
  if best <= 0 then return current, current and "no match: kept" or "no match" end
  if current and #current > 0 and member(current, hits[1].name) then
    return current, "best match " .. hits[1].name .. " already loaded: kept"
  end
  local out, names = {}, {}
  for _, h in ipairs(hits) do
    local sc = tonumber(h.score) or 0
    if #out >= M.MAX or sc <= 0 or sc < best * M.RATIO then break end
    if not M.SKIP[h.name] then
      out[#out + 1] = h.name
      names[#names + 1] = string.format("%s %.1f", h.name, sc)
    end
  end
  if #out == 0 then return current, current and "no clear match: kept" or "no clear match" end
  return out, "routed: " .. table.concat(names, ", ")
end

-- select(text, sess) -> skills | nil. nil means "do not route" (off, explicit
-- skills, or nothing picked yet): the caller keeps its normal behaviour. The
-- choice is recorded on sess.routed = { skills, why, text } and announced on
-- the event bus as skills:routed when it changes.
function M.select(text, sess)
  if not M.auto_enabled() or type(sess) ~= "table" then return nil end
  if sess.skills and #sess.skills > 0 then return nil end
  local current = sess.routed and sess.routed.skills or nil
  if type(text) ~= "string" or text == "" then return current end
  local hits = {}
  if content_words(text) >= M.MIN_WORDS then
    local ok, res = pcall(M.route, table.concat(M.route_words(text), " "), M.MAX * 3)
    if ok and type(res) == "table" then hits = res end
  end
  local skills, why = M.pick(text, current, hits)
  if skills ~= current then
    sess.routed = { skills = skills, why = why, text = text:sub(1, 200) }
    local okev, events = pcall(require, "events")
    if okev and events.emit then pcall(events.emit, "skills:routed", { session = sess.id, skills = skills, why = why }) end
    if rawget(_G, "bog") and bog.log then pcall(bog.log, "skills: " .. why) end
  elseif sess.routed then
    sess.routed.why = why
  end
  return skills
end

-- The set an agent is built from when routed: the picked skills plus BASE.
function M.with_base(skills)
  local out, seen = {}, {}
  for _, list in ipairs({ skills or {}, M.BASE }) do
    for _, n in ipairs(list) do if not seen[n] then seen[n] = true; out[#out + 1] = n end end
  end
  return out
end

function M.learned(request, context, policy)
  return require('learning.route').run(request, context, policy)
end

return M
