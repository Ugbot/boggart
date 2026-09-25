-- judge.lua -- the decision router: a small discrete decision goes to the
-- cheapest thing that can answer it.
--
-- Half the model calls in an agent runtime are not generation at all. "Which
-- of these five skills?", "is this command destructive?", "did the child
-- actually finish, 0..4?" -- a finite answer over state the caller already
-- holds. Today each of those is either a heuristic or a whole chat turn
-- (a spawn with a schema, or a utility-route request and a JSON extract).
-- TypeSafe's System One (lua/typesafe.lua) answers exactly that shape with a
-- probability distribution and a confidence, in seconds, for a fraction of a
-- cent. This module is the seam that lets a caller ask the QUESTION and not
-- care which backend answered:
--
--   local a, meta = bog.judge.decide{
--     state = transcript_tail,
--     questions = {
--       done   = { kind = "noul",   instructions = "The task is complete with evidence" },
--       status = { kind = "choice", instructions = "What is the agent doing",
--                  options = { working = "...", stuck = "...", done = "..." } },
--       evidence = { kind = "score", instructions = "Quality of the evidence",
--                    levels = { "none", "claims only", "partial", "verified" } },
--     },
--   }
--   -- a.done.noul, a.status.choice / .confidence / .ranked, a.evidence.score
--   -- meta.via == "jev" | "chat", meta.escalated, meta.jev (the numbers, when
--   -- jev answered first and chat was consulted after)
--
-- Or hand it a JSON Schema and let it decide whether that schema is simple:
--
--   bog.judge.decide{ state = s, schema = { type = "object", properties = {
--     verdict = { enum = { "ship", "fix", "reject" } },
--     risky   = { type = "boolean" },
--     quality = { type = "integer", minimum = 0, maximum = 4 },
--   } } }
--
-- ROUTING. `simple` means every question is expressible as noul / choice
-- (1..255 options) / score (2..10 ordered levels), the state fits System
-- One's budget, and nothing needs free text. A simple decision goes to jev
-- when the backend allows it; anything else -- or any jev failure -- goes to
-- the chat model on the utility route (lua/route.lua) with a JSON schema and
-- the same last-object-wins extractor spawn{schema=} uses. Both paths return
-- the SAME answer shape, so the caller branches once.
--
-- CONFIDENCE GATE. jev reports a confidence per choice/score. Below
-- `min_confidence` (in "auto") the decision is re-asked of the chat model and
-- the chat answer wins -- the cascade the TypeSafe docs recommend, with jev's
-- numbers kept in meta.jev so telemetry can compare the two.
--
-- OPTIONAL BY CONSTRUCTION. Backend `off`/`chat` never touch jev. `auto`
-- (the default) uses jev only when a key is present -- so an install with
-- no TYPESAFE_API_KEY behaves exactly as if this module routed everything to
-- chat, which is what it does. `jev` insists, and reports the error instead
-- of silently falling back, for when you are measuring it.
--   /judge                    show backend, threshold, availability
--   /judge auto|jev|chat|off  set the backend    (kv config.judge.backend)
--   /judge min 0.6            set the threshold  (kv config.judge.min_confidence)
local M = {}

local json = require("json")

M.DEFAULTS = { backend = "auto", min_confidence = 0.6, max_state_chars = 100000 }
M.BACKENDS = { auto = true, jev = true, chat = true, off = true }

-- ---- config ----------------------------------------------------------------
local function kv_get(k)
  return bog and bog.store and bog.store.kv_get and bog.store.kv_get(k)
end
local function kv_set(k, v)
  if bog and bog.store and bog.store.kv_set then bog.store.kv_set(k, v) end
end

function M.backend()
  local b = kv_get("config.judge.backend")
  if type(b) == "string" and M.BACKENDS[b] then return b end
  return M.DEFAULTS.backend
end

function M.min_confidence()
  local v = tonumber(kv_get("config.judge.min_confidence"))
  if v and v >= 0 and v <= 1 then return v end
  return M.DEFAULTS.min_confidence
end

function M.set_backend(b)
  if not M.BACKENDS[b] then return nil, "backend must be auto|jev|chat|off" end
  kv_set("config.judge.backend", b)
  return b
end

function M.set_min_confidence(v)
  v = tonumber(v)
  if not v or v < 0 or v > 1 then return nil, "threshold must be a number in 0..1" end
  kv_set("config.judge.min_confidence", tostring(v))
  return v
