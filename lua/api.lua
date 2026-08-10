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
local M = {}

local ENDPOINT = "https://api.anthropic.com/v1/messages"

local cached_headers = nil
local function auth_headers()
  if cached_headers then return cached_headers end
  local h = { "anthropic-version: 2023-06-01", "content-type: application/json" }
  local key = os.getenv("ANTHROPIC_API_KEY")
  if key and #key > 0 then
    h[#h + 1] = "x-api-key: " .. key
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
      error("no ANTHROPIC_API_KEY set and `ant auth print-credentials` produced no token")
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

  local function handle(evt)
    local t = evt.type
    if t == "content_block_start" then
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
    return { role = "assistant", content = content }, stop_reason, stream_err
  end

  return { feed = feed, finish = finish }
end

-- ---- blocking transport (default mode) -------------------------------------
local function stream_once(body_tbl, on_text)
  local body = json.encode(body_tbl)
  local dec = new_decoder(on_text)
  local status, resp = http.request{
    url = ENDPOINT, method = "POST", headers = auth_headers(),
    body = body, on_chunk = dec.feed, timeout = 600,
  }
  dec.feed("\n")
  local msg, stop, serr = dec.finish()
  if serr then error(serr) end
  if status == nil then error("http transport error: " .. tostring(resp)) end
  if status == 401 then cached_headers = nil end
  if status ~= 200 then error("api http " .. status .. ": " .. tostring(resp)) end
  return msg, stop
end
M.stream_once = stream_once

-- ---- async transport (swarm mode; must run inside a scheduler coroutine) ----
local function stream_async(body_tbl, on_text)
  local body = json.encode(body_tbl)
  local dec = new_decoder(on_text)
  local raw = {}
  local req = http.begin{
    url = ENDPOINT, method = "POST", headers = auth_headers(), body = body, timeout = 600,
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
  if serr then error(serr) end
  if err then error("http transport error: " .. tostring(err)) end
  if status == 401 then cached_headers = nil end
  if status ~= 200 then error("api http " .. tostring(status) .. ": " .. table.concat(raw)) end
  return msg, stop
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

-- maybe_compact(sess?, opts?) -- defaults to the single-agent session + sync.
function M.maybe_compact(sess, opts)
  sess = sess or bog.session
  opts = opts or {}
  local stream = opts.async and stream_async or stream_once
  local system = opts.system or function() return bog.prompt.system() end

  local total = 0
  for _, m in ipairs(sess.messages) do total = total + #msg_text(m) end
  if total < (sess.compact_at or 400000) then return end

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

    local msg, stop = stream(body, on_text)
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
