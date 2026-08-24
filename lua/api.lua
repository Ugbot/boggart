-- api.lua -- Anthropic Messages API client and the agent turn loop.
--
-- One transport: stream_async -- non-blocking (http.begin + yield("io", req)),
-- driven by the cooperative scheduler. EVERY turn is a scheduler coroutine on
-- the unified libuv loop -- REPL, one-shot, headless, cTUI and swarm alike --
-- so a turn never blocks the loop and nothing ever blocks user input. (The old
-- blocking stream_once + http.request path was retired once curl moved onto uv;
-- see docs/async.md.)
-- The turn loop is parameterized over a session object + opts, so the default
-- agent (bog.session) and swarm agents (own session, own tools/system) run the
-- identical loop.
local json = require("json")
local events = require("events")
local util = require("util")
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
-- Which wire protocol the endpoint speaks. Both a local ds4-server (Anthropic
-- Messages) and a local llama.cpp (OpenAI chat-completions) resolve to the
-- "local" provider, so the address alone can't tell them apart -- this is an
-- explicit setting (auth.wire / `/auth wire` / ANTHROPIC_WIRE), defaulting to
-- Anthropic so nothing existing changes.
local function wire()
  local ok, w = pcall(auth.wire)
  return (ok and w) or "anthropic"
end
M.wire = wire

local function endpoint()
  local base = auth.base_url()
  if wire() == "openai" then
    -- OpenAI-compatible: POST <base>/v1/chat/completions. Accept a bare origin,
    -- a base already ending in /v1, or the full path, so the user doesn't have
    -- to remember the exact suffix.
    if not base or base == "" then base = "https://api.openai.com" end
    base = base:gsub("/+$", "")
    if base:match("/chat/completions$") then return base end
    if base:match("/v1$") then return base .. "/chat/completions" end
    return base .. "/v1/chat/completions"
  end
  if wire() == "responses" then
    -- OpenAI's modern Responses API: POST <base>/v1/responses.
    if not base or base == "" then base = "https://api.openai.com" end
    base = base:gsub("/+$", "")
    if base:match("/responses$") then return base end
    if base:match("/v1$") then return base .. "/responses" end
    return base .. "/v1/responses"
  end
  if not base or base == "" then return "https://api.anthropic.com/v1/messages" end
  base = base:gsub("/+$", "")
  -- Accept either a bare origin or a full messages URL, so callers do not have
  -- to remember which one this wants.
  if base:match("/v1/messages$") then return base end
  return base .. "/v1/messages"
end
M.endpoint = endpoint

-- What model this run is actually talking to, resolved exactly the way a real
-- request resolves it, so nothing that displays it can drift from what is sent:
--   * the model is sess.model -- the field the request body carries (see
--     stream() below); auth.model() is only the persisted default that seeds a
--     new session, so it is the fallback, not the answer.
--   * the provider and local/remote verdict come from the endpoint, which is
--     environment-wins: auth.provider() derives "local" (an address or a port,
--     i.e. your own server) from a named vendor ("deepseek", "anthropic").
-- One source of truth for the status bar, the /model command and doctor.
function M.status()
  local ep = endpoint()
  local host = ep:match("^%a[%w+.-]*://([^/]+)") or ep
  local provider = (auth.provider and auth.provider()) or "anthropic"
  local sess = bog and bog.session
  return {
    model    = (sess and sess.model) or auth.model() or "?",
    provider = provider,
    is_local = (provider == "local"),
    endpoint = ep,
    host     = host,
    has_key  = auth.has_key(),
  }