end

-- Is jev reachable right now? bog.typesafe.available() is "built and keyed".
function M.jev_available()
  local ts = bog and bog.typesafe
  return ts ~= nil and type(ts.available) == "function" and ts.available() == true
end

-- ---- questions --------------------------------------------------------------
-- The internal question is the caller-facing one:
--   { kind = "noul",   instructions = s, criteria = { ["true"]=, ["false"]= }? }
--   { kind = "choice", instructions = s, options = { name = description } }
--   { kind = "score",  instructions = s, levels = { "worst", ..., "best" } }
-- `type` is accepted as an alias of `kind`, and `criteria` of options/levels,
-- so a wire-format question (what typesafe.encode takes) passes through.

local function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = #t
  if n == 0 then return next(t) == nil end
  return count_keys(t) == n
end

-- Normalise one question; returns the canonical form, or nil + why it is not
-- a judge-able question. Everything that is "not simple" ends here.
function M.normalize_question(q)
  if type(q) ~= "table" then return nil, "question must be a table" end
  local kind = q.kind or q.type
  if q.instructions == nil then return nil, "question needs instructions" end
  if kind == "noul" then
    local c = q.criteria
    if c ~= nil and type(c) ~= "table" then return nil, "noul criteria must be {true=,false=}" end
    return { kind = "noul", instructions = q.instructions, criteria = c }
  elseif kind == "choice" then
    local opts = q.options or q.criteria
    if type(opts) ~= "table" then return nil, "choice needs options" end
    local n = count_keys(opts)
    if n < 1 or n > 255 then return nil, "choice needs 1..255 options" end
    if is_array(opts) then
      -- a bare list of names: each option describes itself
      local m = {}
      for _, name in ipairs(opts) do
        if type(name) ~= "string" then return nil, "choice option names must be strings" end
        m[name] = name
      end
      opts = m
    end
    return { kind = "choice", instructions = q.instructions, options = opts }
  elseif kind == "score" then
    local lv = q.levels or q.criteria
    if not is_array(lv) then return nil, "score needs an ordered array of levels" end
    if #lv < 2 or #lv > 10 then return nil, "score needs 2..10 levels" end
    -- `minimum` shifts the reported score into the caller's range (a schema
    -- whose integer starts at 1); the wire is always 0-based.
    return { kind = "score", instructions = q.instructions, levels = lv, minimum = q.minimum }
  end
  return nil, "unknown question kind: " .. tostring(kind)
end

-- JSON Schema -> questions. Only the simple subset maps; anything else makes
-- the whole schema "not simple" and the chat path answers it as a schema.
--   { enum = {...} }                                 -> choice
--   { type = "boolean" }                             -> noul
--   { type = "integer", minimum = a, maximum = b }   -> score, b-a+1 in 2..10
-- Descriptions ride along: `description` becomes the instructions;
-- `enumDescriptions` (map) / `x-levels` (array) describe options / levels.
function M.questions_from_schema(schema)
  if type(schema) ~= "table" or type(schema.properties) ~= "table" then
    return nil, "schema must be an object schema with properties"
  end
  local qs = {}
  for name, p in pairs(schema.properties) do
    if type(p) ~= "table" then return nil, "property " .. name .. " is not a schema" end
    local instr = p.description or name
    if is_array(p.enum) and #p.enum > 0 then
      local opts = {}
      for _, v in ipairs(p.enum) do
        if type(v) ~= "string" then return nil, "property " .. name .. ": non-string enum" end
        opts[v] = (type(p.enumDescriptions) == "table" and p.enumDescriptions[v]) or v
      end
      qs[name] = { kind = "choice", instructions = instr, options = opts }
    elseif p.type == "boolean" then
      qs[name] = { kind = "noul", instructions = instr }
    elseif p.type == "integer" and type(p.minimum) == "number" and type(p.maximum) == "number" then
      local n = p.maximum - p.minimum + 1
      if n < 2 or n > 10 then return nil, "property " .. name .. ": integer range must span 2..10 levels" end
      local levels = {}
      for i = 1, n do
        local given = type(p["x-levels"]) == "table" and p["x-levels"][i]
        levels[i] = given or ("level " .. tostring(p.minimum + i - 1))
      end
      qs[name] = { kind = "score", instructions = instr, levels = levels, minimum = p.minimum }
    else
      return nil, "property " .. name .. " needs free text (not enum/boolean/bounded integer)"
    end
  end
  if next(qs) == nil then return nil, "schema has no properties" end
  return qs
