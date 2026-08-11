-- api.lua -- Anthropic Messages API client and the agent turn loop.
--
-- Two transports share one SSE decoder:
--   * stream_once  -- blocking (http.request), used by the default single-agent
--     REPL/oneshot/headless path. Behaviour is unchanged from before.
--   * stream_async -- non-blocking (http.begin + coroutine.yield("io", req)),
--     used by swarm-mode agent threads so many turns run concurrently under the
--     cooperative scheduler.
-- The turn loop is parameterized over a session object + opts, so the default
-- agent (bog.session, sync) and swarm agents (own session, async, own tools/
-- system) run the identical loop.
local json = require("json")
local events = require("events")
local M = {}

local cached_headers = nil

-- Where to send the request.
--
-- ANTHROPIC_BASE_URL is the same variable the official SDKs honour, so
-- anything that already speaks the Messages API works without further
-- configuration -- a proxy, a gateway, or a local engine. DwarfStar (ds4) is
-- the interesting case: `ds4-server` exposes /v1/messages directly, so
--
--   ANTHROPIC_BASE_URL=http://127.0.0.1:8000 ./boggart "..."
--
-- runs the whole harness against a model on this machine, which is also how
-- you exercise the agent loop with no network and no per-token cost.
-- base_url and model are configuration and live in the C-side credential store
-- (src/lauth.c) alongside the key, which Lua cannot read. auth.base_url()
-- already applies the environment-wins precedence.
local function endpoint()
  local base = auth.base_url()
  if not base or base == "" then return "https://api.anthropic.com/v1/messages" end
  base = base:gsub("/+$", "")
  -- Accept either a bare origin or a full messages URL, so callers do not have
  -- to remember which one this wants.
  if base:match("/v1/messages$") then return base end
  return base .. "/v1/messages"
end
M.endpoint = endpoint

-- ---- failure classification -------------------------------------------------
--
-- Three kinds of thing go wrong here and they want opposite treatment:
--
--   configuration  no credentials, unreachable endpoint, unknown model. Not a
--                  bug, and a stack traceback is actively unhelpful -- the user
--                  needs to be told what to set. Never retried.
--   transient      429, 5xx, a dropped connection. Retried with backoff before
--                  the user ever hears about it.
--   request        400s we caused. Surfaced with the server's own explanation,
--                  which is usually specific and useful.
--
-- Errors are tables with __tostring so every existing `tostring(err)` site
-- renders the human message, while callers that want to branch can look at
-- .kind. `fatal` marks the ones where retrying or continuing is pointless --
-- the swarm scheduler stops on those rather than failing every agent in turn
-- with the same message.
M.ERR = {
  auth        = "auth",
  endpoint    = "endpoint",
  model       = "model",
  bad_request = "bad_request",
  rate_limit  = "rate_limit",
  overloaded  = "overloaded",
  server      = "server",
  stream      = "stream",
}

local ERRMT = {
  __tostring = function(e)
    if e.hint and e.hint ~= "" then return e.message .. "\n\n" .. e.hint end
    return e.message
  end,
}

local function fail(kind, message, opts)
  opts = opts or {}
  error(setmetatable({
    boggart_error = true, kind = kind, message = message,
    hint = opts.hint, retryable = opts.retryable or false,
    fatal = opts.fatal or false, status = opts.status,
  }, ERRMT), 0)
end
M.fail = fail

function M.is_error(e) return type(e) == "table" and e.boggart_error == true end

-- Drop the cached auth headers. Needed after /auth changes a credential, or a
-- key set mid-session would not take effect until restart.
function M.forget_auth() cached_headers = nil end

