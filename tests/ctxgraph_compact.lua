-- tests/ctxgraph_compact.lua -- graph-memory compaction (BOGGART_MEMORY=local).
--
-- The same long single turn tests/compact_long_turn.lua shrinks with a prose
-- summary, collapsed into a graph instead: smaller, the outline first, the
-- recent tail intact, no tool_result without its call, no model call, and a
-- second compaction that rebuilds the outline rather than nesting it. Then a
-- run through the turn loop checks the cache property: between compactions
-- every request extends the previous one, so system + tools + outline stay a
-- byte-identical prefix, and expansions only append.
-- Run: boggart --eval tests/ctxgraph_compact.lua
bog.store.open()
local json = require("json")
local window = require("window")
local outline = require("ctxgraph.outline")
local fails = 0
local function ck(ok, msg) if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end end
local function eq(a, b, msg) ck(a == b, string.format("%s (got %s, want %s)", msg, tostring(a), tostring(b))) end

local model_calls = 0
local function no_model(body)
  model_calls = model_calls + 1
  return { role = "assistant", content = { { type = "text", text = "SUMMARY" } } }, "end_turn"
end

local filler = string.rep("output line from a tool call\n", 400)  -- ~12 KB per result
local function long_turn(id, from, to, task)
  local s = { id = id, model = "mock", memory = "local", messages = {} }
  if task then s.messages[1] = { role = "user", content = task } end
  for i = from, to do
    local cid = "call_" .. i
    s.messages[#s.messages + 1] = { role = "assistant", content = {
      { type = "text", text = "Running step " .. i },
      { type = "tool_use", id = cid, name = "bash", input = { command = "make test " .. i } } } }
    s.messages[#s.messages + 1] = { role = "user", content = {
      { type = "tool_result", tool_use_id = cid, content = "[exit=" .. (i % 3 == 0 and 2 or 0) .. "]\n" .. filler } } }
  end
  return s
end

local function check_shape(s, label)
  local uses = {}
  for _, m in ipairs(s.messages) do
    if type(m.content) == "table" then
      for _, b in ipairs(m.content) do
        if b.type == "tool_use" then uses[b.id] = true end
        if b.type == "tool_result" then ck(uses[b.tool_use_id], label .. ": tool_result " .. b.tool_use_id .. " has its tool_use") end
      end
    end
  end
  for i = 2, #s.messages do ck(s.messages[i].role ~= s.messages[i - 1].role, label .. ": roles alternate at " .. i) end
end