end

-- ---- routing ----------------------------------------------------------------
local function state_size(state)
  if type(state) == "string" then return #state end
  local ok, s = pcall(json.encode, state)
  return ok and #s or math.huge
end

-- Decide where a decision goes. Returns "jev" | "chat", reason, questions.
-- Pure: no I/O beyond reading config and key presence, so it is testable.
function M.route(spec)
  local backend = M.backend()
  -- Normalise first: a malformed question is a caller error on every path.
  local qs, why
  if spec.schema then
    qs, why = M.questions_from_schema(spec.schema)
    if not qs then return "chat", "schema not simple: " .. why, nil end
  else
    if type(spec.questions) ~= "table" or next(spec.questions) == nil then
      return nil, "decide{} needs questions or a schema"
    end
    qs = {}
    for k, q in pairs(spec.questions) do
      local nq, e = M.normalize_question(q)
      if not nq then return nil, "question " .. tostring(k) .. ": " .. e end
      qs[k] = nq
    end
  end
  if backend == "off" or backend == "chat" then return "chat", "backend " .. backend, qs end
  if not M.jev_available() then
    if backend == "jev" then return "jev", "backend jev (no key -- will fail)", qs end
    return "chat", "jev unavailable", qs
  end
  if state_size(spec.state_json or spec.state) > M.DEFAULTS.max_state_chars then
    if backend == "jev" then return "jev", "state over budget (backend jev insists)", qs end
    return "chat", "state over jev budget", qs
  end
  return "jev", "simple", qs
end

-- ---- the jev path -----------------------------------------------------------
local function to_wire(qs)
  local w = {}
  for k, q in pairs(qs) do
    if q.kind == "noul" then
      w[k] = { type = "noul", instructions = q.instructions, criteria = q.criteria }
    elseif q.kind == "choice" then
      w[k] = { type = "choice", instructions = q.instructions, criteria = q.options }
    else
      w[k] = { type = "score", instructions = q.instructions, criteria = q.levels }
    end
  end
  return w
end

local function ask_jev(spec, qs)
  local ts = bog.typesafe
  local answers, meta = ts.ask{
    state = spec.state, state_json = spec.state_json, questions = to_wire(qs),
    model = spec.model, timeout = spec.timeout,
  }
  if not answers then return nil, meta end
  -- A score whose schema had a non-zero minimum reads back shifted.
  for k, q in pairs(qs) do
    local a = answers[k]
    if a and q.kind == "score" and q.minimum and q.minimum ~= 0 and type(a.score) == "number" then
      a.score = a.score + q.minimum
    end
  end
  return answers, meta
end

-- The lowest confidence jev reported (noul has none: it IS the probability,
-- so its distance from 0.5 stands in).
function M.min_reported_confidence(answers, qs)
  local lo = 1
  for k, q in pairs(qs) do
    local a = answers[k]
    if a then
      local c
      if q.kind == "noul" then
        c = type(a.noul) == "number" and math.abs(a.noul - 0.5) * 2 or 0
      else
        c = type(a.confidence) == "number" and a.confidence or 0
      end
      if c < lo then lo = c end
    end
  end
  return lo
end

