-- conflicts.lua -- merge conflicts: detect <<<<<<< regions, tint each side,
-- float an accept row on the head.
--
-- Rendering rides the marks system (washes, action rows); this file draws
-- nothing itself. Detection re-runs when get_change_id() moves; the scan
-- gates on each line's first byte. Accept rebuilds from the current buffer
-- inside commit_undo() boundaries: one accept, one undo step. Regions
-- re-parse on every change, so a stale click cannot splice wrong lines.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"
local marks = require "core.marks"
local DocView = require "core.docview"

config.conflicts = true

local M = {}

-- Marker lines dim harder: scaffolding, not content.
local WASH_OURS   = { style.good[1],  style.good[2],  style.good[3],  20 }
local WASH_THEIRS = { style.link[1],  style.link[2],  style.link[3],  20 }
local WASH_BASE   = { style.warn[1],  style.warn[2],  style.warn[3],  14 }
local WASH_MARKER = { style.dim[1],   style.dim[2],   style.dim[3],   46 }

-- Exactly seven marker characters then end-of-line or whitespace, so a wall
-- of ======== in prose is not a conflict.
local BYTE = { [60] = "<<<<<<<", [124] = "|||||||", [61] = "=======", [62] = ">>>>>>>" }
local KIND = { ["<<<<<<<"] = "start", ["|||||||"] = "base",
               ["======="] = "sep",   [">>>>>>>"] = "stop" }

local function marker(line)
  local want = BYTE[line:byte(1)]
  if not want or line:sub(1, 7) ~= want then return nil end
  local rest = line:sub(8):gsub("\n$", "")
  if rest ~= "" and not rest:match("^[ \t]") then return nil end
  return KIND[want], rest:match("^%s*(.-)%s*$")
end

