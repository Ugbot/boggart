-- ctxgraph/export.lua -- a conversation's graph as a LOKF-style bundle.
--
-- One Markdown file per record: YAML frontmatter (id, type, title, digest,
-- claim state, typed links, the record's own fields) and the body. Scalars
-- are written as JSON strings/numbers, which are valid YAML, so any YAML
-- reader loads the frontmatter; validate() below reads back exactly the
-- subset written here and checks every link resolves inside the bundle.
--
--   boggart --eval tools/graph_export.lua -- <session-id> <out-dir> [backend]
local json = require("json")

local M = {}

-- A file name for an id: path separators and anything unusual become `_`,
-- with a short digest so two ids cannot collide after the mangling.
function M.filename(id)
  local safe = id:gsub("[^%w%.%-@]", "_")
  if #safe > 100 then safe = safe:sub(1, 100) end
  return safe .. "." .. require("ctxgraph.extract").sha(id):sub(1, 8) .. ".md"
end

local function scalar(v)
  if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  return json.encode(tostring(v))
end

function M.render(r)
  local out = { "---", "id: " .. scalar(r.id), "type: " .. scalar(r.type), "title: " .. scalar(r.title or "") }
  if r.stub and r.stub ~= "" then out[#out + 1] = "stub: " .. scalar(r.stub) end
  out[#out + 1] = "digest: " .. scalar(r.digest or "")
  if r.state then out[#out + 1] = "state: " .. scalar(r.state) end
  if r.body_ref then out[#out + 1] = "body_ref: " .. scalar(r.body_ref) end
  if r.seq then out[#out + 1] = "seq: " .. tostring(r.seq) end
  local by = {}
  for _, l in ipairs(r.links or {}) do
    by[l.type] = by[l.type] or {}
    table.insert(by[l.type], l.dst)
  end
  local types = {}
  for t in pairs(by) do types[#types + 1] = t end
  table.sort(types)
  if #types > 0 then
    out[#out + 1] = "links:"
    for _, t in ipairs(types) do
      table.sort(by[t])
      out[#out + 1] = "  " .. t .. ":"
      for _, d in ipairs(by[t]) do out[#out + 1] = "    - " .. scalar(d) end
    end
  end
  local keys = {}
  for k, v in pairs(r.frontmatter or {}) do
    if type(v) ~= "table" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  if #keys > 0 then
    out[#out + 1] = "fields:"
    for _, k in ipairs(keys) do out[#out + 1] = "  " .. k .. ": " .. scalar(r.frontmatter[k]) end
  end
  out[#out + 1] = "---"
  out[#out + 1] = r.body or ""
  return table.concat(out, "\n") .. "\n"
end

-- write_bundle(be, sid, dir) -> { files = n, dir = dir }
function M.write_bundle(be, sid, dir)
  local util = require("util")
  sys.mkdir_p(dir)
  local b = be.export_bundle(sid)
  local n = 0
  for _, r in ipairs(b.records or {}) do
    assert(util.write_file(dir .. "/" .. M.filename(r.id), M.render(r)))
    n = n + 1
  end
  return { files = n, dir = dir }
end

local function unscalar(s)
  if s:sub(1, 1) == '"' then return json.decode(s) end
  if s == "true" then return true elseif s == "false" then return false end
  return tonumber(s) or s
end

-- parse(text) -> { fm = {...}, links = { type = {dst...} }, body } | nil, err
function M.parse(text)
  if text:sub(1, 4) ~= "---\n" then return nil, "no frontmatter" end
  local close = text:find("\n---\n", 4, true)
  if not close then return nil, "frontmatter not closed" end
  local fm, links, fields, section, ltype = {}, {}, {}, nil, nil
  for line in (text:sub(5, close) .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      local k, v = line:match("^([%w_]+):%s*(.*)$")
      if k then
        section = nil
        if v == "" then section = k else
          local ok, val = pcall(unscalar, v)
          if not ok then return nil, "bad value for " .. k end
          fm[k] = val
        end
      elseif section == "links" and line:match("^  [%w_]+:$") then
        ltype = line:match("^  ([%w_]+):$")
        links[ltype] = {}
      elseif section == "links" and ltype and line:match("^    %- ") then
        local ok, val = pcall(unscalar, line:match("^    %- (.*)$"))
        if not ok then return nil, "bad link" end
        table.insert(links[ltype], val)
      elseif section == "fields" and line:match("^  [%w_]+: ") then
        local fk, fv = line:match("^  ([%w_]+): (.*)$")
        local ok, val = pcall(unscalar, fv)
        if not ok then return nil, "bad field " .. fk end
        fields[fk] = val
      else
        return nil, "unexpected line: " .. line
      end
    end
  end
  return { fm = fm, links = links, fields = fields, body = text:sub(close + 5) }
end

-- validate(dir) -> ok, { files, links, errors = {...} }
function M.validate(dir)
  local util = require("util")
  local errs, parsed, ids = {}, {}, {}
  local names = sys.listdir(dir) or {}
  table.sort(names)
  for _, name in ipairs(names) do
    if name:match("%.md$") then
      local p, err = M.parse(util.read_file(dir .. "/" .. name) or "")
      if not p then errs[#errs + 1] = name .. ": " .. err
      else
        for _, req in ipairs({ "id", "type", "title", "digest" }) do
          if p.fm[req] == nil then errs[#errs + 1] = name .. ": missing " .. req end
        end
        if p.fm.type == "claim" and not p.fm.state then errs[#errs + 1] = name .. ": claim without state" end
        if p.fm.id then
          if ids[p.fm.id] then errs[#errs + 1] = name .. ": duplicate id " .. p.fm.id end
          ids[p.fm.id] = true
          if M.filename(p.fm.id) ~= name then errs[#errs + 1] = name .. ": file name does not match id" end
        end
        parsed[#parsed + 1] = { name = name, p = p }
      end
    end
  end
  local nlinks = 0
  for _, f in ipairs(parsed) do
    for t, dsts in pairs(f.p.links) do
      for _, d in ipairs(dsts) do
        nlinks = nlinks + 1
        if not ids[d] then errs[#errs + 1] = f.name .. ": link " .. t .. " -> " .. tostring(d) .. " does not resolve" end
      end
    end
  end
  return #errs == 0, { files = #parsed, links = nlinks, errors = errs }
end

return M
