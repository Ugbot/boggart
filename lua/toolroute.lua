-- toolroute.lua -- tool choice on the tier ladder (lua/ladder.lua).
--
-- Called once per model round from api.lua, between "here are the tools" and
-- "send the request". Four sites, each its own switch (`/ladder on tool.<x>`),
-- all off by default; with them off plan() returns nil and nothing changes.
--
--   tool.triage  once per user turn: does this need tools at all? A confident
--                "no" offers none, so the model just answers.
--   tool.narrow  a ranked Jev choice over the tools (candidates pre-selected by
--                local term overlap): offer the top few + an always-on set.
--   tool.force   one tool is clearly next: tool_choice names it, the model only
--                fills the arguments. A model that ignores it is asked again
--                unforced (api.lua), so a forced call cannot silently dead-end.
--   tool.skip    the next call is decidable without the model (no required
--                args, or only enum/boolean ones Jev can answer): synthesize the
--                tool_use and run it through the normal gate.
--
-- Authority never moves. Narrowing only shrinks what is offered (dispatch
-- re-checks the allow-set, invoke.lua), and a skipped call goes through the same
-- run_tool as a model's, so permissions, approvals and checkpoints all apply.
-- Free-text arguments are never guessed: bash/write/edit are not skippable.
--
-- Every classifier is a ladder stage, so "another Jev step ahead of time" is
-- `toolroute.pre(fn)`: fn(state, tools, sess) -> plan fields to merge.
local ladder = require("ladder")

local M = {}

M.DEFAULTS = {
  min_tools = 12,       -- narrowing is pointless below this many offered tools
  keep = 6,             -- most tools kept by narrow (plus always-on)
  mass = 0.9,           -- probability mass the kept set must cover
  candidates = 40,      -- most tools put to jev as options
  max_skips = 3,        -- skipped calls per user turn
  state_chars = 3000,
}
M.ALWAYS_ON = { read = true, write = true, edit = true, bash = true, grep = true, glob = true }
M.NO_SKIP = { bash = true, write = true, edit = true }
M.NONE = "(none)"