-- ---- the chat path ----------------------------------------------------------
-- Ask the utility-route model for a JSON object with one key per question,
-- then shape the answer like jev's so callers never see the difference.
local function schema_for(qs)
  local props, required = {}, {}
  for k, q in pairs(qs) do
    if q.kind == "noul" then
      props[k] = { type = "boolean", description = q.instructions }
    elseif q.kind == "choice" then
      local names = {}
      for name in pairs(q.options) do names[#names + 1] = name end
      table.sort(names)
      props[k] = { type = "string", enum = names, description = q.instructions,
                   enumDescriptions = q.options }
    else
      local mn = q.minimum or 0
      props[k] = { type = "integer", minimum = mn, maximum = mn + #q.levels - 1,
                   description = q.instructions, ["x-levels"] = q.levels }
    end
    required[#required + 1] = k
  end
  table.sort(required)
  return { type = "object", properties = props, required = required }
end

local CHAT_PROMPT = [[
You are a judge. Decide the questions below about the STATE. Answer ONLY with
one JSON object matching the SCHEMA -- every required key, no prose after it.
For enum keys pick exactly one listed value; for booleans answer true/false;
for integers pick the level whose description fits best.]]

-- Overridable for tests and for callers that already hold a model handle:
-- M.chat_impl(system, user, route) -> text
function M.chat_impl(system, user, route)
  local api = require("api")
  local msg = api.stream_async({
    model = route.model, max_tokens = 1024, system = system,
    messages = { { role = "user", content = user } }, stream = true,
  }, nil, nil, route)
  return api.msg_text(msg)
end

local function shape_chat_answers(obj, qs)
  local answers = {}
  for k, q in pairs(qs) do
    local v = obj[k]
    if q.kind == "noul" then
      answers[k] = { type = "noul", noul = (v == true) and 1 or 0 }
    elseif q.kind == "choice" then
      if type(v) == "string" and q.options[v] ~= nil then
        answers[k] = { type = "choice", choice = v, probabilities = { [v] = 1 },
                       ranked = { { option = v, p = 1 } } }
      end
    else
      local mn = q.minimum or 0
      if type(v) == "number" and v >= mn and v <= mn + #q.levels - 1 then
        local legend, probs = {}, {}
        for i, d in ipairs(q.levels) do legend[mn + i - 1] = d; probs[mn + i - 1] = 0 end
        probs[v] = 1
        answers[k] = { type = "score", score = v, legend = legend, probabilities = probs,
                       ranked = { { level = v, p = 1 } } }
      end
    end
  end
  return answers
end

local function ask_chat(spec, qs)
  local route = spec.route and require("route").resolve(spec.route) or require("route").utility()
  local state = spec.state_json or (type(spec.state) == "string" and spec.state) or json.encode(spec.state)
  local schema = schema_for(qs)
  local user = "STATE:\n" .. state .. "\n\nSCHEMA:\n" .. json.encode(schema)
  local ok, text = pcall(M.chat_impl, CHAT_PROMPT, user, route)
  if not ok then
    return nil, { kind = "transport", message = "chat judge failed: " .. tostring(text) }
  end
  local obj = require("thread").extract_json(text or "")
  if type(obj) ~= "table" then
    return nil, { kind = "parse", message = "chat judge returned no JSON object" }
  end
  local answers = shape_chat_answers(obj, qs)
  local missing = {}
  for k in pairs(qs) do if not answers[k] then missing[#missing + 1] = k end end
  if #missing > 0 then
    table.sort(missing)
    return nil, { kind = "parse", message = "chat judge missed: " .. table.concat(missing, ", ") }
  end
  return answers, { model = route.model, route = route.name }
end

-- ---- decide -----------------------------------------------------------------
-- judge.decide{ state= | state_json=, questions= | schema=, model=?, route=?,
--               min_confidence=?, timeout=? } -> answers, meta | nil, err
-- Never raises. meta = { via = "jev"|"chat", reason, escalated, confidence,
--                        jev = <jev meta + answers when chat overrode> }
function M.decide(spec)
  if type(spec) ~= "table" then return nil, { kind = "validation", message = "decide{} takes a table" } end
  if spec.state == nil and spec.state_json == nil then
    return nil, { kind = "validation", message = "decide{} needs state" }
  end
  local via, reason, qs = M.route(spec)
  if not via then return nil, { kind = "validation", message = reason } end

  if via == "chat" then
    if not qs then
      -- The schema was not simple; the chat model answers the raw schema.
      return M.decide_schema_chat(spec, reason)
    end
    local a, m = ask_chat(spec, qs)
    if not a then return nil, m end
    m.via, m.reason = "chat", reason
    return a, m
  end

  local a, m = ask_jev(spec, qs)
  local backend = M.backend()
  if not a then
    if backend == "jev" then return nil, m end
    local ca, cm = ask_chat(spec, qs)
    if not ca then return nil, cm end
    cm.via, cm.reason, cm.jev_error = "chat", "jev failed: " .. tostring(m), m
    return ca, cm
  end
  local conf = M.min_reported_confidence(a, qs)
  local threshold = spec.min_confidence or M.min_confidence()
  if backend == "auto" and conf < threshold then
    local ca, cm = ask_chat(spec, qs)
    if ca then
      cm.via, cm.reason, cm.escalated = "chat", string.format("jev confidence %.2f < %.2f", conf, threshold), true
      cm.confidence = conf
      m.answers = a
      cm.jev = m
      return ca, cm
    end
    -- chat failed: jev's answer is still an answer; say so.
    m.via, m.reason, m.escalated, m.confidence = "jev", "low confidence, chat unavailable", false, conf
    m.chat_error = cm
    return a, m
  end
  m.via, m.reason, m.escalated, m.confidence = "jev", reason, false, conf
  return a, m
end

-- A schema that is not jev-simple: the chat model answers it directly and
-- the raw object comes back (this is what spawn{schema=} would have done,
-- minus the agent).
function M.decide_schema_chat(spec, reason)
  local route = spec.route and require("route").resolve(spec.route) or require("route").utility()
  local state = spec.state_json or (type(spec.state) == "string" and spec.state) or json.encode(spec.state)
  local user = "STATE:\n" .. state .. "\n\nSCHEMA:\n" .. json.encode(spec.schema)
  local ok, text = pcall(M.chat_impl, CHAT_PROMPT, user, route)
  if not ok then return nil, { kind = "transport", message = "chat judge failed: " .. tostring(text) } end
  local obj = require("thread").extract_json(text or "")
  if type(obj) ~= "table" then return nil, { kind = "parse", message = "chat judge returned no JSON object" } end
  local miss = require("thread").schema_miss and require("thread").schema_miss(spec.schema, obj)
  if miss then return nil, { kind = "parse", message = "chat judge: " .. tostring(miss) } end
  return obj, { via = "chat", reason = reason, model = route.model, route = route.name, raw_schema = true }
end

-- Shorthands ------------------------------------------------------------------
-- judge.choose(state, instructions, options) -> name, answer, meta
function M.choose(state, instructions, options, opts)
  local a, m = M.decide{ state = state, questions = { q = { kind = "choice",
    instructions = instructions, options = options } }, min_confidence = opts and opts.min_confidence }
  if not a then return nil, nil, m end
  return a.q.choice, a.q, m
end

-- judge.yes(state, instructions) -> probability (0..1), answer, meta
function M.yes(state, instructions, opts)
  local a, m = M.decide{ state = state, questions = { q = { kind = "noul",
    instructions = instructions } }, min_confidence = opts and opts.min_confidence }
  if not a then return nil, nil, m end
  return a.q.noul, a.q, m
end

-- judge.rate(state, instructions, levels) -> score, answer, meta
function M.rate(state, instructions, levels, opts)
  local a, m = M.decide{ state = state, questions = { q = { kind = "score",
    instructions = instructions, levels = levels } }, min_confidence = opts and opts.min_confidence }
  if not a then return nil, nil, m end
  return a.q.score, a.q, m
end

-- ---- status / the agent-facing tool ----------------------------------------
function M.status()
  return {
    backend = M.backend(), min_confidence = M.min_confidence(),
    jev = M.jev_available(),
    effective = (M.backend() == "off" or M.backend() == "chat") and "chat"
      or (M.jev_available() and "jev" or (M.backend() == "jev" and "jev (no key)" or "chat")),
  }
end

function M.describe()
  local s = M.status()
  return string.format("judge: backend=%s (effective %s)  min_confidence=%.2f  jev key=%s",
    s.backend, s.effective, s.min_confidence, s.jev and "yes" or "no")
end

M.tool = {
  description = "Decide small discrete questions about some state without a full model turn: "
    .. "yes/no (noul), pick-one (choice, with a probability per option), or a rubric rating (score). "
    .. "Returns numbers to branch on, plus which backend answered. Use this instead of spawning "
    .. "an agent when the answer is one of a fixed set of options.",
  input_schema = {
    type = "object",
    properties = {
      state = { type = "string", description = "the text (or JSON) to judge" },
      questions = { type = "object", description = "map of id -> {kind=noul|choice|score, instructions, options={name=desc}|levels=[...]}" },
    },
    required = { "state", "questions" },
  },
  run = function(a)
    local answers, meta = M.decide{ state = a.state, questions = a.questions }
    if not answers then return "Tool error: judge: " .. tostring(meta and meta.message or meta) end
    return json.encode{ answers = answers, via = meta.via, confidence = meta.confidence, escalated = meta.escalated }
  end,
}

function M.register()
  if bog and bog.tools and bog.tools.register then bog.tools.register("judge", M.tool) end
end

return M
