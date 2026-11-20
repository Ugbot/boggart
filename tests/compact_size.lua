-- tests/compact_size.lua -- the compaction summary request fits the summary model's window.
--
-- api.compact used to send the whole conversation. A conversation already over
-- the window (a resumed session, one huge tool result) or a utility model with
-- a smaller window than the session's had its summary request refused. The
-- request is now made to fit: the largest parts cut to a head, then, if need
-- be, the oldest messages left out (the request itself kept as text). The
-- transcript is never edited to make the request fit.
-- Run: boggart --eval tests/compact_size.lua
bog.store.open()
local json = require("json")
local api = bog.api

local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end

require("catalog").import({
  providers = { cstest = { url = "http://127.0.0.1:9", wire = "anthropic" } },
  models = { ["cs-small-utility"] = { provider = "cstest", context = 16000 } },
}, "test")

local function prompt_of(body)
  return #json.encode({ system = body.system, messages = body.messages }) // 4
end

local seen, calls
local function strict(win)
  return function(body)
    calls = calls + 1
    seen = body
    local p = prompt_of(body)
    ck(p + body.max_tokens <= win, string.format("summary request %d + max_tokens %d fits the %d window",
      p, body.max_tokens, win))
    return { role = "assistant", content = { { type = "text", text = "SUMMARY" } },
             usage = { input_tokens = p, output_tokens = 5 } }, "end_turn"
  end
end

local function conv(task, n, result)
  local msgs = { { role = "user", content = task } }
  for i = 1, n do
    msgs[#msgs + 1] = { role = "assistant", content = { { type = "text", text = "step " .. i },
      { type = "tool_use", id = "c" .. i, name = "bash", input = { command = "make " .. i } } } }
    msgs[#msgs + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = "c" .. i,
      content = type(result) == "function" and result(i) or result } } }
  end
  return msgs
end

-- A valid request: starts with a user message, roles alternate, every tool
-- result answers a tool call earlier in the request, ends with the prompt.
local function valid(body, label)
  local m = body and body.messages or {}
  ck(m[1] and m[1].role == "user", label .. ": starts with a user message")
  local uses = {}
  for i, x in ipairs(m) do
    if i > 1 then ck(x.role ~= m[i - 1].role, label .. ": roles alternate at " .. i) end
    if type(x.content) == "table" then
      for _, b in ipairs(x.content) do
        if b.type == "tool_use" then uses[b.id] = true end
        if b.type == "tool_result" then ck(uses[b.tool_use_id], label .. ": result " .. tostring(b.tool_use_id) .. " has its call") end
      end
    end
  end
  ck(json.encode(m[#m] or {}):find("context-compaction request", 1, true), label .. ": ends with the compaction prompt")
end

local function snapshot(msgs) return json.encode(msgs) end

-- ---- a conversation already over the window ------------------------------------------
do
  local WIN = 50000
  local result = string.rep("make: compiling unit\n", 600)   -- ~12.6 KB, ~3k tokens each
  local s = { id = 991, model = "cs-uncatalogued", context_limit = WIN,
              messages = conv("Port the parser to the new grammar.", 22, result) }
  local before = snapshot(s.messages)
  calls = 0
  local ok, err = pcall(api.compact, s, { stream = strict(WIN), system = function() return "be brief" end })
  ck(ok and calls == 1, "over-window conversation compacted in one call (" .. tostring(err) .. ")")
  valid(seen, "over-window")
  ck(seen and json.encode(seen.messages):find("Port the parser", 1, true), "the request text is in the summary request")
  ck(before ~= snapshot(s.messages), "the conversation was compacted")
end

-- ---- one huge tool result ------------------------------------------------------------------
do
  local WIN = 50000
  local s = { id = 992, model = "cs-uncatalogued", context_limit = WIN,
              messages = conv("Find the slow query.", 3, function(i)
                return i == 3 and string.rep("x", 400000) or "ok" end) }
  local copy = {}
  for i, m in ipairs(s.messages) do copy[i] = m end
  local huge_block = s.messages[7].content[1]
  calls = 0
  local ok, err = pcall(api.compact, s, { stream = strict(WIN), system = function() return "" end })
  ck(ok and calls == 1, "a huge tool result compacts (" .. tostring(err) .. ")")
  valid(seen, "huge result")
  local sent = seen and seen.messages[#seen.messages].content
  local r = type(sent) == "table" and sent[1] or {}
  ck(r.type == "tool_result" and type(r.content) == "string" and #r.content < 10000
     and r.content:sub(1, 100) == string.rep("x", 100),
     "the huge result goes as its head (" .. #tostring(r.content) .. " bytes)")
  ck(#huge_block.content == 400000, "the transcript's own block was not edited")
end

-- ---- a utility model with a smaller window -----------------------------------------------
do
  local s = { id = 993, model = "cs-uncatalogued", context_limit = 200000,
              messages = conv("Write the migration.", 40, string.rep("migration log line\n", 200)) }
  calls = 0
  local ok, err = pcall(api.compact, s, { stream = strict(16000), compact_route = "cs-small-utility",
                                          system = function() return "" end })
  ck(ok and calls == 1, "compacts through a 16k utility model (" .. tostring(err) .. ")")
  valid(seen, "utility")
  ck(seen and json.encode(seen.messages):find("Write the migration", 1, true), "the request text is kept")
  ck(seen and json.encode(seen.messages):find("earlier messages left out", 1, true), "the request says messages were left out")
end

-- ---- a request that fits is sent whole --------------------------------------------------
do
  local s = { id = 994, model = "cs-uncatalogued", context_limit = 200000,
              messages = conv("Small task.", 3, string.rep("line\n", 400)) }
  local n = #s.messages
  local before = {}
  for i, m in ipairs(s.messages) do before[i] = m end
  calls = 0
  api.compact(s, { stream = strict(200000), system = function() return "" end })
  ck(seen and #seen.messages == n, "every message is sent (" .. tostring(seen and #seen.messages) .. " of " .. n .. ")")
  for i = 1, n - 1 do ck(seen and seen.messages[i] == before[i], "message " .. i .. " sent as it was") end
end

-- ---- nothing fits: an error, nothing sent ------------------------------------------------
do
  local s = { id = 995, model = "cs-uncatalogued", context_limit = 20000,
              messages = conv("x", 2, "ok") }
  calls = 0
  local ok, err = pcall(api.compact, s, { stream = strict(20000),
    system = function() return string.rep("rules ", 20000) end })   -- ~30k tokens of system prompt
  ck(not ok and api.is_error(err) and err.kind == "context_window",
     "a context_window error (" .. tostring(err) .. ")")
  ck(calls == 0, "nothing was sent")
end

if fails == 0 then
  io.write("ok  compact_size: the summary request fits the summary model's window\n")
else
  io.write(string.format("FAIL compact_size: %d check(s) failed\n", fails))
  os.exit(1)
end