-- Turn an HTTP status into one of the kinds above, with the server's body as
-- the detail (it usually says exactly what is wrong).
local function classify_status(status, body)
  body = tostring(body or "")
  local detail = body:sub(1, 400):gsub("%s+$", "")
  if status == 401 or status == 403 then
    return M.ERR.auth, "The API rejected our credentials (HTTP " .. status .. ").", {
      fatal = true,
      hint = "Check ANTHROPIC_API_KEY, or re-run `ant auth login`.\n" ..
             "Detail: " .. detail,
    }
  elseif status == 404 then
    return M.ERR.model, "The endpoint returned 404 for " .. M.endpoint() .. ".", {
      fatal = true,
      hint = "Usually a wrong model name or base URL.\n" ..
             "Check --model, and that ANTHROPIC_BASE_URL points at a server\n" ..
             "exposing /v1/messages.\nDetail: " .. detail,
    }
  elseif status == 429 then
    return M.ERR.rate_limit, "Rate limited (HTTP 429).", { retryable = true, hint = detail }
  elseif status == 529 or status == 503 then
    return M.ERR.overloaded, "The API is overloaded (HTTP " .. status .. ").",
           { retryable = true, hint = detail }
  elseif status >= 500 then
    return M.ERR.server, "Server error (HTTP " .. status .. ").",
           { retryable = true, hint = detail }
  end
  return M.ERR.bad_request, "The API rejected the request (HTTP " .. status .. ").",
         { hint = detail }
end

-- A transport failure: no HTTP status at all. "Couldn't connect" against a
-- configured base URL is nearly always a local server that is not running, so
-- say that rather than reporting a generic network error.
local function transport_error(detail)
  detail = tostring(detail or "unknown")
  local base = os.getenv("ANTHROPIC_BASE_URL")
  local connect = detail:lower():find("connect", 1, true) ~= nil
  if base and connect then
    return M.ERR.endpoint, "Cannot reach " .. endpoint() .. " (" .. detail .. ").", {
      fatal = true,
      hint = "ANTHROPIC_BASE_URL is set, so this is your own endpoint.\n"
        .. "Check the server is running and the port is right:\n"
        .. "  curl -s " .. (base:gsub("/+$", "")) .. "/v1/models\n"
        .. "Unset ANTHROPIC_BASE_URL to use the Anthropic API instead.",
    }
  end
  -- No base URL configured: this is the real network, so it may well be a blip.
  return M.ERR.endpoint, "Network error talking to the API (" .. detail .. ").",
         { retryable = not connect, hint = connect
             and "Check your network connection." or nil }
end

M.classify_status = classify_status
M.transport_error = transport_error

-- Retry policy. Deliberately short and few: a coding agent waiting two minutes
-- on a wedged endpoint is worse than being told promptly.
M.RETRY = { attempts = 4, base_ms = 500, max_ms = 8000 }

-- Wait without stalling everyone else. On the sync path a plain sleep is
-- correct. Under the scheduler we arm a uv timer and yield "proc" until it
-- fires, so other agents keep running through the backoff.
local function backoff_wait(ms, async)
  local uv = require("uv")
  if not async or not coroutine.isyieldable() then uv.sleep(ms); return end
  local t = uv.new_timer()
  local done = false
  uv.timer_start(t, ms, 0, function() done = true end)
  while not done do coroutine.yield("proc", t) end
  pcall(uv.close, t)
end

local function retry_delay(attempt)
  local ms = math.min(M.RETRY.max_ms, M.RETRY.base_ms * (2 ^ (attempt - 1)))
  -- Jitter so several swarm agents rate-limited at once do not retry in lockstep.
  return math.floor(ms * (0.75 + math.random() * 0.5))
end

