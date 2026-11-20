-- ctxgraph/outline.lua -- the collapsed view of a graph, and expanding one node.
--
-- The outline is the first message of a graph-compacted conversation: the
-- request, then one stub line per span, entity and claim, each with its id.
-- It is rebuilt from the backend at a compaction and not touched between
-- compactions (assumption 13), so the prompt prefix it belongs to stays
-- cached; an expansion goes into the tail instead.
local stubs = require("ctxgraph.stubs")
local util = require("util")

local M = {}

M.PREAMBLE = "[Earlier conversation compacted to a graph outline. Each line is a collapsed record: "
  .. "call expand{id} to see one in full, graph_recall{query} to search them. Nothing was deleted.]"
M.REQUEST = "[The request being worked on:]"
M.OUTLINE = "[Outline:]"
M.CONTINUES = "[Recent conversation continues below.]"

-- Sections in outline order. `drop` ranks what goes first when the outline is
-- over its budget (highest first); spans go last, oldest first.
local SECTIONS = {
  { title = "Spans (oldest first):", types = { span = true }, drop = 1 },
  { title = "Files:", types = { file = true }, drop = 3 },
  { title = "Packages:", types = { package = true }, drop = 4 },
  { title = "Tests:", types = { test = true }, drop = 5 },
  { title = "Errors:", types = { error = true }, drop = 6 },
  { title = "Threads:", types = { thread = true }, drop = 2 },
  { title = "Repeated commands:", types = { command = true }, drop = 7 },
  { title = "Claims:", types = { claim = true }, drop = 8 },
}

-- Which records earn an outline line. A command run once is in its step's
-- stub already; an exit-status claim repeats what its command line says.
local function listed(r)
  if r.type == "command" then return (r.frontmatter.runs or 1) >= 2 end
  if r.type == "claim" then return not tostring(r.frontmatter.predicate or ""):match("^exit=") end
  return true
end

