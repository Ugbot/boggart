-- ctxgraph/tools.lua -- the model's three graph tools, and the harness's own
-- expansion after each tool round (assumptions 15 and 16).
--
-- All three are offered only on a graph-memory tier (lua/tools.lua decides
-- that), and none needs approval: expand and graph_recall read the conversation's
-- own graph, and note adds an unverified claim to it, which changes nothing
-- outside the conversation.
local cg = require("ctxgraph")
local outline = require("ctxgraph.outline")
local ex = require("ctxgraph.extract")
local stubs = require("ctxgraph.stubs")
local ingest = require("ctxgraph.ingest")

local M = {}

local function need_graph(sess)
  if not (sess and cg.enabled(sess)) then
    return nil, "Tool error: graph memory is off for this conversation (BOGGART_MEMORY=local turns it on)"
  end
  return cg.backend(sess)
end

function M.expand(sess, a, by)
  local be, err = need_graph(sess)
  if not be then return err end
  local id = type(a) == "table" and a.id
  if type(id) ~= "string" or id == "" then return "Tool error: expand requires 'id' (a record id from the outline)" end
  -- its own graph first, then (a fork) its parent's as of the fork
  local _, src = cg.locate(sess, id)
  local text, why
  if src then text, why = outline.expand(be, src.sid, id, { max_seq = src.max_seq })
  else why = "no record " .. id .. " in this conversation's graph" end
  if not text then return "Tool error: " .. why .. ". graph_recall{query} finds ids." end
  cg.rt(sess).expanded[id] = true
  cg.count(sess, "expand", { id = id, by = by or "model", bytes = #text })
  return text
end

function M.recall(sess, a)
  local be, err = need_graph(sess)
  if not be then return err end
  local q = type(a) == "table" and a.query
  if type(q) ~= "string" or q == "" then return "Tool error: graph_recall requires 'query'" end
  local limit = math.max(1, math.min(tonumber(a.limit) or 8, 50))
  -- own records first, then a fork's parent's (as of the fork), each newest
  -- first; an id held by both is the conversation's own
  local hits, seen = {}, {}
  for _, src in ipairs(cg.sources(sess)) do
    if #hits >= limit then break end
    for _, h in ipairs(be.search(src.sid, q, { limit = limit })) do
      if #hits >= limit then break end
      if not seen[h.id] and cg.visible(h, src) then seen[h.id] = true; hits[#hits + 1] = h end
    end
  end
  cg.count(sess, "recall", { query_bytes = #q, hits = #hits })
  if #hits == 0 then return "No records match \"" .. stubs.line(q, 80) .. "\"." end
  local out = { string.format("%d record%s (newest first; expand{id} for one in full):", #hits, #hits == 1 and "" or "s") }
  for _, h in ipairs(hits) do out[#out + 1] = "- " .. h.id .. "  " .. h.stub end
  return table.concat(out, "\n")
end

function M.note(sess, a)
  local be, err = need_graph(sess)
  if not be then return err end
  local text = type(a) == "table" and a.text
  if type(text) ~= "string" or text == "" then return "Tool error: note requires 'text'" end
  local sid = cg.sid(sess)
  local about = type(a.about) == "string" and a.about ~= "" and a.about or nil
  -- The subject may be a parent's record (a fork): the claim then names it
  -- in frontmatter but carries no link, since a link must resolve inside the
  -- graph that holds it and the claim lives in this conversation's graph.
  local subject, subject_graph
  if about then
    for _, cand in ipairs({ about, "file/" .. ex.relpath(about, nil) }) do
      local r, src = cg.locate(sess, cand)
      if r then subject = cand; subject_graph = src.parent and src.sid or nil; break end
    end
  end
  local seq = tonumber(be.meta(sid, "seq") or "0") + 1
  be.meta(sid, "seq", tostring(seq))
  local id = "claim/" .. ex.sha((subject or about or "") .. "\0note:" .. text .. "\0" .. sid):sub(1, 16)
  local links = {}
  if subject and not subject_graph then links[1] = { type = "about", dst = subject } end
  local rec = { id = id, type = "claim", title = text, state = "unverified", seq = seq, links = links,
    frontmatter = { subject = subject or about, subject_graph = subject_graph, predicate = "note", origin = sid,
                    by = "model" },
    body = text, digest = ex.sha(text), tokens = (#text + 3) // 4 }
  rec.stub = stubs.claim(rec)
  local _, created = be.record_claim(sid, rec)
  cg.count(sess, "note", { id = id, about = subject })
  return (created and "Noted " or "Already noted ") .. id .. " [unverified]"
    .. (about and not subject and ("; '" .. about .. "' is not a record, so it is kept as text") or "")
end

M.defs = {
  expand = { effect = "read",
    description = "Show a collapsed record from the conversation outline in full: a span's steps, a step's "
      .. "messages and output, a file's versions, an error's occurrences. Pass the id exactly as the outline "
      .. "or graph_recall shows it. The outline itself does not change; the content arrives as this result.",
    input_schema = { type = "object", properties = {
      id = { type = "string", description = "record id, e.g. s/7/span/2 or file/src/parser.c" } },
      required = { "id" } } },
  graph_recall = { effect = "read",
    description = "Search this conversation's collapsed records by text (commands, paths, errors, what was "
      .. "done). Returns stub lines with ids, newest first; expand one to see it.",
    input_schema = { type = "object", properties = {
      query = { type = "string" }, limit = { type = "integer", description = "at most this many (default 8)" } },
      required = { "query" } } },
  note = { effect = "read",
    description = "Record a fact worth keeping across compactions, as an unverified claim (e.g. 'the tests "
      .. "need PYTHONPATH=src'). Pass `about` to attach it to a record id or a file path.",
    input_schema = { type = "object", properties = {
      text = { type = "string" }, about = { type = "string", description = "record id or file path" } },
      required = { "text" } } },
}
-- `graph_recall`, not `recall`: core memory already has a `recall` tool
-- (lua/memory.lua) that searches durable memory, a different store.
M.NAMES = { "expand", "graph_recall", "note" }
M.graph_recall = function(sess, a) return M.recall(sess, a) end

-- Tool definitions bound to a session getter (lua/tools.lua's calling_session).
function M.register_into(register, session_of)
  for _, name in ipairs(M.NAMES) do
    local d = M.defs[name]
    register(name, { description = d.description, input_schema = d.input_schema, effect = d.effect,
      graph_only = true,
      run = function(a) return M[name](session_of(), a) end })
  end
end

-- ---- harness auto-expand -------------------------------------------------------

-- The collapsed entities worth naming: files, packages and errors, with what
-- to look for in a step. Built once per compaction (the set only changes then).
local function index(sess, be)
  local rt = cg.rt(sess)
  if rt.index then return rt.index end
  local idx, seen = {}, {}
  for _, src in ipairs(cg.sources(sess)) do
    for _, r in ipairs(be.scan(src.sid, { "error", "file", "package" })) do
      local f = r.frontmatter or {}
      local key = r.type == "file" and f.path or (r.type == "package" and f.name) or f.line
      -- only collapsed records: what a live step touched is in the tail already
      if key and #key >= 3 and not seen[r.id] and cg.visible(r, src) and ingest.collapsed(r, src.live) then
        seen[r.id] = true
        idx[#idx + 1] = { id = r.id, type = r.type, key = key, src = src }
      end
    end
  end
  -- errors first (seeing the same failure again is the costliest repeat), then
  -- files, then packages; most recent first within a kind
  local rank = { error = 1, file = 2, package = 3 }
  table.sort(idx, function(a, b)
    if rank[a.type] ~= rank[b.type] then return rank[a.type] < rank[b.type] end
    return a.id < b.id
  end)
  rt.index = idx
  return idx
end

local function word_in(hay, w)
  local s = 1
  while true do
    local i, j = hay:find(w, s, true)
    if not i then return false end
    local before, after = hay:sub(i - 1, i - 1), hay:sub(j + 1, j + 1)
    if not before:match("[%w_%-/%.]") and not after:match("[%w_%-]") then return true end
    s = i + 1
  end
end

-- After a tool round: remember file digests (so versions get content keys),
-- then expand up to AUTOEXPAND_MAX collapsed records the round names, as a
-- marked text block on the round's own result message.
function M.after_round(sess, msg, rmsg)
  if not cg.enabled(sess) then return 0 end
  local rt = cg.rt(sess)
  local calls_text, results_text = {}, {}
  local results = {}
  if rmsg and type(rmsg.content) == "table" then
    for _, b in ipairs(rmsg.content) do
      if b.type == "tool_result" then results[b.tool_use_id] = type(b.content) == "string" and b.content or "" end
    end
  end
  for _, b in ipairs(msg.content or {}) do
    if b.type == "tool_use" then
      local inp = b.input or {}
      if (b.name == "write" or b.name == "edit") and type(inp.path) == "string" then
        local data = require("util").read_file(inp.path)
        if data then rt.digests[b.id] = ex.sha(data) end
      end
      for _, k in ipairs({ "path", "command", "task" }) do
        if type(inp[k]) == "string" then calls_text[#calls_text + 1] = inp[k] end
      end
      local r = results[b.id]
      if r and (r:sub(1, 11) == "Tool error:" or (ex.exit_code(r) or 0) ~= 0) then
        results_text[#results_text + 1] = ex.error_line(r) or ""
      end
    elseif b.type == "text" then
      calls_text[#calls_text + 1] = b.text or ""
    end
  end
  if os.getenv("BOGGART_GRAPH_AUTOEXPAND") == "0" or sess.graph_autoexpand == false then return 0 end
  if not (rmsg and type(rmsg.content) == "table") then return 0 end
  local be = cg.backend(sess)
  local named = table.concat(calls_text, "\n")
  local picked = {}
  for _, e in ipairs(index(sess, be)) do
    if #picked >= cg.AUTOEXPAND_MAX then break end
    if not rt.expanded[e.id] then
      local hit
      if e.type == "error" then
        for _, l in ipairs(results_text) do if l == e.key then hit = true end end
      else
        hit = word_in(named, e.key)
      end
      if hit then picked[#picked + 1] = e end
    end
  end
  local budget = cg.AUTOEXPAND_TOKENS * 4
  local n = 0
  for _, e in ipairs(picked) do
    local room = budget - 200
    if room < 400 then break end
    local text = outline.expand(be, e.src.sid, e.id, { max_bytes = math.min(room, outline.EXPAND_BYTES),
                                                      max_seq = e.src.max_seq })
    if text then
      local block = "[harness: auto-expanded " .. e.id .. ", which this step names; it was collapsed at an "
        .. "earlier compaction. Read-only view.]\n" .. text
      rmsg.content[#rmsg.content + 1] = { type = "text", text = block }
      budget = budget - #block
      rt.expanded[e.id] = true
      n = n + 1
      cg.count(sess, "expand", { id = e.id, by = "harness", bytes = #block })
    end
  end
  return n
end

return M