-- Scan into regions { s, b, m, e, ours, theirs }: marker line numbers (b nil
-- for a 2-way conflict) plus git's labels. Unterminated regions are dropped.
local function parse(doc)
  local regions, r = {}, nil
  for i, line in ipairs(doc.lines) do
    local kind, label = marker(line)
    if kind == "start" then
      r = { s = i, ours = label }
    elseif r then
      if kind == "base" and not r.m then r.b = i
      elseif kind == "sep" and not r.m then r.m = i
      elseif kind == "stop" and r.m then
        r.e, r.theirs = i, label
        regions[#regions + 1] = r
        r = nil
      end
    end
  end
  return regions
end

-- One scan result per doc per change_id; weak keys so a closed doc drops it.
local cache = setmetatable({}, { __mode = "k" })

local function head_actions(doc, idx)
  return {
    { label = "current",  tone = style.good,
      fn = function() M.accept(doc, idx, "ours") end },
    { label = "incoming", tone = style.link,
      fn = function() M.accept(doc, idx, "theirs") end },
    { label = "both",     tone = style.accent,
      fn = function() M.accept(doc, idx, "both") end },
  }
end

function M.refresh(doc)
  local st = cache[doc]
  local rev = doc.get_change_id and doc:get_change_id()
  if not rev then return nil end
  if st and st.rev == rev then return st.regions end

  if st then
    for _, g in ipairs(st.groups) do marks.clear_group(doc, g) end
  end
  local regions = parse(doc)
  local groups = {}
  for i, r in ipairs(regions) do
    local group = "conflict:" .. i .. ":" .. rev
    groups[#groups + 1] = group
    local function wash(line, hl)
      marks.set(doc, line, { kind = "changed", hl = hl, group = group })
    end
    wash(r.s, WASH_MARKER)
    -- Head line carries the label and the actions.
    marks.set(doc, r.s, {
      kind = "changed", hl = WASH_MARKER, group = group,
      text = string.format("%d/%d  %s vs %s", i, #regions,
        r.ours ~= "" and r.ours or "current",
        r.theirs ~= "" and r.theirs or "incoming"),
      data = { actions = head_actions(doc, i), conflict = i },
    })
    for l = r.s + 1, (r.b or r.m) - 1 do wash(l, WASH_OURS) end
    if r.b then
      wash(r.b, WASH_MARKER)
      for l = r.b + 1, r.m - 1 do wash(l, WASH_BASE) end
    end
    wash(r.m, WASH_MARKER)
    for l = r.m + 1, r.e - 1 do wash(l, WASH_THEIRS) end
    wash(r.e, WASH_MARKER)
  end
  cache[doc] = { rev = rev, regions = regions, groups = groups }
  return regions
end

-- Accept one side of region `idx`. The replacement comes from the buffer as
-- it stands (refresh() re-parsed at the current change_id), so nothing
-- recorded can go stale.
function M.accept(doc, idx, side)
  local regions = M.refresh(doc)
  local r = regions and regions[idx]
  if not r then core.error("conflict %d is gone", idx) return end

  local keep = {}
  if side == "ours" or side == "both" then
    for l = r.s + 1, (r.b or r.m) - 1 do keep[#keep + 1] = doc.lines[l] end
  end
  if side == "theirs" or side == "both" then
    for l = r.m + 1, r.e - 1 do keep[#keep + 1] = doc.lines[l] end
  end
  local text = table.concat(keep)

  doc:commit_undo()
  if r.e < #doc.lines then
    doc:remove(r.s, 1, r.e + 1, 1)
    doc:insert(r.s, 1, text)
  else
    -- Last line of the file: keep its newline, insert without one (marks.revert's shape).
    doc:remove(r.s, 1, r.e, #doc.lines[r.e])
    doc:insert(r.s, 1, (text:gsub("\n$", "")))
  end
  doc:commit_undo()
  doc:set_selection(r.s, 1)

  local left = M.refresh(doc)
  core.log("conflict resolved (%s), %d left", side, left and #left or 0)
end

-- Jump to the next/previous conflict head, wrapping.
local function jump(doc, dir)
  local regions = M.refresh(doc)
  if not regions or #regions == 0 then core.log("no conflicts") return end
  local line = doc:get_selection()
  local best
  if dir > 0 then
    for _, r in ipairs(regions) do
      if r.s > line then best = r break end
    end
    best = best or regions[1]
  else
    for i = #regions, 1, -1 do
      if regions[i].s < line then best = regions[i] break end
    end
    best = best or regions[#regions]
  end
  doc:set_selection(best.s, 1)
end

-- Region containing the caret.
local function region_at(doc, line)
  local regions = M.refresh(doc)
  for i, r in ipairs(regions or {}) do
    if line >= r.s and line <= r.e then return i end
  end
end

-- Re-detect once per edit; refresh() early-outs on an unchanged change_id.
local update = DocView.update
function DocView:update()
  update(self)
  if config.conflicts and self.doc and self.doc.lines then
    M.refresh(self.doc)
  end
end

local function doc()
  return core.active_view.doc
end

command.add("core.docview", {
  ["conflicts:next"] = function() jump(doc(), 1) end,
  ["conflicts:previous"] = function() jump(doc(), -1) end,
  ["conflicts:accept-current"] = function()
    local d = doc()
    local i = region_at(d, d:get_selection())
    if i then M.accept(d, i, "ours") else core.log("no conflict at caret") end
  end,
  ["conflicts:accept-incoming"] = function()
    local d = doc()
    local i = region_at(d, d:get_selection())
    if i then M.accept(d, i, "theirs") else core.log("no conflict at caret") end
  end,
  ["conflicts:accept-both"] = function()
    local d = doc()
    local i = region_at(d, d:get_selection())
    if i then M.accept(d, i, "both") else core.log("no conflict at caret") end
  end,
})

keymap.add {
  ["alt+shift+n"] = "conflicts:next",
  ["alt+shift+p"] = "conflicts:previous",
}

return M
