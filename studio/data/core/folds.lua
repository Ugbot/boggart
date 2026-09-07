-- folds.lua -- fold ranges, collapsed state, and the hidden-line answer the
-- display-row builder asks. Detection: a bracket-stack walk (string and
-- comment aware) for brace languages, an indent walk otherwise. A range is
-- { s = start_line, e = end_line, collapsed }.
--
-- Collapsed state survives re-detection: collapsed start lines are
-- snapshotted before a rescan and re-applied after. `version` bumps on every
-- toggle so the row cache keys on (change_id, fold version).
local M = {}

local BRACE_EXTS = {
  c = true, h = true, cpp = true, hpp = true, cc = true, cxx = true, hh = true,
  js = true, jsx = true, ts = true, tsx = true, java = true, cs = true,
  go = true, rs = true, kt = true, swift = true, css = true, json = true,
  zig = true, glsl = true, proto = true,
}

-- One byte scan with a brace stack. Only a pair spanning lines makes a range.
local function detect_by_brackets(lines)
  local ranges, stack = {}, {}
  local in_block_comment, in_string, string_ch = false, false, nil
  for ln = 1, #lines do
    local s = lines[ln]
    local i, n = 1, #s
    local in_line_comment = false
    in_string, string_ch = false, nil -- strings do not span lines here
    while i <= n do
      local c = s:sub(i, i)
      local c2 = s:sub(i, i + 1)
      if in_block_comment then
        if c2 == "*/" then in_block_comment = false; i = i + 1 end
      elseif in_line_comment then
        break
      elseif in_string then
        if c == "\\" then i = i + 1
        elseif c == string_ch then in_string = false end
      elseif c2 == "//" then in_line_comment = true
      elseif c2 == "/*" then in_block_comment = true; i = i + 1
      elseif c == '"' or c == "'" then in_string, string_ch = true, c
      elseif c == "{" then
        stack[#stack + 1] = ln
      elseif c == "}" then
        local open = table.remove(stack)
        if open and ln > open then
          ranges[#ranges + 1] = { s = open, e = ln }
        end
      end
      i = i + 1
    end
  end
  return ranges
end

local function indent_of(line)
  if line:match("^%s*$") then return -1 end -- blank belongs to any fold
  local ws = line:match("^[ \t]*")
  return #(ws:gsub("\t", "    "))
end

-- A line whose next non-blank indents deeper folds until indent <= base.
local function detect_by_indent(lines)
  local ind = {}
  for i = 1, #lines do ind[i] = indent_of(lines[i]) end
  local ranges = {}
  for i = 1, #lines - 1 do
    local base = ind[i]
    if base >= 0 then
      local j = i + 1
      while j <= #lines and ind[j] == -1 do j = j + 1 end
      if j <= #lines and ind[j] > base then
        local e = j
        while e + 1 <= #lines and (ind[e + 1] == -1 or ind[e + 1] > base) do
          e = e + 1
        end
        while e > j and ind[e] == -1 do e = e - 1 end -- drop trailing blanks
        if e > i then ranges[#ranges + 1] = { s = i, e = e } end
      end
    end
  end
  return ranges
end

local states = setmetatable({}, { __mode = "k" })

local function detect(doc)
  local ext = (doc.filename or ""):match("%.(%w+)$")
  local ranges = (ext and BRACE_EXTS[ext:lower()])
    and detect_by_brackets(doc.lines)
    or detect_by_indent(doc.lines)
  table.sort(ranges, function(a, b)
    if a.s ~= b.s then return a.s < b.s end
    return a.e > b.e
  end)
  return ranges
end

-- Fold state per doc, recomputed when the buffer changes.
function M.get(doc)
  local st = states[doc]
  local rev = doc.get_change_id and doc:get_change_id() or 0
  if st and st.rev == rev then return st end
  local was = {}
  if st then
    for _, r in ipairs(st.ranges) do
      if r.collapsed then was[r.s] = true end
    end
  end
  local ranges = detect(doc)
  for _, r in ipairs(ranges) do r.collapsed = was[r.s] or false end
  st = { ranges = ranges, rev = rev, version = (st and st.version or 0) + 1,
         hidden = nil }
  states[doc] = st
  return st
end

-- hidden[line] = the fold-start line that hides it. Lazy per rescan/toggle.
function M.hidden(doc)
  local st = M.get(doc)
  if not st.hidden then
    local h = {}
    for _, r in ipairs(st.ranges) do
      if r.collapsed then
        for l = r.s + 1, r.e do
          if not h[l] then h[l] = r.s end
        end
      end
    end
    st.hidden = h
  end
  return st.hidden
end

-- The range starting at `line`, or nil.
function M.range_at(doc, line)
  for _, r in ipairs(M.get(doc).ranges) do
    if r.s == line then return r end
    if r.s > line then return nil end
  end
end

function M.toggle(doc, line)
  local st = M.get(doc)
  local r = M.range_at(doc, line)
  if not r then return false end
  r.collapsed = not r.collapsed
  st.version = st.version + 1
  st.hidden = nil
  return true
end

function M.set_all(doc, collapsed)
  local st = M.get(doc)
  for _, r in ipairs(st.ranges) do r.collapsed = collapsed end
  st.version = st.version + 1
  st.hidden = nil
end

-- Bumps on toggle and rescan; half of the row builder's cache key.
function M.version(doc)
  local st = M.get(doc)
  return st.version
end

return M
