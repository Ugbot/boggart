-- typesafe.lua -- TypeSafe System One (Jev) as a typed judge, over boggart's
-- own async transport. The codec and validation are C (src/ltypesafe.c, the
-- `typesafe` global); this file is the policy around it: which endpoint,
-- how to wait, when to retry, and the small question constructors.
--
-- What it is for (docs/typesafe.md): one call, one state, a handful of
-- atomic questions, numbers back. Not a chat model -- it has no transcript,
-- no tools, no streaming, and is never offered by /model. It is the thing
-- you ask "which of these five?", "how bad, 0..4?", "is this true?" when a
-- probability is what the code needs.
--
--   local ts = bog.typesafe
--   local a, meta = ts.ask{
--     state = ticket_text,
--     questions = {
--       dept   = ts.choice("Which team should handle this",
--                          { billing = "...", technical = "...", sales = "..." }),
--       anger  = ts.score("How frustrated the customer appears",
--                         { "Calm", "Frustrated but civil", "Very angry" }),
--       urgent = ts.noul("The message conveys urgency"),
--     },
--   }
--   if a then route(a.dept.choice, a.dept.confidence) end
--
-- Never raises: every failure is nil + err where err is the C module's
-- { kind, message, status? } (tostring-able). kind is what a caller
-- switches on: auth | validation | rate_limit | overloaded | http | parse |
-- transport.
--
-- The credential is the "typesafe" slot (TYPESAFE_API_KEY, or
-- `/auth key typesafe <k>`); it is attached in C and never read here. lauth
-- only honours the slot for a host the providers table registers, so the
-- provider row is ensured before the first request -- an install seeded
-- before this module existed has no such row.
local M = {}

local json = require("json")

M.RETRY = { attempts = 5, base_ms = 500, max_ms = 8000 }
M.DEFAULT_MODEL = typesafe and typesafe.DEFAULT_MODEL or "jev-latest"
M.TIMEOUT = 60

-- The provider row lauth's (host, slot) registry needs. Mirrors the entry
-- in lua/models.json; kept here too so an existing catalog gains it lazily.
M.PROVIDER = {
  label = "TypeSafe (Jev)", url = "https://api.typesafe.ai/v1",
  wire = "systemone", auth = "bearer",
  key_slot = "typesafe", env = "TYPESAFE_API_KEY",
}

local function err(kind, message, status)
  if typesafe and typesafe.error then return typesafe.error(kind, message, status) end
  return setmetatable({ kind = kind, message = message, status = status },
                      { __tostring = function(e) return e.message end })
end

local function log(msg)
  if bog and bog.log then bog.log(msg) end
end