local pre = {}
function M.pre(fn) pre[#pre + 1] = fn end

-- ---- state -----------------------------------------------------------------
local function text_of(content)
  if type(content) == "string" then return content end
  local out = {}
  for _, b in ipairs(content or {}) do
    if type(b) == "table" then
      if b.type == "text" then out[#out + 1] = b.text or ""
      elseif b.type == "tool_result" then
        out[#out + 1] = type(b.content) == "string" and b.content or text_of(b.content)
      end
    end
  end
  return table.concat(out, "\n")
end

local function has_text(content)
  if type(content) == "string" then return content ~= "" end
  for _, b in ipairs(content or {}) do
    if type(b) == "table" and b.type == "text" and (b.text or "") ~= "" then return true end
  end
  return false
end

-- The index of the last REAL user message (not a tool_result carrier).
local function turn_index(sess)
  local msgs = sess.messages or {}
  for i = #msgs, 1, -1 do
    local m = msgs[i]
    if m.role == "user" and has_text(m.content) then return i end
  end
  return nil
end

local function clip(s, n)
  if #s <= n then return s end
  return s:sub(1, n)
end

-- The request plus the tail of what the tools just returned.
function M.state(sess, chars)
  chars = chars or M.DEFAULTS.state_chars
  local msgs = sess.messages or {}
  local ti = turn_index(sess)
  if not ti then return nil end
  local ask = clip(text_of(msgs[ti].content), chars)
  local tail = {}
  for i = ti + 1, #msgs do
    local m = msgs[i]
    if m.role == "user" and type(m.content) == "table" then
      for _, b in ipairs(m.content) do
        if b.type == "tool_result" and not b.pending then
          tail[#tail + 1] = clip(type(b.content) == "string" and b.content or "", 600)
        end
      end
    end
  end
  local s = "REQUEST:\n" .. ask
  if #tail > 0 then
    local t = table.concat(tail, "\n---\n")
    s = s .. "\n\nTOOL RESULTS SO FAR (latest last):\n" .. t:sub(math.max(1, #t - chars + 1))
  end
  return s, ti
end

-- ---- local retrieval -------------------------------------------------------
local function tokens(s)
  local set = {}
  for w in tostring(s or ""):lower():gmatch("[%a][%w_]+") do
    if #w > 2 then set[w] = true end
  end
  return set
end

-- Term overlap between the state and each tool's name + description: the code
-- tier of the narrowing site (no model, no network).
function M.candidates(state, tools, limit)
  local st = tokens(state)
  local scored = {}
  for i, t in ipairs(tools) do
    local score = 0
    for w in pairs(tokens(t.name:gsub("_", " ") .. " " .. (t.description or ""))) do
      if st[w] then score = score + 1 end
    end
    scored[i] = { tool = t, score = score, i = i }
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.i < b.i
  end)
  local out = {}
  for k = 1, math.min(limit or M.DEFAULTS.candidates, #scored) do out[k] = scored[k].tool end
  return out
end

-- ---- the shared Jev ranking -------------------------------------------------
-- One typed question per model round, shared by narrow / force / skip so they
-- cost one request between them. Result: { ranked = {{name,p}...}, top, p,
-- none_p, conf } or nil, err.
local function rank(ctx)
  if ctx.ranking ~= nil then return ctx.ranking or nil, ctx.ranking_err end
  local judge = bog and bog.judge
  if not judge or not judge.jev_only then ctx.ranking = false; return nil end
  local cands = M.candidates(ctx.state, ctx.tools, M.DEFAULTS.candidates)
  local options = { [M.NONE] = "no listed tool is clearly the right next step" }
  for _, t in ipairs(cands) do
    options[t.name] = clip((t.description or t.name):gsub("%s+", " "), 160)
  end
  local answers, meta = judge.jev_only{
    state = ctx.state,
    questions = { tool = { kind = "choice", instructions =
      "Which single tool is the right NEXT step for this request, given what the tools have returned so far", options = options } },
  }
  if not answers then
    ctx.ranking, ctx.ranking_err = false, meta
    return nil, meta
  end
  local a = answers.tool
  local ranked = {}
  for name, p in pairs(a.probabilities or {}) do ranked[#ranked + 1] = { name = name, p = p } end
  table.sort(ranked, function(x, y)
    if x.p ~= y.p then return x.p > y.p end
    return x.name < y.name
  end)
  local r = { ranked = ranked, top = a.choice, p = (a.probabilities or {})[a.choice] or a.confidence or 0,
              none_p = (a.probabilities or {})[M.NONE] or 0, conf = a.confidence or 0 }
  ctx.ranking = r
  return r
end
M._rank = rank

-- ---- sites -----------------------------------------------------------------
local defined = false
function M.define()
  if defined then return end
  defined = true
  local function nothing() return nil end

  ladder.define{ id = "tool.triage", threshold = 0.9, sample = 0,
    help = "no tools offered when the request clearly needs none",
    key = function(ctx) return (tostring(ctx.request or ""):lower():gsub("%s+", " ")) end,
    stages = {
      ladder.jev{
        name = "needs_tools",
        state = function(ctx) return ctx.state end,
        questions = { q = { kind = "noul", instructions =
          "Answering this request requires running tools (reading or changing files, running commands, searching, calling services) rather than replying from knowledge and the conversation" } },
        map = function(a) return a.q.noul < 0.5 and "none" or "tools" end,
      },
      ladder.llm(nothing),
    } }

  ladder.define{ id = "tool.narrow", threshold = 0.8, sample = 0,
    help = "offer the likely tools, not all of them",
    stages = {
      { tier = "jev", name = "rank", run = function(ctx)
          local r = rank(ctx)
          if not r then return nil end
          -- keep tools until the kept set covers `mass`, at most `keep`
          local keep, mass = {}, 0
          for _, e in ipairs(r.ranked) do
            if e.name ~= M.NONE then
              keep[#keep + 1] = e.name; mass = mass + e.p
              if mass >= M.DEFAULTS.mass or #keep >= M.DEFAULTS.keep then break end
            end
          end
          -- "none of these" being the lead answer means the set is not decided
          if r.none_p >= (r.ranked[1] and r.ranked[1].p or 0) or #keep == 0 then return nil end
          return keep, mass
        end },
      ladder.llm(nothing),
    } }

  ladder.define{ id = "tool.force", threshold = 0.9, sample = 0,
    help = "one clear next tool: the model only fills its arguments",
    stages = {
      { tier = "jev", name = "rank", run = function(ctx)
          local r = rank(ctx)
          if not r or r.top == M.NONE then return nil end
          return r.top, r.p
        end },
      ladder.llm(nothing),
    } }

  ladder.define{ id = "tool.skip", threshold = 0.95, sample = 0,
    help = "decide the next call without the model when its arguments are decidable",
    stages = {
      { tier = "jev", name = "rank+args", run = function(ctx)
          local r = rank(ctx)
          if not r or r.top == M.NONE or M.NO_SKIP[r.top] then return nil end
          local tool
          for _, t in ipairs(ctx.tools) do if t.name == r.top then tool = t end end
          if not tool then return nil end
          local input, conf = M.decide_input(tool, ctx)
          if input == nil then return nil end
          return { name = tool.name, input = input }, math.min(r.p, conf or 1)
        end },
      ladder.llm(nothing),
    } }
end

-- Arguments for `tool` decided without free text. No required properties ->
-- {}. Required enum/boolean/bounded-integer properties -> typed Jev questions.
-- Anything else -> nil (the model fills them). Returns input, confidence.
function M.decide_input(tool, ctx)
  local schema = tool.input_schema or {}
  local required = schema.required or {}
  if #required == 0 then return {}, 1 end
  local judge = bog.judge
  local props = {}
  for _, k in ipairs(required) do
    local p = schema.properties and schema.properties[k]
    if type(p) ~= "table" then return nil end
    props[k] = p
  end
  local qs, why = judge.questions_from_schema({ type = "object", properties = props })
  if not qs then return nil end
  local answers, meta = judge.jev_only{ state = ctx.state, questions = qs }
  if not answers then return nil end
  local input = {}
  for k, q in pairs(qs) do
    local a = answers[k]
    if not a then return nil end
    if q.kind == "choice" then input[k] = a.choice
    elseif q.kind == "noul" then input[k] = (a.noul or 0) >= 0.5
    else input[k] = a.score end
  end
  return input, meta.confidence
end

-- ---- plan ------------------------------------------------------------------
local function any_enabled()
  for _, id in ipairs({ "tool.triage", "tool.narrow", "tool.force", "tool.skip" }) do
    if ladder.enabled(id) then return true end
  end
  return false
end

local function filter(tools, keep)
  local set = {}
  for _, n in ipairs(keep) do set[n] = true end
  local out = {}
  for _, t in ipairs(tools) do
    if set[t.name] or M.ALWAYS_ON[t.name] then out[#out + 1] = t end
  end
  return out
end

local function plan(sess, tools)
  M.define()
  if not any_enabled() or type(sess) ~= "table" or type(tools) ~= "table" or #tools == 0 then return nil end
  local state, ti = M.state(sess)
  if not state then return nil end

  local ctx = { state = state, tools = tools, turn = ti,
    request = text_of(sess.messages[ti].content):sub(1, 400) }
  local p = { tools = tools, sites = {}, ctx = ctx, ti = ti }
  sess._toolroute = sess._toolroute or {}
  local turn = sess._toolroute
  if turn.ti ~= ti then
    turn.ti, turn.triage, turn.skips, turn.skipped = ti, nil, 0, {}
  end

  -- triage: once per user turn, remembered across the tool rounds of that turn
  if ladder.enabled("tool.triage") and turn.triage == nil then
    local v, m = ladder.run("tool.triage", ctx)
    turn.triage = v or false
    p.sites["tool.triage"] = m
  end
  -- only the first round of the turn: once a tool has run the answer is not "none"
  if turn.triage == "none" and ti == #(sess.messages or {}) then
    p.tools = {}
    return p
  end

  for _, fn in ipairs(pre) do
    local ok, add = pcall(fn, state, tools, sess)
    if ok and type(add) == "table" then
      for k, v in pairs(add) do p[k] = v end
    end
  end

  if #p.tools > 0 and #tools >= M.DEFAULTS.min_tools and ladder.enabled("tool.narrow") then
    local keep, m = ladder.run("tool.narrow", ctx)
    p.sites["tool.narrow"] = m
    if keep then p.tools = filter(tools, keep) end
  end

  if ladder.enabled("tool.skip") and turn.skips < M.DEFAULTS.max_skips then
    local sk, m = ladder.run("tool.skip", ctx)
    p.sites["tool.skip"] = m
    if sk and not turn.skipped[sk.name] then
      turn.skips = turn.skips + 1
      turn.skipped[sk.name] = true
      p.skip = sk
      return p
    end
  end

  if ladder.enabled("tool.force") then
    local name, m = ladder.run("tool.force", ctx)
    p.sites["tool.force"] = m
    if name then
      for _, t in ipairs(p.tools) do
        if t.name == name then p.tool_choice = name end
      end
    end
  end
  return p
end

-- plan(sess, tools) -> nil | { tools, tool_choice?, skip?, sites, ctx }.
-- Never raises; a router fault is the unrouted offer.
function M.plan(sess, tools)
  local ok, p = pcall(plan, sess, tools)
  if not ok then
    if bog and bog.log then bog.log("toolroute: " .. tostring(p)) end
    return nil
  end
  return p
end

-- The assistant turn a skip stands in for. The id is stable and unique per turn
-- so a resumed transcript pairs it with its result.
function M.synth(sess, skip, round)
  local id = string.format("toolu_route_%d_%d", #(sess.messages or {}), round or 0)
  return { role = "assistant", content = { { type = "tool_use", id = id,
    name = skip.name, input = skip.input or {} } } }
end

-- A forced tool the model ignored (api.lua asked again unforced).
function M.note_unforced(p)
  if p then p.unforced = true end
end

-- After the model answers: when it was free to choose, did it pick what the
-- ranking said? That agreement is the thermometer for narrow/force/skip.
function M.observe(p, msg)
  if not p or not p.ctx or p.skip then return end
  local r = p.ctx.ranking
  if not r or p.tool_choice or #p.tools < #p.ctx.tools then return end
  local used
  for _, b in ipairs(msg and msg.content or {}) do
    if b.type == "tool_use" then used = b.name; break end
  end
  local ok, tel = pcall(require, "telemetry")
  if not ok then return end
  local top = {}
  for i, e in ipairs(r.ranked) do if i <= M.DEFAULTS.keep then top[e.name] = true end end
  pcall(tel.ladder, nil, { site = "tool.rank", tier = "jev", confidence = r.p,
    agree = (used ~= nil) and (top[used] == true) or (r.top == M.NONE) })
end

function M.install()
  if bog then bog.toolroute = M end
  M.define()
end

return M