function M.is_outline(text)
  return type(text) == "string" and text:sub(1, #M.PREAMBLE) == M.PREAMBLE
end

-- The request inside an outline message, or nil.
function M.request_of(text)
  if not M.is_outline(text) then return nil end
  local at = text:find("\n" .. M.REQUEST .. "\n", 1, true)
  if not at then return nil end
  local rest = text:sub(at + #M.REQUEST + 2)
  local cut = rest:find("\n\n" .. M.OUTLINE, 1, true) or rest:find("\n\n" .. M.CONTINUES, 1, true)
  return cut and rest:sub(1, cut - 1) or rest
end

-- render(be, sid, task, opts) -> text, stats
-- opts.cap_tokens bounds the outline (the request is bounded by the caller).
-- opts.inherit = { { sid, max_seq } }: read-only parent graphs (a fork's,
-- lua/ctxgraph.lua M.sources), nearest first. Their records as of the fork are
-- listed before the conversation's own, oldest ancestor first; an id the
-- conversation holds itself is listed once, as its own.
function M.render(be, sid, task, opts)
  opts = opts or {}
  local cap = (opts.cap_tokens or 8000) * 4
  local types = {}
  for _, s in ipairs(SECTIONS) do for t in pairs(s.types) do types[#types + 1] = t end end
  table.sort(types)
  local by = {}
  for i = 1, #SECTIONS do by[i] = {} end
  local own = be.scan(sid, types)
  local seen = {}
  for _, r in ipairs(own) do seen[r.id] = true end
  local rows = {}
  local inherit = opts.inherit or {}
  for k = #inherit, 1, -1 do
    local src = inherit[k]
    for _, r in ipairs(be.scan(src.sid, types)) do
      if not seen[r.id] and (src.max_seq == nil or (r.seq or 0) <= src.max_seq) then
        seen[r.id] = true
        rows[#rows + 1] = r
      end
    end
  end
  for _, r in ipairs(own) do rows[#rows + 1] = r end
  for _, r in ipairs(rows) do
    if listed(r) then
      for i, s in ipairs(SECTIONS) do
        if s.types[r.type] then by[i][#by[i] + 1] = "- " .. r.id .. "  " .. (r.stub ~= "" and r.stub or r.title) end
      end
    end
  end
  local function assemble(dropped)
    local parts = { M.PREAMBLE }
    if task and task ~= "" then parts[#parts + 1] = "\n" .. M.REQUEST .. "\n" .. task end
    parts[#parts + 1] = "\n" .. M.OUTLINE
    local n = 0
    for i, s in ipairs(SECTIONS) do
      if #by[i] > 0 then
        parts[#parts + 1] = s.title .. "\n" .. table.concat(by[i], "\n")
        n = n + #by[i]
      end
    end
    if dropped > 0 then
      parts[#parts + 1] = string.format("[%d more record%s not listed; graph_recall{query} finds them.]",
        dropped, dropped == 1 and "" or "s")
    end
    return table.concat(parts, "\n"), n
  end
  local dropped = 0
  local text, n = assemble(0)
  local function body_bytes() return #text - (task and #task or 0) end
  while body_bytes() > cap do
    local worst
    for i, s in ipairs(SECTIONS) do
      if #by[i] > 0 and (not worst or s.drop > SECTIONS[worst].drop) then worst = i end
    end
    if not worst then break end
    table.remove(by[worst], 1)   -- the oldest of the least useful kind
    dropped = dropped + 1
    text, n = assemble(dropped)
  end
  return text, { lines = n, bytes = #text, dropped = dropped }
end

-- ---- expand -----------------------------------------------------------------

M.EXPAND_BYTES = 6000   -- the bash tool's head limit (lua/tools.lua)
M.EXPAND_LINES = 200
M.SPAN_STEP_BYTES = 400 -- of each step's body, in a span's expansion

local function header(r)
  local s = "[" .. r.type .. "] " .. r.id .. "  " .. (r.stub ~= "" and r.stub or r.title)
  if r.state then s = s .. "\nstate: " .. r.state end
  return s
end

local function list(rs)
  local out = {}
  for _, r in ipairs(rs) do out[#out + 1] = "- " .. r.id .. "  " .. (r.stub ~= "" and r.stub or r.title) end
  return table.concat(out, "\n")
end

-- The rest of an output the step only kept the head of. The head is already
-- in the step's body, so the read-back starts after it and is itself bounded
-- like any tool output; the file's path is given for anything beyond.
local function read_ref(ref, body, room)
  local data = util.read_file(ref)
  if not data then return "\n[full output was saved to " .. ref .. "; that file is gone]" end
  local mark = body:find("\n\n%[output truncated:")
  local skip = 0
  if mark then
    -- the head runs from the line after the call's status (or its call line)
    local before = body:sub(1, mark - 1)
    local start = 1
    for pos in before:gmatch("()\n[>%[][^\n]*") do start = pos end
    local head = before:sub(start + 1):gsub("^[^\n]*\n", "", 1)
    skip = select(2, head:gsub("\n", "\n")) + 1
  end
  local rest, n = {}, 0
  for line in (data .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    if n > skip then rest[#rest + 1] = line end
  end
  local text = table.concat(rest, "\n")
  local cut = #text > room
  if cut then
    local c = room
    while c > 0 and ((text:byte(c + 1) or 0) & 0xC0) == 0x80 do c = c - 1 end
    text = text:sub(1, c)
  end
  return string.format("\n[full output, from line %d of %s]\n%s%s", skip + 1, ref, text,
    cut and ("\n[...cut; read " .. ref .. " for the rest]") or "")
end

-- expand(be, sid, id, opts) -> text | nil, err. Bounded by EXPAND_BYTES (or
-- opts.max_bytes): what does not fit is saved to a file and pointed at, the
-- same shape every large tool result has.
-- opts.max_seq: records put after it are left out of the lists (a fork reading
-- its parent's graph sees it as it was at the fork).
function M.expand(be, sid, id, opts)
  opts = opts or {}
  local max = opts.max_bytes or M.EXPAND_BYTES
  local r = be.get(sid, id)
  if r and opts.max_seq and (r.seq or 0) > opts.max_seq then r = nil end
  if not r then return nil, "no record " .. tostring(id) .. " in this conversation's graph" end
  local function vis(rs)
    if not opts.max_seq then return rs end
    local out = {}
    for _, x in ipairs(rs) do if (x.seq or 0) <= opts.max_seq then out[#out + 1] = x end end
    return out
  end
  local out = { header(r) }
  if r.type == "span" then
    for _, st in ipairs(vis(be.children(sid, id, "contains"))) do
      out[#out + 1] = "\n## " .. st.id .. "  " .. st.stub
      -- a taste of each step; expand the step for all of it
      local b = st.body or ""
      if #b > M.SPAN_STEP_BYTES then
        local cut = M.SPAN_STEP_BYTES
        while cut > 0 and ((b:byte(cut + 1) or 0) & 0xC0) == 0x80 do cut = cut - 1 end
        b = b:sub(1, cut) .. " [...]"
      end
      out[#out + 1] = b
    end
  elseif r.type == "step" then
    out[#out + 1] = r.body or ""
    for _, c in ipairs(vis(be.children(sid, id, "has_reasoning"))) do
      out[#out + 1] = "(reasoning collapsed: expand{id=\"" .. c.id .. "\"})"
    end
    if r.body_ref then out[#out + 1] = read_ref(r.body_ref, r.body or "", max) end
  elseif r.type == "file" or r.type == "package" or r.type == "command" or r.type == "test" or r.type == "error" then
    local vs = vis(be.versions(sid, id))
    if #vs > 0 then out[#out + 1] = "versions:\n" .. list(vs) end
    local steps = vis(be.referrers(sid, id))
    local touching = {}
    for _, s in ipairs(steps) do if s.type == "step" then touching[#touching + 1] = s end end
    if #touching > 0 then out[#out + 1] = "steps:\n" .. list(touching) end
    local claims = {}
    for _, c in ipairs(vis(be.referrers(sid, id, "about"))) do claims[#claims + 1] = c end
    if #claims > 0 then out[#out + 1] = "claims:\n" .. list(claims) end
  else
    if r.body and r.body ~= "" then out[#out + 1] = r.body end
    if #(r.links or {}) > 0 then
      local ls = {}
      for _, l in ipairs(r.links) do ls[#ls + 1] = "- " .. l.type .. " -> " .. l.dst end
      out[#out + 1] = "links:\n" .. table.concat(ls, "\n")
    end
  end
  local text = table.concat(out, "\n")
  -- a step with saved output carries its own bounded read-back
  if r.type == "step" and r.body_ref then return text end
  return util.shape_result(text, { max_bytes = max, head_lines = M.EXPAND_LINES })
end

return M