-- ---- question constructors (mirror the JS SDK's choice/score/noul) ---------
function M.noul(instructions, criteria)
  return { type = "noul", instructions = instructions, criteria = criteria }
end

function M.choice(instructions, options)
  return { type = "choice", instructions = instructions, criteria = options }
end

function M.score(instructions, levels)
  return { type = "score", instructions = instructions, criteria = levels }
end

-- ---- availability -----------------------------------------------------------
function M.available()
  return typesafe ~= nil and typesafe.has_key() == true
end

-- Register the provider row if the catalog lacks it. Best-effort and quiet:
-- with no store (a test, early boot) the registry is not consulted anyway.
local registered = false
function M.ensure_provider()
  if registered then return true end
  if not (bog and bog.db) then return false end
  local okc, cat = pcall(require, "catalog")
  if not (okc and cat) then return false end
  local ok, have = pcall(cat.provider, "typesafe")
  if ok and have then registered = true; return true end
  local okimp = pcall(cat.import, { providers = { typesafe = M.PROVIDER } }, "seed")
  registered = okimp and true or false
  return registered
end

-- ---- transport --------------------------------------------------------------
-- Same wait as lua/api.lua's stream_async_once: under the scheduler the
-- request handle is yielded ("io", req) and the loop resumes us when curl
-- moves; off a coroutine, pump the loop in slices. Returns status, body |
-- nil, transport-error.
local function wait(req)
  local raw = {}
  while true do
    if coroutine.isyieldable() then coroutine.yield("io", req)
    else http.pump(50) end
    local chunk = req:take()
    if chunk ~= "" then raw[#raw + 1] = chunk end
    local st, extra = req:status()
    if st == "done" then return extra, table.concat(raw)
    elseif st == "error" then return nil, extra end
  end
end

-- Backoff yields rather than sleeps so a rate-limited judge does not stall
-- every other agent on the loop (api.lua's backoff_wait, verbatim).
local function backoff_wait(ms)
  local uv = require("uv")
  if not coroutine.isyieldable() then uv.sleep(ms); return end
  local t = uv.new_timer()
  local done = false
  uv.timer_start(t, ms, 0, function() done = true end)
  while not done do coroutine.yield("proc", t) end
  pcall(uv.close, t)
end

local function retry_delay(attempt)
  local ms = math.min(M.RETRY.max_ms, M.RETRY.base_ms * (2 ^ (attempt - 1)))
  return math.floor(ms * (0.75 + math.random() * 0.5))
end

-- lhttp.c does not expose response headers, so Retry-After is not honoured;
-- the backoff is the API's documented remedy for 429/529 regardless.
local function retryable(status)
  return status == 429 or status == 529 or status == 502 or status == 503
end

local function request(method, url, body, timeout)
  if not (http and http.begin) then return nil, err("transport", "http unavailable") end
  local okb, req = pcall(http.begin, {
    url = url, method = method,
    headers = { "content-type: application/json", "accept: application/json" },
    auth = true, key_slot = "typesafe", auth_style = "bearer",
    body = body, timeout = timeout or M.TIMEOUT,
  })
  if not okb then return nil, err("transport", tostring(req)) end
  local status, raw = wait(req)
  req:close()
  if not status then return nil, err("transport", tostring(raw)) end
  return status, raw
end

-- ---- the call ---------------------------------------------------------------
-- typesafe.ask{ state= | state_json=, questions=, model=?, timeout=? }
--   -> answers, meta | nil, err
function M.ask(spec)
  if type(spec) ~= "table" then return nil, err("validation", "ask{} takes a table") end
  if not typesafe then return nil, err("transport", "typesafe module not built in") end
  if not typesafe.has_key() then
    return nil, err("auth", "no TypeSafe key: export TYPESAFE_API_KEY or `/auth key typesafe <key>` "
                    .. "(keys at https://console.typesafe.ai/keys)", 401)
  end
  local body, e = typesafe.encode{
    state = spec.state, state_json = spec.state_json,
    model = spec.model or M.DEFAULT_MODEL, questions = spec.questions,
  }
  if not body then return nil, e end
  M.ensure_provider()

  local last
  for attempt = 1, M.RETRY.attempts do
    local status, raw = request("POST", typesafe.endpoint(), body, spec.timeout)
    if not status then
      last = raw -- a transport error; retry
    else
      local answers, meta = typesafe.decode(raw, status)
      if answers then return answers, meta end
      last = meta
      if not retryable(status) then return nil, last end
    end
    if attempt == M.RETRY.attempts then break end
    local delay = retry_delay(attempt)
    log(string.format("typesafe: %s -- retrying in %dms (%d/%d)",
      tostring(last), delay, attempt, M.RETRY.attempts - 1))
    backoff_wait(delay)
  end
  return nil, last
end

-- One question, the common case: returns that answer directly.
--   local a = ts.one(state, ts.noul("Is this spam?"))  -> a.noul
function M.one(state, question, opts)
  local answers, meta = M.ask{
    state = state, questions = { q = question },
    model = opts and opts.model, timeout = opts and opts.timeout,
  }
  if not answers then return nil, meta end
  return answers.q, meta
end

-- GET /v1/models -> decoded JSON | nil, err
function M.models(timeout)
  if not typesafe then return nil, err("transport", "typesafe module not built in") end
  if not typesafe.has_key() then return nil, err("auth", "no TypeSafe key", 401) end
  M.ensure_provider()
  local status, raw = request("GET", typesafe.models_url(), nil, timeout)
  if not status then return nil, raw end
  if status < 200 or status >= 300 then
    local _, e = typesafe.decode(raw, status)
    return nil, e
  end
  local ok, t = pcall(json.decode, raw)
  if not ok then return nil, err("parse", "models: not valid JSON", status) end
  return t
end

return M