local function auth_headers()
  if cached_headers then return cached_headers end
  local h = { "anthropic-version: 2023-06-01", "content-type: application/json" }
  -- Note what is NOT here: the key. auth.has_key() answers the only question
  -- this code has, and lhttp.c attaches the header itself from the C-side
  -- store when a request sets `auth = true`. The secret never enters the Lua
  -- state, so it cannot leak through a table the model can read, a log line,
  -- or a generated tool.
  if auth.has_key() then
    -- Nothing to add here: the request itself carries `auth = true` and
    -- lhttp.c appends the header. This branch exists only to say "we do have
    -- a credential, do not fall through to the CLI".
  elseif auth.base_url() then
    -- A self-hosted endpoint generally wants no credential at all. Falling
    -- through to the `ant` CLI here would fail for the wrong reason and hide
    -- what is actually a working local setup.
    cached_headers = h
    return h
  else
    -- No `2>/dev/null`: that is sh redirection syntax, and cmd.exe would hand
    -- it to `ant` as a literal argument. But sys.exec folds stderr into r.out,
    -- so we cannot just trim the whole buffer either -- a warning line would
    -- end up concatenated into the token. Pick the last line that actually
    -- looks like a credential (one run of token characters, no spaces), which
    -- is robust whether or not the tool writes anything to stderr.
    local r = sys.exec("ant auth print-credentials --access-token", 20)
    local tok = ""
    for line in ((r.out or "") .. "\n"):gmatch("(.-)\r?\n") do
      local cand = line:match("^%s*([%w%-%._~%+/=]+)%s*$")
      if cand and #cand >= 16 then tok = cand end
    end
    if r.code == 0 and tok ~= "" then
      h[#h + 1] = "authorization: Bearer " .. tok
      h[#h + 1] = "anthropic-beta: oauth-2025-04-20"
    else
      -- Configuration, not a fault. Say what to do, and mention every route
      -- including the local one -- a user who has ds4 running mostly wants to
      -- be told that pointing at it is an option.
      fail(M.ERR.auth, "No API credentials found.", {
        fatal = true,
        hint = "Set one of these once and boggart will remember it:\n"
          .. "  /auth key sk-...                 store an Anthropic API key\n"
          .. "  /auth url http://127.0.0.1:8000  store a local endpoint (e.g. ds4-server)\n"
          .. "\nOr for this shell only:\n"
          .. "  export ANTHROPIC_API_KEY=sk-...\n"
          .. "  export ANTHROPIC_BASE_URL=http://127.0.0.1:8000\n"
          .. "  ant auth login                   sign in with the Anthropic CLI\n"
          .. "\nStored settings live in ~/.boggart/boggart.db (chmod 0600, not encrypted).",
      })
    end
  end
  cached_headers = h
  return h
end

-- Flatten a message's content to text (compaction size + summary extraction).
local function msg_text(m)
  if type(m.content) == "string" then return m.content end
  local parts = {}
  for _, b in ipairs(m.content) do
    if b.type == "text" then parts[#parts + 1] = b.text or ""
    elseif b.type == "tool_use" then parts[#parts + 1] = "[tool_use " .. (b.name or "?") .. "]"
    elseif b.type == "tool_result" then parts[#parts + 1] = tostring(b.content or "") end
  end
  return table.concat(parts, "\n")
end
M.msg_text = msg_text

-- ---- shared SSE decoder ----------------------------------------------------
-- Accumulates streamed content blocks and the stop_reason; on_text (optional)
-- receives text deltas live. feed(chunk) is chunk-boundary safe; finish()
-- returns (assistant_message, stop_reason, stream_err).
local function new_decoder(on_text)
  local blocks, tool_json = {}, {}
  local stop_reason, stream_err, buf = nil, nil, ""
  -- Token usage, so the UI can show what a conversation is costing and how
  -- close it is to the context window. message_start carries the input count,
  -- message_delta the final output count.
  local usage = { input_tokens = 0, output_tokens = 0,
                  cache_read_input_tokens = 0, cache_creation_input_tokens = 0 }
  local function take_usage(u)
    if type(u) ~= "table" then return end
    for k in pairs(usage) do
      if type(u[k]) == "number" then usage[k] = u[k] end
    end
  end

  local function handle(evt)
    local t = evt.type
    if t == "message_start" then
      take_usage(evt.message and evt.message.usage)
    elseif t == "content_block_start" then
      local b = {}
      for k, v in pairs(evt.content_block or {}) do b[k] = v end
      blocks[evt.index + 1] = b
    elseif t == "content_block_delta" then
      local idx = evt.index + 1
      local b = blocks[idx]; if not b then b = {}; blocks[idx] = b end
      local d = evt.delta or {}
      if d.type == "text_delta" then
        b.text = (b.text or "") .. (d.text or "")
        if on_text then on_text(d.text or "") end
      elseif d.type == "input_json_delta" then
        tool_json[idx] = (tool_json[idx] or "") .. (d.partial_json or "")
      elseif d.type == "thinking_delta" then
        b.thinking = (b.thinking or "") .. (d.thinking or "")
      elseif d.type == "signature_delta" then
        b.signature = (b.signature or "") .. (d.signature or "")
      end
    elseif t == "content_block_stop" then
      local idx = evt.index + 1
      local b = blocks[idx]
      if b and b.type == "tool_use" then
        local js = tool_json[idx]
        if not js or js == "" then js = "{}" end
        local ok, parsed = pcall(json.decode, js)
        b.input = (ok and type(parsed) == "table") and parsed or {}
      end
    elseif t == "message_delta" then
      if evt.delta and evt.delta.stop_reason then stop_reason = evt.delta.stop_reason end
      take_usage(evt.usage)
    elseif t == "error" then
      stream_err = "api stream error: " .. (evt.error and evt.error.message or "unknown")
    end
  end

  local function feed(chunk)
    buf = buf .. chunk
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then break end
      local line = buf:sub(1, nl - 1):gsub("\r$", "")
      buf = buf:sub(nl + 1)
      if line:sub(1, 6) == "data: " then
        local data = line:sub(7)
        if data ~= "" and data ~= "[DONE]" then
          local ok, evt = pcall(json.decode, data)
          if ok and type(evt) == "table" then handle(evt) end
        end
      end
    end
  end

  local function finish()
    local maxidx = 0
    for k in pairs(blocks) do if k > maxidx then maxidx = k end end
    local content = {}
    for i = 1, maxidx do if blocks[i] then content[#content + 1] = blocks[i] end end
    if #content == 0 then content[1] = { type = "text", text = "" } end
    -- usage rides on the message but is not part of the wire format we send
    -- back, so api.run_on strips it before the message joins the transcript.
    return { role = "assistant", content = content, usage = usage },
           stop_reason, stream_err
  end

  return { feed = feed, finish = finish }
end

-- ---- blocking transport (default mode) -------------------------------------
local function stream_once(body_tbl, on_text)
  local body = json.encode(body_tbl)
  for attempt = 1, M.RETRY.attempts do
    -- A fresh decoder per attempt: a retry must not inherit half a stream.
    local dec = new_decoder(attempt == 1 and on_text or on_text)
    local status, resp = http.request{
      url = endpoint(), method = "POST", headers = auth_headers(),
      auth = true, body = body, on_chunk = dec.feed, timeout = 600,
    }
    dec.feed("\n")
    local msg, stop, serr = dec.finish()

    if status == 200 and not serr then return msg, stop end
    if status == 401 or status == 403 then cached_headers = nil end

    local kind, message, opts
    if status == nil then
      kind, message, opts = transport_error(resp)
    elseif serr then
      kind, message, opts = M.ERR.stream, serr, { retryable = true }
    else
      kind, message, opts = classify_status(status, resp)
    end

    if not opts.retryable or attempt == M.RETRY.attempts then
      fail(kind, message, opts)
    end
    local delay = retry_delay(attempt)
    bog.log(string.format("%s -- retrying in %dms (%d/%d)",
      message, delay, attempt, M.RETRY.attempts - 1))
    backoff_wait(delay, false)
  end
end
M.stream_once = stream_once

-- ---- async transport (swarm mode; must run inside a scheduler coroutine) ----
local function stream_async_once(body, on_text)
  local dec = new_decoder(on_text)
  local raw = {}
  local req = http.begin{
    url = endpoint(), method = "POST", headers = auth_headers(), auth = true,
    body = body, timeout = 600,
  }
  local status, err
  while true do
    coroutine.yield("io", req) -- scheduler pumps curl_multi and resumes us
    local chunk = req:take()
    if chunk ~= "" then raw[#raw + 1] = chunk; dec.feed(chunk) end
    local st, extra = req:status()
    if st == "done" then status = extra; break
    elseif st == "error" then err = extra; break end
  end
  req:close()
  dec.feed("\n")
  local msg, stop, serr = dec.finish()
  return msg, stop, serr, status, err, table.concat(raw)
end

-- Same policy as the sync path. The backoff yields rather than sleeping, so a
-- rate-limited agent does not stop the others from working.
local function stream_async(body_tbl, on_text)
  local body = json.encode(body_tbl)
  for attempt = 1, M.RETRY.attempts do
    local msg, stop, serr, status, terr, raw = stream_async_once(body, on_text)
    if status == 200 and not serr then return msg, stop end
    if status == 401 or status == 403 then cached_headers = nil end

    local kind, message, opts
    if terr then kind, message, opts = transport_error(terr)
    elseif serr then kind, message, opts = M.ERR.stream, serr, { retryable = true }
    else kind, message, opts = classify_status(status, raw) end

    if not opts.retryable or attempt == M.RETRY.attempts then
      fail(kind, message, opts)
    end
    local delay = retry_delay(attempt)
    bog.log(string.format("%s -- retrying in %dms (%d/%d)",
      message, delay, attempt, M.RETRY.attempts - 1))
    backoff_wait(delay, true)
  end
end
M.stream_async = stream_async

-- ---- compaction ------------------------------------------------------------
local COMPACT_PROMPT = [[
Internal boggart context-compaction request. This is not a user request.
Write a durable task-state summary of the conversation so far, preserving only
what matters to continue the work: the user's goals and preferences, files
inspected or edited, commands run and key results, decisions and rejected
approaches, known bugs, and pending next steps. Do not invent facts, do not
include raw file contents, and do not call tools. Output only the summary.
]]

-- Context windows, by model. Only used to decide when to compact, so being
-- approximately right is enough; sess.context_limit overrides for anything not
-- listed, and a local server can be told its own number.
M.CONTEXT = {
  default = 200000,
  ["claude-opus-5"] = 200000,
  ["claude-sonnet-5"] = 200000,
  ["claude-haiku-4-5-20251001"] = 200000,
}
M.COMPACT_RATIO = 0.8   -- compact at 80% of the window, as goose does

function M.context_limit(sess)
  sess = sess or bog.session
  return sess.context_limit or M.CONTEXT[sess.model] or M.CONTEXT.default
end

-- How full the context is, in tokens, and where the number came from.
--
-- Prefer the measured size of the last request: it is the only figure that
-- accounts for the system prompt, the tool schemas and the cache, none of
-- which are in sess.messages. Before the first response there is nothing to
-- measure, so fall back to characters/4 -- crude, but it only has to be good
-- enough to catch a resumed session that is already enormous.
function M.context_used(sess)
  sess = sess or bog.session
  local u = sess.usage
  if u and u.last_input and u.last_input > 0 then return u.last_input, "measured" end
  local total = 0
  for _, m in ipairs(sess.messages) do total = total + #msg_text(m) end
  return total // 4, "estimated"
end

-- Fraction of the window in use, 0..1+. What the UI shows.
function M.context_fraction(sess)
  sess = sess or bog.session
  local used = M.context_used(sess)
  return used / M.context_limit(sess), used
end

-- maybe_compact(sess?, opts?) -- defaults to the single-agent session + sync.
function M.maybe_compact(sess, opts)
  sess = sess or bog.session
  local used, how = M.context_used(sess)
  local limit = M.context_limit(sess)
  if used < limit * (sess.compact_ratio or M.COMPACT_RATIO) then return false end
  bog.log(string.format("context %d/%d tokens (%s) -- compacting", used, limit, how))
  return M.compact(sess, opts)
end

-- Compact unconditionally. Separate from maybe_compact so the UI can offer it
-- before you hit the threshold, which is when you actually want it: at a
-- natural break, not in the middle of a tool chain.
function M.compact(sess, opts)
  sess = sess or bog.session
  opts = opts or {}
  local stream = opts.async and stream_async or stream_once
  local system = opts.system or function() return bog.prompt.system() end

  if #sess.messages == 0 then return false end
  local total = 0
  for _, m in ipairs(sess.messages) do total = total + #msg_text(m) end

  bog.log(string.format("compacting context (~%d chars)...", total))
  local copy = {}
  for i = 1, #sess.messages - 1 do copy[i] = sess.messages[i] end
  local last = sess.messages[#sess.messages]
  if last and last.role == "user" and type(last.content) == "string" then
    copy[#copy + 1] = { role = "user", content = last.content .. "\n\n" .. COMPACT_PROMPT }
  else
    copy[#copy + 1] = last
    copy[#copy + 1] = { role = "user", content = COMPACT_PROMPT }
  end
  local msg = stream({ model = sess.model, max_tokens = 4096, system = system(),
    messages = copy, stream = true }, nil)
  local summary = msg_text(msg)

  local start = nil
  for i = #sess.messages, 1, -1 do
    if sess.messages[i].role == "user" and type(sess.messages[i].content) == "string" then start = i; break end
  end
  local preamble = "[Earlier conversation compacted. Durable summary follows.]\n" .. summary
  local newmsgs = {}
  if start then
    newmsgs[1] = { role = "user",
      content = preamble .. "\n\n[Recent conversation continues below.]\n\n" .. sess.messages[start].content }
    for i = start + 1, #sess.messages do newmsgs[#newmsgs + 1] = sess.messages[i] end
  else
    newmsgs[1] = { role = "user", content = preamble }
  end
  sess.messages = newmsgs

  -- Forget the measured size. It described the request *before* compaction,
  -- and leaving it in place would keep the threshold tripped on every
  -- subsequent turn -- compacting an already-compacted conversation in a loop
  -- until there was nothing left of it. The next response measures the truth.
  if sess.usage then
    sess.usage.last_input = nil
    sess.usage.compactions = (sess.usage.compactions or 0) + 1
  end
  if opts.on_compact then opts.on_compact(summary) end
  -- Sizes, not text: a handler that wants the summary can read the first
  -- message, and shipping it on the event would put a few thousand tokens on
  -- the bus every time.
  events.emit("context:compacted", { session = sess.id, before = total, after = #summary })
  return true
end

-- ---- the turn loop ---------------------------------------------------------
-- run_on(sess, user_text, on_text, opts): run one user turn to completion.
-- opts: { async, system=fn, tools=fn, run_tool=fn(name,input), on_tool=fn(name,input) }
function M.run_on(sess, user_text, on_text, opts)
  opts = opts or {}
  local stream = opts.async and stream_async or stream_once
  local system = opts.system or function() return bog.prompt.system() end
  local tools_fn = opts.tools or function() return bog.tools.schemas() end
  local run_tool = opts.run_tool or bog.tools.run
  local on_tool = opts.on_tool or bog.log_tool

  if user_text ~= nil then
    sess.messages[#sess.messages + 1] = { role = "user", content = user_text }
  end

  events.emit("turn:start", {
    session = sess.id,
    -- A preview, not the prompt: a pasted file would otherwise ride on every
    -- turn:start. The full text is in sess.messages for anyone who needs it.
    preview = user_text and user_text:sub(1, 200) or nil,
    chars = user_text and #user_text or 0,
  })

  -- turn:end and turn:error come off a to-be-closed variable rather than a
  -- pcall wrapper around the loop. __close runs during the unwind, so the error
  -- keeps travelling to the caller untouched -- same value, same traceback,
  -- bog.try still sees a diagnosed api error as diagnosed. A pcall/rethrow
  -- would have moved the traceback to the rethrow line.
  --
  -- Caveat: if a swarm actor is dropped mid-turn (sched.kill), its coroutine is
  -- never resumed, so turn:end fires whenever that coroutine is collected, or
  -- not at all. Handlers must not assume every turn:start is paired.
  local stop_reason = nil
  local turn <close> = setmetatable({}, { __close = function(_, err)
    if err == nil then
      events.emit("turn:end", { session = sess.id, stop = stop_reason })
    else
      events.emit("turn:error", {
        session = sess.id, message = tostring(err),
        kind = (type(err) == "table" and err.kind) or nil,
      })
    end
  end })

  -- Wrapped rather than replaced: turn:text is the one genuinely hot emit here
  -- (once per streamed delta), so the payload is built only when something is
  -- subscribed. events.any is a single table lookup once the name has resolved.
  local sink = function(chunk)
    if on_text then on_text(chunk) end
    if events.any("turn:text") then
      events.emit("turn:text", { session = sess.id, text = chunk })
    end
  end

  while true do
    M.maybe_compact(sess, opts)

    local body = {
      model = sess.model,
      max_tokens = sess.max_tokens or 16000,
      system = system(),
      messages = sess.messages,
      stream = true,
    }
    local tools = tools_fn()
    if #tools > 0 then body.tools = tools end

    local msg, stop = stream(body, sink)
    stop_reason = stop -- what turn:end reports on the way out
    -- Account before the message joins the transcript: `usage` is our own
    -- annotation, and sending it back to the API on the next turn would be a
    -- wire-shape error.
    if msg.usage then
      sess.usage = sess.usage or { input = 0, output = 0, cached = 0, turns = 0 }
      sess.usage.input  = sess.usage.input  + (msg.usage.input_tokens or 0)
      sess.usage.output = sess.usage.output + (msg.usage.output_tokens or 0)
      sess.usage.cached = sess.usage.cached + (msg.usage.cache_read_input_tokens or 0)
      sess.usage.turns  = sess.usage.turns + 1
      -- The whole prompt, not just the uncached part. This is the number that
      -- says how close the conversation is to the context window, and with
      -- prompt caching on, input_tokens alone reads as near-zero on exactly
      -- the turns where the context is largest.
      sess.usage.last_input = (msg.usage.input_tokens or 0)
        + (msg.usage.cache_read_input_tokens or 0)
        + (msg.usage.cache_creation_input_tokens or 0)
      msg.usage = nil
    end
    sess.messages[#sess.messages + 1] = msg

    local tool_uses = {}
    for _, b in ipairs(msg.content) do
      if b.type == "tool_use" then tool_uses[#tool_uses + 1] = b end
    end

    if #tool_uses > 0 then
      local results = {}
      for _, b in ipairs(tool_uses) do
        if on_tool then on_tool(b.name, b.input) end
        local ok, res = pcall(run_tool, b.name, b.input)
        local content
        if ok then content = res else content = "Tool error: " .. tostring(res) end
        if type(content) ~= "string" then content = tostring(content) end
        -- A refused call never reaches tools.M.run -- the gate returns instead
        -- of calling it -- so tool:refused cannot come from there. Every gate
        -- in the tree (the studio's approval prompt, thread.lua's per-agent
        -- allowlist) already spells refusal as this exact result, so testing it
        -- once here covers all of them and needs no new hook.
        if events.any("tool:refused")
            and content:find("^Tool error: %[permission_error%]") then
          events.emit("tool:refused", { name = b.name, reason = content })
        end
        local is_err = content:sub(1, 11) == "Tool error:"
        results[#results + 1] = {
          type = "tool_result", tool_use_id = b.id, content = content,
          is_error = is_err or nil,
        }
      end
      sess.messages[#sess.messages + 1] = { role = "user", content = results }
      if stop ~= "tool_use" then return msg, stop end
    elseif stop == "refusal" then
      if on_text then on_text("\n[request refused by safety policy]\n") end
      return msg, stop
    else
      return msg, stop -- end_turn / max_tokens / stop_sequence
    end
  end
end

-- Default single-agent entry point (unchanged behaviour): bog.session, sync.
function M.run_turn(user_text, on_text)
  return M.run_on(bog.session, user_text, on_text, nil)
end

return M