-- ---- one compaction --------------------------------------------------------------
local sess = long_turn(301, 1, 30, "Fix the failing tests in this repository.")
local before = #json.encode(sess.messages)
local last_two = { json.encode(sess.messages[#sess.messages - 1]), json.encode(sess.messages[#sess.messages]) }
ck(bog.api.compact(sess, { stream = no_model, system = function() return "" end }) == true, "compaction ran")
eq(model_calls, 0, "graph compaction makes no model call")
local after = #json.encode(sess.messages)
ck(after < before / 2, string.format("the conversation at least halves: %d -> %d bytes", before, after))
local first = sess.messages[1].content
ck(outline.is_outline(first), "the first message is the outline")
ck(first:find("Fix the failing tests", 1, true), "the request survives")
ck(first:find("- s/301/span/1  ", 1, true), "spans are listed by id")
ck(not first:find("SUMMARY", 1, true), "no prose summary")
eq(json.encode(sess.messages[#sess.messages - 1]), last_two[1], "tail: the last call survives verbatim")
eq(json.encode(sess.messages[#sess.messages]), last_two[2], "tail: its result survives verbatim")
ck(window.tokens_of(sess.messages, 2) <= window.keep_budget(bog.api.compact_threshold(sess)), "tail within the keep budget")
check_shape(sess, "first compaction")
eq(bog.api.compaction_request(first), "Fix the failing tests in this repository.", "the request can be read back")
eq(sess.usage.graph.compactions, 1, "telemetry: one graph compaction")
ck(sess.usage.graph.outline_bytes[1] == #first, "telemetry: the outline's size")
local rows = bog.db:query("SELECT payload FROM records WHERE kind='graph' AND run_id=301")
ck(#rows == 1 and rows[1].payload:find('"event":"compacted"', 1, true), "telemetry: a graph record row for the bench export")

-- ---- a second compaction rebuilds, never nests ------------------------------------
local more = long_turn(301, 31, 50)
for _, m in ipairs(more.messages) do sess.messages[#sess.messages + 1] = m end
ck(bog.api.compact(sess, { stream = no_model, system = function() return "" end }) == true, "second compaction ran")
eq(model_calls, 0, "still no model call")
first = sess.messages[1].content
local _, npre = first:gsub("Earlier conversation compacted", "")
local _, nreq = first:gsub("%[The request being worked on:%]", "")
eq(npre, 1, "one preamble after two compactions")
eq(nreq, 1, "one request after two compactions")
local seen, dup = {}, false
for id in first:gmatch("\n%- (%S+)  ") do
  if seen[id] then dup = true end
  seen[id] = true
end
ck(not dup, "no record is listed twice")
ck(seen["s/301/span/1"], "the first compaction's spans are still listed")
local be = require("ctxgraph").backend(sess)
local steps = be.scan("301", { "step" })
local nums = {}
for _, st in ipairs(steps) do nums[#nums + 1] = st.frontmatter.n end
local contiguous = true
for i, n in ipairs(nums) do if n ~= i then contiguous = false end end
ck(contiguous and #nums > 30, "step numbers continue across compactions (" .. #nums .. " steps)")
eq(#be.scan("301", { "compaction" }), 2, "two compaction records")
check_shape(sess, "second compaction")

-- ---- through the turn loop: the cache property ----------------------------------------
do
  local WIN, rounds, prev, compacted_between = 60000, 0, nil, 0
  local result = string.rep("output line from a tool call\n", 400)
  local prefix_breaks, appends_ok, checked, expanded = 0, true, 0, false
  local tools_seen
  local function key(body)
    return json.encode({ system = body.system, tools = body.tools, first = body.messages[1] })
  end
  local function model(body, sink)
    model_calls = model_calls + 1
    local p = #json.encode({ system = body.system, messages = body.messages, tools = body.tools }) // 4
    ck(p + body.max_tokens <= WIN, string.format("request fits the window: %d + %d", p, body.max_tokens))
    local names = {}
    for _, t in ipairs(body.tools or {}) do names[#names + 1] = t.name end
    tools_seen = table.concat(names, ",")
    if prev then
      if key(prev) == key(body) then
        -- same outline: the whole previous request is a prefix of this one
        checked = checked + 1
        for i = 1, #prev.messages do
          if json.encode(prev.messages[i]) ~= json.encode(body.messages[i]) then appends_ok = false end
        end
      else
        prefix_breaks = prefix_breaks + 1
      end
    end
    prev = { system = body.system, tools = body.tools, messages = {} }
    for i, m in ipairs(body.messages) do prev.messages[i] = json.decode(json.encode(m)) end
    rounds = rounds + 1
    if rounds > 40 then
      return { role = "assistant", content = { { type = "text", text = "finished" } },
               usage = { input_tokens = p, output_tokens = 2 } }, "end_turn"
    end
    -- once the outline exists, expand its first span
    local first_msg = body.messages[1].content
    if not expanded and type(first_msg) == "string" and outline.is_outline(first_msg) then
      expanded = true
      local id = first_msg:match("\n%- (s/%S+/span/%d+)  ")
      return { role = "assistant", content = { { type = "tool_use", id = "x" .. rounds, name = "expand",
               input = { id = id } } }, usage = { input_tokens = p, output_tokens = 9 } }, "tool_use"
    end
    return { role = "assistant", content = { { type = "tool_use", id = "c" .. rounds, name = "bash",
             input = { command = "step " .. rounds } } }, usage = { input_tokens = p, output_tokens = 9 } }, "tool_use"
  end
  local s = { id = 302, model = "mock", context_limit = WIN, memory = "local", messages = {} }
  local calls_before = model_calls
  -- the tools find their session the way a live run does: the active one
  local saved = bog.session
  bog.session = s
  local _, stop = bog.api.run_on(s, "Port the parser to the new grammar.", nil, {
    stream = model, system = function() return "SYSTEM PROMPT" end,
    tools = function() return bog.tools.offered(s) end,
    run_tool = function(name, input)
      if name == "expand" then return bog.tools.run(name, input) end
      return "[exit=0]\n" .. result
    end })
  bog.session = saved
  eq(stop, "end_turn", "the long turn finished")
  local compactions = s.usage.graph and s.usage.graph.compactions or 0
  ck(compactions >= 2, "it compacted more than once (" .. compactions .. ")")
  eq(model_calls - calls_before, rounds, "every model call was a turn round: compaction called no model")
  eq(prefix_breaks, compactions, "the prefix changed only at compactions")
  ck(appends_ok and checked >= 20, "between compactions each request extends the previous one (" .. checked .. " checked)")
  ck(expanded and (s.usage.graph.expands_model or 0) == 1, "the model's expand ran and was counted")
  ck(tools_seen and tools_seen:find("expand,graph_recall,note", 1, true), "graph tools are offered: " .. tostring(tools_seen))
  local _, n_pre = s.messages[1].content:gsub("Earlier conversation compacted", "")
  eq(n_pre, 1, "one outline after repeated compactions")
end

-- ---- summary stays the default --------------------------------------------------------
do
  local s = long_turn(303, 1, 10, "task")
  s.memory = nil
  local calls = 0
  bog.api.compact(s, { stream = function() calls = calls + 1
    return { role = "assistant", content = { { type = "text", text = "SUMMARY" } } }, "end_turn" end,
    system = function() return "" end })
  eq(calls, 1, "without a memory tier, compaction is the prose summary")
  local names = {}
  for _, t in ipairs(bog.tools.offered(s)) do names[t.name] = true end
  ck(not names.expand and not names.graph_recall and not names.note, "graph tools are not offered on the summary tier")
end

-- ---- the coding profile carries the graph tools on a graph tier ---------------------
do
  assert(bog.tools.set_profile("coding"))
  local names = {}
  for _, t in ipairs(bog.tools.offered({ id = 304, memory = "local", messages = {} })) do names[#names + 1] = t.name end
  local list = table.concat(names, ",")
  ck(list:find("load_tools", 1, true) and list:sub(-#",expand,graph_recall,note") == ",expand,graph_recall,note",
    "coding profile + graph tier: graph tools follow the profile's: " .. list)
  names = {}
  for _, t in ipairs(bog.tools.offered({ id = 305, messages = {} })) do names[t.name] = true end
  ck(not names.expand, "coding profile on the summary tier: no graph tools")
  bog.tools.set_profile(nil)
end

if fails == 0 then io.write("ok  ctxgraph_compact: graph compaction shrinks, keeps the tail, keeps the prefix\n")
else io.write(string.format("FAIL ctxgraph_compact: %d check(s) failed\n", fails)); os.exit(1) end