end

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
      -- Provider-agnostic recovery: `/auth key <k>` works in the REPL and the
      -- cTUI alike and takes effect immediately (no restart). The env var only
      -- helps the default Anthropic endpoint.
      hint = "Fix it with `/auth key <your-key>` (or `/auth show` to inspect).\n" ..
             "For the default Anthropic endpoint you can also set ANTHROPIC_API_KEY.\n" ..
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
  -- auth.base_url(), not just the environment variable. The variable was the
  -- only way to set an endpoint when this was written; the studio's settings
  -- and welcome screens store one through auth instead, and auth.base_url()
  -- already applies the environment-wins precedence. Reading only the variable
  -- meant anyone who configured a local model through the GUI got the generic
  -- "network error" instead of the branch below, which tells them their own
  -- server is not answering -- the one message that would have helped.
  local ok, base = pcall(auth.base_url)
  base = ok and base or os.getenv("ANTHROPIC_BASE_URL")
  if base == "" then base = nil end
  local from_env = os.getenv("ANTHROPIC_BASE_URL") ~= nil
  local connect = detail:lower():find("connect", 1, true) ~= nil
  if base and connect then
    return M.ERR.endpoint, "Cannot reach " .. endpoint() .. " (" .. detail .. ").", {
      fatal = true,
      hint = (from_env and "ANTHROPIC_BASE_URL is set, so this is your own endpoint.\n"
                        or "A custom endpoint is configured, so this is your own server.\n")
        .. "Check the server is running and the port is right:\n"
        .. "  curl -s " .. (base:gsub("/+$", "")) .. "/v1/models\n"
        .. (from_env and "Unset ANTHROPIC_BASE_URL to use the Anthropic API instead."
                      or "Clear it with `/auth url` to use the Anthropic API instead."),
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
  -- OpenAI-compatible servers reject/ignore the anthropic-version header; send
  -- only content-type. A local llama.cpp wants no credential at all, which the
  -- base_url branch below already handles.
  local w = wire()
  local h = (w == "openai" or w == "responses")
    and { "content-type: application/json" }
    or { "anthropic-version: 2023-06-01", "content-type: application/json" }
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
          .. "  /auth url http://127.0.0.1:8000  store a local Anthropic endpoint (e.g. ds4-server)\n"
          .. "  /auth url http://127.0.0.1:8080 + /auth wire openai   a local OpenAI server (llama.cpp)\n"
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

-- ---- OpenAI wire adapter ---------------------------------------------------
-- boggart's transcript is Anthropic content-blocks everywhere. To talk to a
-- local OpenAI-compatible server (llama.cpp / vLLM / LM Studio) we translate
-- ONLY at the wire boundary: encode the request body on the way out, decode the
-- SSE on the way back into the same block shape the Anthropic decoder produces.
-- The agent loop, tools, marks and transcript never learn a second format.

-- Anthropic content is a string or a list of blocks; pull the plain text out.
local function text_of(content)
  if type(content) == "string" then return content end
  if type(content) ~= "table" then return "" end
  local parts = {}
  for _, b in ipairs(content) do
    if type(b) == "string" then parts[#parts + 1] = b
    elseif type(b) == "table" and b.type == "text" and b.text then parts[#parts + 1] = b.text end
  end
  return table.concat(parts)
end

-- Anthropic accepts loose JSON-schema type names in tool definitions; OpenAI
-- servers (llama.cpp's grammar converter especially) validate strictly and 400
-- on anything non-standard. Normalise every `type` in a tool's schema to the
-- canonical JSON-schema name, deep-copying so the shared tool definitions the
-- Anthropic path uses are never mutated.
local SCHEMA_TYPE = {
  bool = "boolean", boolean = "boolean",
  int = "integer", integer = "integer", long = "integer",
  float = "number", double = "number", number = "number", num = "number",
  str = "string", string = "string", text = "string",
  dict = "object", object = "object", map = "object",
  list = "array", array = "array",
  null = "null", ["nil"] = "null", none = "null",
}
local function norm_schema(s)
  if type(s) ~= "table" then return s end
  local out = {}
  for k, v in pairs(s) do
    if k == "type" and type(v) == "string" then
      out[k] = SCHEMA_TYPE[v:lower()] or v
    elseif k == "type" and type(v) == "table" then
      local t = {}
      for i, x in ipairs(v) do t[i] = (type(x) == "string" and (SCHEMA_TYPE[x:lower()] or x)) or x end
      out[k] = t
    elseif type(v) == "table" then
      out[k] = norm_schema(v)
    else
      out[k] = v
    end
  end
  -- An array with no `items` is legal JSON-schema and Anthropic tolerates it,
  -- but strict OpenAI templates choke: gpt-oss's Jinja does `{% if
  -- param_spec.type == "array" %}{% if param_spec['items'] %}`, and a missing
  -- `items` makes minja throw "Function is not a bool value" -> HTTP 500 on the
  -- whole request. Supply a permissive default so every array is renderable.
  if out.type == "array" and type(out.items) ~= "table" then
    out.items = { type = "string" }
  end
  return out
end

local function to_openai_body(body)
  local msgs = {}
  local systext = text_of(body.system)
  if systext ~= "" then msgs[#msgs + 1] = { role = "system", content = systext } end

  for _, m in ipairs(body.messages or {}) do
    if type(m.content) == "string" then
      msgs[#msgs + 1] = { role = m.role, content = m.content }
    else
      local textparts, tool_calls, tool_results = {}, {}, {}
      for _, b in ipairs(m.content or {}) do
        if b.type == "text" then
          textparts[#textparts + 1] = b.text or ""
        elseif b.type == "tool_use" then
          tool_calls[#tool_calls + 1] = {
            id = b.id, type = "function",
            ["function"] = { name = b.name, arguments = json.encode(b.input or {}) },
          }
        elseif b.type == "tool_result" then
          -- Each tool result is its own message keyed by the call id -- the
          -- OpenAI shape for "here is what that function returned".
          tool_results[#tool_results + 1] = {
            role = "tool", tool_call_id = b.tool_use_id, content = text_of(b.content),
          }
        end
        -- `thinking` blocks are dropped: there is no assistant-reasoning input slot.
      end
      if m.role == "assistant" then
        local msg = { role = "assistant", content = table.concat(textparts) }
        if #tool_calls > 0 then msg.tool_calls = tool_calls end
        msgs[#msgs + 1] = msg
      else
        -- A user turn's tool_results answer the previous assistant's tool_calls,
        -- so they must come first, then any actual user text.
        for _, tr in ipairs(tool_results) do msgs[#msgs + 1] = tr end
        local t = table.concat(textparts)
        if t ~= "" then msgs[#msgs + 1] = { role = "user", content = t } end
      end
    end
  end

  local out = {
    model = body.model, max_tokens = body.max_tokens,
    messages = msgs, stream = body.stream and true or false,
  }
  if body.stream then out.stream_options = { include_usage = true } end
  if body.temperature then out.temperature = body.temperature end
  if body.reasoning_effort then out.reasoning_effort = body.reasoning_effort end
  if body.tools and #body.tools > 0 then
    local tools = {}
    for _, t in ipairs(body.tools) do
      tools[#tools + 1] = { type = "function", ["function"] = {
        name = t.name, description = t.description,
        parameters = norm_schema(t.input_schema) or { type = "object" },
      } }
    end
    out.tools = tools
  end
  return out
end

-- Decode an OpenAI chat-completions SSE stream into the same (assistant_message,
-- stop_reason, stream_err) the Anthropic decoder returns. delta.content -> text,
-- delta.reasoning_content -> a thinking block (qwen3 streams its reasoning
-- separately), delta.tool_calls -> tool_use blocks (name + JSON args arrive in
-- fragments, accumulated by index).
local function new_openai_decoder(on_text)
  local text, thinking, tool_acc = "", "", {}
  local stop_reason, stream_err, buf = nil, nil, ""
  local usage = { input_tokens = 0, output_tokens = 0,
                  cache_read_input_tokens = 0, cache_creation_input_tokens = 0 }
  local FINISH = { stop = "end_turn", length = "max_tokens",
                   tool_calls = "tool_use", content_filter = "end_turn" }

  local function handle(evt)
    if type(evt) ~= "table" then return end
    if type(evt.usage) == "table" then
      if type(evt.usage.prompt_tokens) == "number" then usage.input_tokens = evt.usage.prompt_tokens end
      if type(evt.usage.completion_tokens) == "number" then usage.output_tokens = evt.usage.completion_tokens end
    end
    if evt.error then
      stream_err = "api stream error: " .. (type(evt.error) == "table" and evt.error.message or tostring(evt.error))
      return
    end
    local ch = evt.choices and evt.choices[1]
    if not ch then return end
    local d = ch.delta or {}
    if type(d.content) == "string" and d.content ~= "" then
      text = text .. d.content
      if on_text then on_text(d.content) end
    end
    if type(d.reasoning_content) == "string" and d.reasoning_content ~= "" then
      thinking = thinking .. d.reasoning_content
    end
    if type(d.tool_calls) == "table" then
      for _, tc in ipairs(d.tool_calls) do
        local i = (tc.index or 0) + 1
        local acc = tool_acc[i]
        if not acc then acc = { id = nil, name = "", args = "" }; tool_acc[i] = acc end
        if tc.id then acc.id = tc.id end
        local fn = tc["function"]
        if fn then
          if fn.name then acc.name = acc.name .. fn.name end
          if fn.arguments then acc.args = acc.args .. fn.arguments end
        end
      end
    end
    if ch.finish_reason then stop_reason = FINISH[ch.finish_reason] or "end_turn" end
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
          if ok then handle(evt) end
        end
      end
    end
  end

  local function finish()
    local content = {}
    if thinking ~= "" then content[#content + 1] = { type = "thinking", thinking = thinking } end
    if text ~= "" then content[#content + 1] = { type = "text", text = text } end
    local maxi = 0; for i in pairs(tool_acc) do if i > maxi then maxi = i end end
    local had_tool = false
    for i = 1, maxi do
      local acc = tool_acc[i]
      if acc and acc.name ~= "" then
        local ok, parsed = pcall(json.decode, acc.args ~= "" and acc.args or "{}")
        content[#content + 1] = {
          type = "tool_use", id = acc.id or ("call_" .. i), name = acc.name,
          input = (ok and type(parsed) == "table") and parsed or {},
        }
        had_tool = true
      end
    end
    if #content == 0 then content[1] = { type = "text", text = "" } end
    -- If the model emitted tool calls, the Anthropic-side stop_reason MUST be
    -- tool_use or run_tool_round never fires -- force it regardless of what
    -- finish_reason the server sent (some send "stop" alongside tool_calls).
    if had_tool then stop_reason = "tool_use" end
    if not stop_reason then stop_reason = "end_turn" end
    return { role = "assistant", content = content, usage = usage }, stop_reason, stream_err
  end

  return { feed = feed, finish = finish }
end

-- ---- OpenAI Responses API adapter ------------------------------------------
-- The modern OpenAI API (POST /v1/responses). Differs from chat-completions:
-- the system prompt is top-level `instructions`; the transcript is `input`, an
-- array of role messages PLUS `function_call` / `function_call_output` items;
-- tools are FLAT ({type,name,description,parameters}); reasoning effort is
-- `reasoning.effort`; the cap is `max_output_tokens`; and the stream is a TYPED
-- event stream (response.output_text.delta, response.function_call_arguments.
-- delta, response.completed, ...). We translate to/from the same Anthropic block
-- shape as the other wires, so the agent loop is unchanged.
local function to_responses_body(body)
  local input = {}
  for _, m in ipairs(body.messages or {}) do
    if type(m.content) == "string" then
      input[#input + 1] = { role = m.role, content = m.content }
    else
      local textparts, calls, outputs = {}, {}, {}
      for _, b in ipairs(m.content or {}) do
        if b.type == "text" then
          textparts[#textparts + 1] = b.text or ""
        elseif b.type == "tool_use" then
          calls[#calls + 1] = { type = "function_call", call_id = b.id,
            name = b.name, arguments = json.encode(b.input or {}) }
        elseif b.type == "tool_result" then
          outputs[#outputs + 1] = { type = "function_call_output",
            call_id = b.tool_use_id, output = text_of(b.content) }
        end
        -- `thinking` blocks are dropped: no assistant-reasoning input item.
      end
      -- Order within a turn: the message text, then this turn's function calls,
      -- then (next turn) their outputs. Cross-turn order is preserved by walking
      -- messages in order, so a call always precedes its output.
      local t = table.concat(textparts)
      if t ~= "" then input[#input + 1] = { role = m.role, content = t } end
      for _, c in ipairs(calls) do input[#input + 1] = c end
      for _, o in ipairs(outputs) do input[#input + 1] = o end
    end
  end

  local out = {
    model = body.model, input = input,
    max_output_tokens = body.max_tokens,
    stream = body.stream and true or false, store = false,
  }
  local instructions = text_of(body.system)
  if instructions ~= "" then out.instructions = instructions end
  if body.reasoning_effort then out.reasoning = { effort = body.reasoning_effort } end
  if body.temperature then out.temperature = body.temperature end
  if body.tools and #body.tools > 0 then
    local tools = {}
    for _, t in ipairs(body.tools) do
      tools[#tools + 1] = { type = "function", name = t.name,
        description = t.description, parameters = norm_schema(t.input_schema) or { type = "object" } }
    end
    out.tools = tools
  end
  return out
end

-- Decode the Responses typed SSE stream into (assistant_message, stop_reason,
-- stream_err). Each frame is `event: <type>` + `data: {json}`; we read the type
-- from the data object (it carries its own `type`), so only `data:` lines matter.
local function new_responses_decoder(on_text)
  local text, thinking, tool_acc, order = "", "", {}, {}
  local stop_reason, stream_err, buf = nil, nil, ""
  local usage = { input_tokens = 0, output_tokens = 0,
                  cache_read_input_tokens = 0, cache_creation_input_tokens = 0 }

  local function handle(evt)
    local t = evt.type
    if t == "response.output_text.delta" then
      text = text .. (evt.delta or ""); if on_text then on_text(evt.delta or "") end
    elseif t == "response.reasoning_summary_text.delta" or t == "response.reasoning_text.delta" then
      thinking = thinking .. (evt.delta or "")
    elseif t == "response.output_item.added" then
      local it = evt.item
      if type(it) == "table" and it.type == "function_call" then
        local id = it.id or ("item" .. (#order + 1))
        if not tool_acc[id] then order[#order + 1] = id end
        tool_acc[id] = { id = it.call_id, name = it.name or "", args = "" }
      end
    elseif t == "response.function_call_arguments.delta" then
      local acc = tool_acc[evt.item_id]
      if acc then acc.args = acc.args .. (evt.delta or "") end
    elseif t == "response.output_item.done" then
      local it = evt.item
      if type(it) == "table" and it.type == "function_call" then
        local acc = tool_acc[it.id or evt.item_id]
        if acc then
          acc.id = it.call_id or acc.id
          if it.name and it.name ~= "" then acc.name = it.name end
          if it.arguments and acc.args == "" then acc.args = it.arguments end
        end
      end
    elseif t == "response.completed" or t == "response.incomplete" then
      local u = evt.response and evt.response.usage
      if type(u) == "table" then
        if type(u.input_tokens) == "number" then usage.input_tokens = u.input_tokens end
        if type(u.output_tokens) == "number" then usage.output_tokens = u.output_tokens end
      end
    elseif t == "response.failed" or t == "response.error" or t == "error" then
      local msg = (evt.response and evt.response.error and evt.response.error.message)
        or evt.message or "unknown"
      stream_err = "api stream error: " .. tostring(msg)
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
    local content = {}
    if thinking ~= "" then content[#content + 1] = { type = "thinking", thinking = thinking } end
    if text ~= "" then content[#content + 1] = { type = "text", text = text } end
    local had_tool = false
    for _, id in ipairs(order) do
      local acc = tool_acc[id]
      if acc and acc.name ~= "" then
        local ok, parsed = pcall(json.decode, acc.args ~= "" and acc.args or "{}")
        content[#content + 1] = { type = "tool_use", id = acc.id or ("call_" .. id),
          name = acc.name, input = (ok and type(parsed) == "table") and parsed or {} }
        had_tool = true
      end
    end
    if #content == 0 then content[1] = { type = "text", text = "" } end
    if had_tool then stop_reason = "tool_use" elseif not stop_reason then stop_reason = "end_turn" end
    return { role = "assistant", content = content, usage = usage }, stop_reason, stream_err
  end

  return { feed = feed, finish = finish }
end

-- ---- the transport (always runs inside a scheduler coroutine) --------------
local function stream_async_once(body, on_text, w)
  local dec = (w == "responses" and new_responses_decoder(on_text))
    or (w == "openai" and new_openai_decoder(on_text))
    or new_decoder(on_text)
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
  -- Belt-and-suspenders: the primary fix scrubs content at ingest, but a
  -- session resumed from the store that was written *before* that fix could
  -- still carry invalid bytes. Scrubbing the fully-encoded body once here
  -- guarantees the outbound request is always valid UTF-8 no matter its
  -- provenance. It is a no-op (a single O(n) scan, no allocation) whenever the
  -- body is already valid, which after the ingest scrub is the normal case.
  local w = wire()
  local tbl = (w == "responses" and to_responses_body(body_tbl))
    or (w == "openai" and to_openai_body(body_tbl))
    or body_tbl
  local body = util.to_valid_utf8(json.encode(tbl))
  for attempt = 1, M.RETRY.attempts do
    local msg, stop, serr, status, terr, raw = stream_async_once(body, on_text, w)
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
  -- DeepSeek v4. 100k is what a v4 server reports for itself in /v1/models;
  -- their Anthropic-compatible endpoint does not publish a window, so this is
  -- an observation rather than a documented figure. sess.context_limit
  -- overrides it, and `boggart doctor` prints whichever is in force.
  ["deepseek-v4-flash"] = 100000,
  ["deepseek-v4-pro"] = 100000,
}

-- Token pricing, USD per 1,000,000 tokens, as { match, input, output }. These
-- are ESTIMATES, for showing an approximate $ spend next to the token counts --
-- not billing-accurate, and they drift as vendors change their prices. Matched
-- by model-id substring in order (first hit wins), so "claude-opus-5" and
-- "claude-opus-4-8" both land on the opus row; `default` catches anything not
-- listed. Easy to extend: add a row, keep the list small and specific-first.
--
-- A LOCAL endpoint is your own server (see M.status().is_local), so its cost is
-- $0 -- M.cost returns nil for it, letting the UI say "local" instead of a
-- bogus price. Cache reads bill at roughly a tenth of the input rate, which
-- M.cost applies to the accumulated cached-token total.
M.PRICING = {
  { "claude-opus",   5.0,  25.0 },  -- Opus 5 / Opus 4.x
  { "claude-sonnet", 3.0,  15.0 },  -- Sonnet 5 / Sonnet 4.x
  { "claude-haiku",  1.0,   5.0 },  -- Haiku 4.5
  { "claude-fable", 10.0,  50.0 },  -- Fable 5 (most capable)
  { "deepseek",      0.30,  1.20 }, -- DeepSeek v4 -- order-of-magnitude estimate
  default = { 3.0, 15.0 },          -- unknown remote model: assume Sonnet-class
}

-- Cache-read (prompt-cache hit) input tokens bill at about a tenth of fresh
-- input on the vendors boggart talks to.
M.CACHE_READ_RATIO = 0.1

-- Providers that speak the Messages API.
--
-- Not an abstraction layer and deliberately not the beginning of one: DeepSeek
-- publishes an Anthropic-compatible endpoint that takes x-api-key, tools with
-- input_schema, tool_use/tool_result blocks and the same streaming events, so
-- supporting it is a base URL and two model names rather than a second client.
-- Their Responses API would have needed a real provider abstraction; this does
-- not, and writing one anyway would be inventing a seam nothing is pulling on.
--
-- What they ignore rather than reject: anthropic-version and anthropic-beta
-- headers, top_k, cache_control, and image content. boggart sends the version
-- header (ignored, harmless), no top_k, no cache_control and no images, so
-- nothing in the request is silently dropped. `thinking` blocks work; the
-- budget_tokens field inside them does not.
-- The built-in defaults. What actually gets used lives in the store, seeded
-- from this on first run -- see M.providers() below.
M.PROVIDER_DEFAULTS = {
  anthropic = {
    label = "Anthropic",
    base_url = nil,                       -- the built-in default endpoint
    models = { "claude-opus-5", "claude-sonnet-5" },
    key_hint = "sk-ant-...",
  },
  deepseek = {
    label = "DeepSeek",
    base_url = "https://api.deepseek.com/anthropic",
    models = { "deepseek-v4-flash", "deepseek-v4-pro" },
    key_hint = "sk-...",
  },
  ["local"] = {
    label = "A local server",
    base_url = "http://127.0.0.1:8000",
    models = {},                          -- ask the server; it knows
    key_hint = "usually anything non-empty",
  },
}

-- Providers and their models, from the store.
--
-- Model names change faster than binaries do. deepseek-v4-pro did not exist
-- when this file was first written and will not be the newest thing for long,
-- and a table compiled into the executable means the answer to "what can I run"
-- is whatever was true on build day. So the list lives in SQLite, seeded from
-- the defaults above the first time it is missing, and editable afterwards --
-- by hand, by `/model`, or by the agent, which can already write to the store.
--
-- Credentials deliberately do NOT move with it. Config is not secret and wants
-- to be readable, diffable and editable; a key wants to be in a 0600 file that
-- the `sql` tool cannot read. They are different kinds of thing and they stay
-- in different places.
local providers_cache = nil

function M.providers()
  if providers_cache then return providers_cache end
  local raw = bog.store and bog.store.kv_get and bog.store.kv_get("config.providers")
  if raw then
    local ok, t = pcall(json.decode, raw)
    if ok and type(t) == "table" and next(t) then
      providers_cache = t
      return t
    end
  end
  providers_cache = M.PROVIDER_DEFAULTS
  -- Seed, so the row exists to be edited rather than having to be invented.
  if bog.store and bog.store.kv_set then
    pcall(bog.store.kv_set, "config.providers", json.encode(M.PROVIDER_DEFAULTS))
  end
  return providers_cache
end

function M.set_providers(t)
  assert(type(t) == "table", "providers must be a table")
  bog.store.kv_set("config.providers", json.encode(t))
  providers_cache = nil
  return true
end

-- Context windows, same argument: a number that was right on build day is a
-- number that silently compacts too early later. M.CONTEXT is the fallback;
-- config.context in the store overrides it per model; a session that has been
-- *shown* a bigger window (see run_on) overrides both.
function M.context_config()
  local raw = bog.store and bog.store.kv_get and bog.store.kv_get("config.context")
  if not raw then return nil end
  local ok, t = pcall(json.decode, raw)
  return ok and type(t) == "table" and t or nil
end

-- Point boggart at a provider: endpoint and model in one action, because
-- setting one without the other is the mistake people actually make (an
-- Anthropic model name against a DeepSeek endpoint quietly gets you whatever
-- their name mapping decides, which is not an error and not what you asked
-- for).
function M.use_provider(name, model)
  local p = M.providers()[name]
  if not p then return nil, "no such provider: " .. tostring(name) end
  if p.base_url then auth.set("base_url", p.base_url) else auth.clear("base_url") end
  local pick = model or p.models[1]
  if pick then
    auth.set("model", pick)
    if bog.session then bog.session.model = pick end
  end
  M.forget_auth()
  return p, pick
end
M.COMPACT_RATIO = 0.8   -- compact at 80% of the window, as goose does

function M.context_limit(sess)
  sess = sess or bog.session
  local cfg = M.context_config()
  return sess.context_limit
    or (cfg and cfg[sess.model])
    or M.CONTEXT[sess.model]
    or (cfg and cfg.default)
    or M.CONTEXT.default
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

-- The { input, output } price (USD per 1M tokens) for a model id, matched by
-- substring against M.PRICING with a sane default. Estimate, not a quote.
local function price_for(model)
  model = tostring(model or ""):lower()
  for _, row in ipairs(M.PRICING) do
    if model:find(row[1], 1, true) then return row[2], row[3] end
  end
  return M.PRICING.default[1], M.PRICING.default[2]
end
M.price_for = price_for

-- Estimated USD spent so far on a session, from its accumulated token usage
-- (sess.usage.input / output / cached, as run_on records them). Returns nil for
-- a LOCAL endpoint -- your own server has no per-token cost, so the UI can show
-- "local" rather than a fake $0.00 -- and 0 when nothing has been billed yet.
-- This is an ESTIMATE off M.PRICING: a ballpark for "what am I spending?", not
-- an invoice. Purely additive and side-effect-free, so it is safe to call from
-- the status bar every frame and never touches the request/stream path. The CLI
-- shares this file, so it can print the same figure.
function M.cost(sess)
  sess = sess or bog.session
  -- is_local is a property of the endpoint/provider, not the session, so
  -- status() (which reads the live config) is the right source of truth.
  local ok, st = pcall(M.status)
  if ok and st and st.is_local then return nil end
  local u = sess and sess.usage
  if not u then return 0 end
  local pin, pout = price_for((sess and sess.model) or (st and st.model))
  return ((u.input  or 0) * pin
        + (u.output or 0) * pout
        + (u.cached or 0) * pin * M.CACHE_READ_RATIO) / 1e6
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
  -- Honour a scripted transport: compaction is a model call too, so a
  -- deterministic run (opts.stream set) must summarise through the SAME mock,
  -- never fall back to the network. Otherwise "no model call" would be a lie the
  -- moment a session crosses the compaction threshold.
  local stream = opts.stream or stream_async
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
-- Make a session's message list valid to send. Two ways a turn dies mid-flight
-- and leaves it un-sendable, each of which the API answers with a permanent
-- HTTP 400 (it 400s every subsequent turn too, since the broken history
-- persists to the store and to --resume):
--
--   1. Cancelled between issuing tool calls and writing their results (Ctrl-C
--      during a slow tool): a trailing assistant `tool_use` with no matching
--      `tool_result`. We fill each unanswered id with a synthetic
--      "[interrupted]" result so the conversation reads as "the tools were
--      cancelled" rather than becoming permanently unsendable.
--   2. Two `user` messages in a row (cancelled mid-stream before the assistant
--      replied, then a new prompt): the API requires alternation. We coalesce
--      adjacent user messages into one turn.
--
-- Idempotent; a no-op on already-valid history. Runs at the top of every turn
-- (so a corrupted session self-heals) and at each front end's cancel site (so
-- the *saved* transcript is clean immediately).
-- Convert any in-flight (`pending`) tool-result markers into interrupted
-- results. A tool checkpointed as "about to run" but never checkpointed with a
-- result was executing when the process died: its side effect may be half
-- applied, so it must be answered as interrupted rather than re-run.
local function finalize_pending(sess)
  local changed = false
  for _, m in ipairs(sess.messages or {}) do
    if m.role == "user" and type(m.content) == "table" then
      for _, b in ipairs(m.content) do
        if b.type == "tool_result" and b.pending then
          b.content = "[interrupted]"; b.is_error = true; b.pending = nil
          changed = true
        end
      end
    end
  end
  return changed
end
M.finalize_pending = finalize_pending

function M.repair_history(sess)
  local msgs = sess and sess.messages
  if type(msgs) ~= "table" then return false end
  local changed = finalize_pending(sess)

  -- (1) answer any dangling tool_use
  local i = 1
  while i <= #msgs do
    local m = msgs[i]
    if m.role == "assistant" and type(m.content) == "table" then
      local pending = {}
      for _, b in ipairs(m.content) do
        if b.type == "tool_use" then pending[#pending + 1] = b.id end
      end
      if #pending > 0 then
        local nxt = msgs[i + 1]
        local have = {}
        if nxt and nxt.role == "user" and type(nxt.content) == "table" then
          for _, b in ipairs(nxt.content) do
            if b.type == "tool_result" and b.tool_use_id then have[b.tool_use_id] = true end
          end
        end
        local results = {}
        for _, id in ipairs(pending) do
          if not have[id] then
            results[#results + 1] = {
              type = "tool_result", tool_use_id = id,
              content = "[interrupted]", is_error = true,
            }
          end
        end
        if #results > 0 then
          if nxt and nxt.role == "user" and type(nxt.content) == "string" then
            local text = nxt.content
            nxt.content = results
            if text ~= "" then nxt.content[#nxt.content + 1] = { type = "text", text = text } end
          elseif nxt and nxt.role == "user" and type(nxt.content) == "table" then
            for k = #results, 1, -1 do table.insert(nxt.content, 1, results[k]) end
          else
            table.insert(msgs, i + 1, { role = "user", content = results })
          end
          changed = true
        end
      end
    end
    i = i + 1
  end

  -- (2) coalesce consecutive same-role user messages into one turn
  i = 2
  while i <= #msgs do
    local prev, cur = msgs[i - 1], msgs[i]
    if prev.role == "user" and cur.role == "user" then
      local function as_blocks(c)
        if type(c) == "table" then return c end
        return (c ~= nil and c ~= "") and { { type = "text", text = c } } or {}
      end
      local merged = as_blocks(prev.content)
      for _, b in ipairs(as_blocks(cur.content)) do merged[#merged + 1] = b end
      prev.content = merged
      table.remove(msgs, i)
      changed = true
    else
      i = i + 1
    end
  end

  return changed
end

-- Append a user turn, merging into a trailing user message rather than creating
-- two user messages in a row (which the API rejects). Used for the opening
-- prompt and for mid-turn injected input alike, so both keep role alternation.
local function append_user(sess, text)
  text = util.to_valid_utf8(text)
  local last = sess.messages[#sess.messages]
  if last and last.role == "user" then
    if type(last.content) == "string" then
      last.content = (last.content ~= "" and (last.content .. "\n\n") or "") .. text
    elseif type(last.content) == "table" then
      last.content[#last.content + 1] = { type = "text", text = text }
    else
      last.content = text
    end
  else
    sess.messages[#sess.messages + 1] = { role = "user", content = text }
  end
end
M.append_user = append_user

-- Run (or finish) the tool calls an assistant message asks for, writing each
-- result into a single following user message and CHECKPOINTING around every
-- one -- an intent marker before it runs (so a crash mid-tool is recoverable)
-- and the result after. Resumable: a tool that already has a result is not
-- re-run, so a turn interrupted after tool 2 of 5 continues at tool 3 without
-- repeating the first two (which may have had side effects). `idx` is the
-- assistant message's index in sess.messages. Returns true if it had tools.
local function run_tool_round(sess, msg, idx, run_tool, on_tool, checkpoint)
  local uses = {}
  for _, b in ipairs(msg.content) do
    if b.type == "tool_use" then uses[#uses + 1] = b end
  end
  if #uses == 0 then return false end

  local rmsg = sess.messages[idx + 1]
  if not (rmsg and rmsg.role == "user" and type(rmsg.content) == "table") then
    rmsg = { role = "user", content = {} }
    table.insert(sess.messages, idx + 1, rmsg)
  end
  local resulted = {}
  for _, b in ipairs(rmsg.content) do
    if b.type == "tool_result" and not b.pending then resulted[b.tool_use_id] = true end
  end

  for _, b in ipairs(uses) do
    if not resulted[b.id] then
      -- intent checkpoint: this tool is about to run
      local block = { type = "tool_result", tool_use_id = b.id, content = "", pending = true }
      rmsg.content[#rmsg.content + 1] = block
      checkpoint()

      if on_tool then on_tool(b.name, b.input) end
      local ok, res = pcall(run_tool, b.name, b.input)
      local content = ok and res or ("Tool error: " .. tostring(res))
      if type(content) ~= "string" then content = tostring(content) end
      content = util.to_valid_utf8(content)
      if events.any("tool:refused")
          and content:find("^Tool error: %[permission_error%]") then
        events.emit("tool:refused", { name = b.name, reason = content })
      end
      -- result checkpoint: finalise the marker in place
      block.content = content
      block.is_error = (content:sub(1, 11) == "Tool error:") or nil
      block.pending = nil
      checkpoint()
    end
  end
  return true
end

-- True (plus the assistant message's index) if the session's last exchange is
-- an unfinished tool round: the final assistant message asked for tools that
-- have no non-pending result yet -- i.e. a turn that was interrupted.
function M.incomplete_turn(sess)
  local msgs = sess and sess.messages
  if type(msgs) ~= "table" then return false end
  for i = #msgs, 1, -1 do
    local m = msgs[i]
    if m.role == "assistant" then
      if type(m.content) ~= "table" then return false end
      local ids, any = {}, false
      for _, b in ipairs(m.content) do
        if b.type == "tool_use" then ids[b.id] = true; any = true end
      end
      if not any then return false end
      local resulted = {}
      local nxt = msgs[i + 1]
      if nxt and nxt.role == "user" and type(nxt.content) == "table" then
        for _, b in ipairs(nxt.content) do
          if b.type == "tool_result" and not b.pending then resulted[b.tool_use_id] = true end
        end
      end
      for id in pairs(ids) do if not resulted[id] then return true, i end end
      return false
    end
  end
  return false
end

-- Backstop against a turn that never converges: the tool loop below is
-- `while true`, so without a cap a model can round-trip tools forever (or, on a
-- local model, burn wall-clock thinking without acting). Generous enough that a
-- normal turn (< ~20 rounds) never notices; low enough that a furnace stops.
-- Overridable per turn (opts.max_rounds) or per session (sess.max_rounds).
M.MAX_ROUNDS = 80

-- run_on(sess, user_text, on_text, opts): run one user turn to completion.
-- opts: { async, system=fn, tools=fn, run_tool=fn(name,input), on_tool=fn(name,input) }
function M.run_on(sess, user_text, on_text, opts)
  opts = opts or {}
  -- The transport is overridable so a test/bench can inject a scripted model and
  -- drive the whole loop deterministically with no network (boggart had no such
  -- seam -- the "mock wire" was only "point at a local server"). A scripted
  -- stream(body, sink) returns the same (msg, stop) shape as stream_async.
  local stream = opts.stream or stream_async
  local system = opts.system or function() return bog.prompt.system() end
  local tools_fn = opts.tools or function() return bog.tools.schemas() end
  -- Gate by default. If the front end did not pass its own run_tool, wrap the
  -- raw dispatcher in the permission gate rather than running tools blind -- the
  -- old default (bare bog.tools.run) let headless/one-shot/swarm turns run
  -- write/edit/bash with no policy at all. With no interactive approver the wrap
  -- resolves gated tools via perm.headless_decision (default allow, overridable).
  local run_tool = opts.run_tool
    or (bog.perm and bog.perm.wrap_run(bog.tools.run, bog.perm.state()))
    or bog.tools.run
  local on_tool = opts.on_tool or bog.log_tool
  -- Durable checkpoint: persist the transcript after the assistant message and
  -- after every tool result, so a crash/cancel loses at most the tool that was
  -- in flight. Front ends pass save_session / thread_save; default is a no-op.
  local checkpoint = opts.checkpoint or function() end
  -- Budgets: bound the tool loop (rounds) and, for a spawned worker, its output
  -- tokens (≈ cost / wall-clock on a local model). Defaults are generous; a
  -- spawned agent carries a tighter token_budget from thread.new_agent.
  local max_rounds = tonumber(opts.max_rounds or sess.max_rounds) or M.MAX_ROUNDS
  local token_budget = tonumber(opts.token_budget or sess.token_budget)
  local rounds = 0
  -- Telemetry: one turn span per model round (never per streamed delta). The
  -- whole fan-out shares run_id so KPIs group; ttfb is measured off the first
  -- non-empty delta in the sink below.
  local tel = bog.telemetry
  local tctx = { run_id = opts.run_id or sess.id, agent_id = sess.id,
                 parent_id = opts.parent_id or sess.parent_id }
  local ttfb_t0, ttfb_ms = nil, nil

  -- Scrub to valid UTF-8 at INGEST -- the moment content joins the transcript --
  -- so ill-formed bytes never enter sess.messages or the store, and therefore
  -- cannot re-break the turn, a later turn, a --resume, or compaction. The JSON
  -- encoder passes bytes >= 0x80 through raw, so a single invalid byte here (a
  -- pasted binary, a file dropped in as text) would otherwise HTTP-400 the turn.
  if user_text ~= nil then
    -- A new prompt means the user has moved on: heal (abandon) any interrupted
    -- tool round rather than resume it, then start the new turn. Without this
    -- the API 400s here and on every turn after -- the "cancel -> 400 loop".
    append_user(sess, user_text)
    M.repair_history(sess)
  else
    -- No new prompt: this is a resume/continue. Finish an interrupted tool
    -- round in place -- in-flight tools become interrupted (not re-run), tools
    -- that never started are executed now -- so the turn picks up where the
    -- crash/cancel left it instead of discarding the work already done.
    local incomplete, idx = M.incomplete_turn(sess)
    if incomplete then
      finalize_pending(sess)
      run_tool_round(sess, sess.messages[idx], idx, run_tool, on_tool, checkpoint)
      checkpoint()
    end
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
    if ttfb_t0 and not ttfb_ms and chunk and chunk ~= "" then
      ttfb_ms = tel and (tel.now_ms() - ttfb_t0) or nil
    end
    if on_text then on_text(chunk) end
    if events.any("turn:text") then
      events.emit("turn:text", { session = sess.id, text = chunk })
    end
  end

  -- OPTIONAL auto-dispatch: if this fresh request is "different enough" from what
  -- this agent does (see lua/dispatch.lua), hand the whole turn to a specialist
  -- sub-agent and return its answer, instead of answering here. Off by default,
  -- and never for a resumed turn (user_text == nil) or a delegated child
  -- (dispatch.depth > 0), which would recurse.
  -- `not opts.stream`: a deterministic run must never hand the turn to a
  -- specialist (assess + delegate are real model calls). The scripted transport
  -- means "answer here, with this mock" -- so dispatch is off in that mode.
  if user_text ~= nil and not opts.stream and bog.dispatch and bog.dispatch.enabled()
     and bog.dispatch.depth == 0 then
    local cur_skills = (sess.agent and sess.agent.skills) or sess.skills or {}
    local a = bog.dispatch.assess(user_text, cur_skills, sess)
    if a.delegate and #a.skills > 0 then
      sink("[dispatch] routing to a " .. tostring(a.match) .. " specialist (" .. a.reason .. ")\n")
      local text, ok = bog.dispatch.delegate(user_text, a.skills, nil)
      if text then
        sink(text)
        local msg = { role = "assistant", content = { { type = "text", text = text } } }
        sess.messages[#sess.messages + 1] = msg
        stop_reason = "delegated"
        return msg, "delegated"
      end
      -- delegation unavailable/failed: fall through and answer locally
    end
  end

  while true do
    -- Budget check at the top of each round: stop a turn that will not converge
    -- rather than let it loop or burn tokens forever. Reported as a distinct
    -- stop_reason so the exit contract (Phase 1) can treat it as a failure.
    rounds = rounds + 1
    local over_rounds = rounds > max_rounds
    local used_out = (sess.usage and sess.usage.output) or 0
    local over_tokens = token_budget and used_out >= token_budget
    if over_rounds or over_tokens then
      local why = over_rounds
        and ("hit the max of " .. max_rounds .. " tool rounds")
        or  ("used " .. used_out .. " output tokens (budget " .. token_budget .. ")")
      local note = "[budget] stopped: " .. why .. ". The turn did not converge; "
        .. "treat this as a failure, not a completion."
      if on_text then on_text("\n" .. note .. "\n") end
      local m = { role = "assistant", content = { { type = "text", text = note } } }
      sess.messages[#sess.messages + 1] = m
      stop_reason = over_rounds and "max_rounds" or "token_budget"
      return m, stop_reason
    end

    -- Mid-turn steering: anything the user submitted while the turn was running
    -- is queued on sess.inbox and folded in here, so it rides the next request
    -- alongside the pending tool results. Merge-aware, so roles still alternate.
    if sess.inbox and #sess.inbox > 0 then
      local pending = sess.inbox
      sess.inbox = {}
      for _, t in ipairs(pending) do append_user(sess, t) end
    end

    M.maybe_compact(sess, opts)

    local body = {
      model = sess.model,
      max_tokens = sess.max_tokens or 16000,
      system = system(),
      messages = sess.messages,
      stream = true,
      -- Reasoning effort, when the user set one (/effort). Reasoning models
      -- (deepseek, gpt-oss, o-series) read it; others ignore it.
      reasoning_effort = sess.effort,
    }
    local tools = tools_fn()
    if #tools > 0 then body.tools = tools end

    ttfb_t0 = tel and tel.now_ms() or nil; ttfb_ms = nil
    local msg, stop = stream(body, sink)
    stop_reason = stop -- what turn:end reports on the way out
    -- One turn span: model / TTFB / tokens / tool-calls / think-vs-output.
    -- Emitted before usage is scrubbed off msg, counted from the blocks the
    -- model produced this round.
    if tel then
      local tc, think_c, text_c = 0, 0, 0
      for _, b in ipairs(msg.content or {}) do
        if b.type == "tool_use" then tc = tc + 1
        elseif b.type == "thinking" then think_c = think_c + #(b.thinking or "")
        elseif b.type == "text" then text_c = text_c + #(b.text or "") end
      end
      tel.turn(tctx, {
        model = sess.model, ttfb_ms = ttfb_ms,
        in_tokens = (msg.usage and msg.usage.input_tokens) or 0,
        out_tokens = (msg.usage and msg.usage.output_tokens) or 0,
        tool_calls = tc, think_chars = think_c, text_chars = text_c, stop = stop,
      })
    end
    -- Live progress counters the watchdog reads: turns taken vs tool rounds run.
    sess._turns = (sess._turns or 0) + 1
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

      -- A request that succeeded is proof the window is at least that big.
      --
      -- The table below is guesswork for anything but the models we know, and
      -- remote models increasingly have windows far larger than the 200k
      -- default -- in which case boggart would compact at 160k on a model that
      -- had another 800k to spare, throwing away context for nothing. The
      -- server just answered a request of this size, so the limit cannot be
      -- lower than it. Raise the assumption to fit the evidence, with headroom.
      --
      -- Only ever upwards, and only from a served request: a wrong guess makes
      -- boggart compact too eagerly, which is wasteful; guessing upwards
      -- without evidence would make it overflow, which fails the turn.
      local seen = sess.usage.last_input
      if seen > 0 and seen >= M.context_limit(sess) then
        sess.context_limit = math.floor(seen * 1.25)
        bog.log(string.format(
          "context window for %s is at least %d tokens (a request that size "
          .. "was served); assuming %d", tostring(sess.model), seen,
          sess.context_limit))
      end
      msg.usage = nil
    end
    sess.messages[#sess.messages + 1] = msg
    checkpoint() -- the assistant message (maybe carrying tool_use) is now durable

    -- Run its tools with per-result checkpointing (see run_tool_round). Every
    -- tool_result is scrubbed to valid UTF-8 and refusals are surfaced there,
    -- so this is still the single ingest point for tool output.
    local had_tools = run_tool_round(sess, msg, #sess.messages, run_tool, on_tool, checkpoint)
    if had_tools then sess._tools = (sess._tools or 0) + 1 end

    if had_tools then
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
-- The default turn. It runs through the session's agent record -- the same
-- record shape a swarm actor has -- so skills, tool filtering and prompt
-- assembly are one code path. A session with no skills gets the whole registry,
-- so this is behaviour-identical to the old direct call until skills are set.
function M.run_turn(user_text, on_text)
  local sess = bog.session
  if bog.active_session then
    local ok, s = pcall(bog.active_session)
    if ok and s then sess = s end
  end
  local opts = sess.agent and sess.agent.opts
  if not opts and bog.thread and bog.thread.session_agent then
    local ok, rec = pcall(bog.thread.session_agent, sess)
    if ok then opts = rec.opts end
  end
  -- Checkpoint the default session to the store after each assistant message /
  -- tool result, so an interrupted turn survives to be resumed.
  opts = opts or {}
  if opts.checkpoint == nil then
    local merged = { checkpoint = function() pcall(bog.save_session) end }
    setmetatable(merged, { __index = opts })
    opts = merged
  end
  return M.run_on(sess, user_text, on_text, opts)
end

-- Continue a turn that was interrupted mid-tool (no new prompt): finish the
-- unfinished tool round, then run to completion. A no-op-through-to-normal-run
-- if the session is already complete. Used by --resume and the cTUI on load.
function M.resume_turn(sess, on_text, opts)
  return M.run_on(sess, nil, on_text, opts)
end

-- Wire adapters are exposed under `_`-names for tests/wire.lua, which checks the
-- OpenAI Responses encode/decode pair without a live endpoint. They are internal;
-- nothing in the agent loop calls them by these names.
M._to_responses_body = to_responses_body
M._new_responses_decoder = new_responses_decoder
M._to_openai_body = to_openai_body

return M
