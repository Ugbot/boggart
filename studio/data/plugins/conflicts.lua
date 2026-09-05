-- conflicts.lua -- merge-conflict CodeLens: detect <<<<<<< regions, tint each
-- side, and float an accept row on the conflict head, so resolving a merge is
-- three readable choices instead of hand-deleting marker lines.
--
-- Everything visual rides the marks system: side washes are line washes,
-- the controls are a mark action row (data.actions), so this file contains no
-- drawing and no hit-testing of its own. Detection re-runs only when
-- doc:get_change_id() moves, and the scan byte-gates on the first character of
-- each line, so a keystroke in a conflict-free file costs one integer compare
-- per line at worst -- and nothing at all until the next edit.
--
-- Accepting rebuilds the replacement from the CURRENT buffer (the chosen
-- side's lines are already in it), wrapped in doc:commit_undo() boundaries so
-- one accept is exactly one undo step. The regions are re-parsed on every
-- change, so a stale click cannot splice the wrong lines: the mark that was
-- clicked died with the change_id that made it.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"
local marks = require "core.marks"
local DocView = require "core.docview"

config.conflicts = true

local M = {}

-- Side washes: ours in the calm green, theirs in the link blue, the optional
-- base in the warn orange, all at mark-wash alpha. Marker lines get the dim
-- tone a touch stronger -- they are scaffolding, not content.
local WASH_OURS   = { style.good[1],  style.good[2],  style.good[3],  20 }
local WASH_THEIRS = { style.link[1],  style.link[2],  style.link[3],  20 }
local WASH_BASE   = { style.warn[1],  style.warn[2],  style.warn[3],  14 }
local WASH_MARKER = { style.dim[1],   style.dim[2],   style.dim[3],   46 }

-- Marker classification, NED's rule: exactly seven marker characters followed
-- by end-of-line or whitespace, so a wall of ======== in prose is not a
-- conflict. Returns the kind and the label text after the marker.
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

-- Scan the buffer into regions { s, b, m, e, ours, theirs }: line numbers of
-- the start/base/sep/stop markers (b is nil for a 2-way conflict) plus the
-- labels git wrote after <<<<<<< and >>>>>>>. An unterminated region is
-- dropped rather than guessed at.
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

-- One scan result per doc, valid for one change_id. Weak keys: a closed doc
-- takes its cache with it.
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
    -- The head line also carries the label and the three answers.
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

-- Accept one side of region `idx`. The replacement is built from the buffer
-- as it stands right now -- refresh() just re-parsed it against the current
-- change_id -- so there is nothing recorded to go stale and nothing to guess.
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
    -- The stop marker is the last line; keep its final newline in place and
    -- insert the kept text without one, the same shape marks.revert uses.
    doc:remove(r.s, 1, r.e, #doc.lines[r.e])
    doc:insert(r.s, 1, (text:gsub("\n$", "")))
  end
  doc:commit_undo()
  doc:set_selection(r.s, 1)

  local left = M.refresh(doc)
  core.log("conflict resolved (%s) — %d left", side, left and #left or 0)
end

-- Jump the caret to the next/previous conflict head, wrapping: resolving a
-- merge is a loop, and stopping dead at the last one makes you scroll back.
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

-- The region the caret currently sits inside, for the keyboard accepts.
local function region_at(doc, line)
  local regions = M.refresh(doc)
  for i, r in ipairs(regions or {}) do
    if line >= r.s and line <= r.e then return i end
  end
end

-- Re-detect once per edit, driven from the docview's own update so an open
-- merge shows its conflicts without anyone asking. refresh() early-outs on an
-- unchanged change_id, so the steady-state cost is one comparison per frame.
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
