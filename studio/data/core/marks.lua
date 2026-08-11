-- marks.lua -- decorations that live beside a buffer instead of inside it.
--
-- Taken from Neovim's extmarks. An annotation is anchored to a line, is carried
-- along by edits to the text above it, and is drawn without ever becoming part
-- of the document: nothing in this file can change what a file says, and none
-- of it can be saved to disk. That separation is the whole point. The agent's
-- account of what it did has to sit against the code it changed, and it has to
-- be impossible to accidentally commit.
--
-- The store is a hash from line number to the marks on that line, because the
-- editor asks exactly one question sixty times a second -- "is there anything
-- on line 412?" -- and answering it must not cost a walk of every mark in the
-- file. Everything here that is O(marks) happens on an edit or a command, never
-- inside a frame.
--
-- WHAT TRACKS AND WHAT DOES NOT. Marks follow `Doc:raw_insert` and
-- `Doc:raw_remove`, which is every edit made through the buffer -- typing,
-- paste, undo, redo, a plugin. Line granularity: a mark names a line, not a
-- column, so an edit within a line moves nothing and costs nothing. What does
-- NOT track is a change that never passes through the buffer: the agent writes
-- files on disk, and `Doc:reload` replaces the line table wholesale. That case
-- is handled by `marks.shift`, called from `from_edit` below, and it is only as
-- good as the diff it is given -- one contiguous hunk. Two agent edits far
-- apart in one write will leave the earlier marks off by the second hunk's
-- delta.
local style = require "core.style"
local difflib = require "core.diff"

local marks = {}

-- Sign colour per kind, and the alpha of the wash drawn across the line. The
-- wash is the same hue at low alpha rather than a new palette entry: a whole
-- line of solid green is a traffic light, not an annotation.
local KIND = {
  added   = { tone = "good",  alpha = 30 },
  changed = { tone = "warn",  alpha = 26 },
  removed = { tone = "error", alpha = 26 },
  info    = { tone = "dim",   alpha = 22 },
  error   = { tone = "error", alpha = 40 },
}

local washes = {}

function marks.color(kind)
  local k = KIND[kind or "info"] or KIND.info
  return style[k.tone] or style.dim
end

-- The whole-line highlight for a mark. `m.hl` wins if the caller supplied one;
-- otherwise the kind's hue at the kind's alpha. Memoised because this is read
-- once per marked visible line per frame and allocating a colour table sixty
-- times a second to say the same thing is exactly the kind of per-frame litter
-- the loop cannot afford.
function marks.wash(m)
  if type(m) == "table" and m.hl then return m.hl end
  local kind = (type(m) == "table" and m.kind) or m or "info"
  local w = washes[kind]
  if not w then
    local k = KIND[kind] or KIND.info
    local c = style[k.tone] or style.dim
    w = { c[1], c[2], c[3], k.alpha }
    washes[kind] = w
  end
  return w
end

-- ---------------------------------------------------------------------------
-- The store
-- ---------------------------------------------------------------------------

local stores = {}                                 -- by absolute path
local anon = setmetatable({}, { __mode = "k" })   -- unsaved docs, by identity
local next_id = 0

local function abs(path)
  if type(path) ~= "string" or path == "" then return nil end
  local ok, p = pcall(function() return system.absolute_path(path) end)
  return (ok and p) or path
end

-- A store key, from either a Doc or a path. Resolving a path is a syscall and
-- the view asks for this every frame, so the answer is cached on the doc and
-- recomputed only if the doc is saved somewhere else.
local function key_of(target)
  if type(target) == "table" then
    local name = target.filename
    if not name then return nil, target end
    if target.marks_key_of ~= name then
      target.marks_key_of, target.marks_key = name, abs(name)
    end
    return target.marks_key, target
  end
  return abs(target), nil
end

local function reindex(st)
  local by_line = {}
  for _, m in ipairs(st.list) do
    local at = by_line[m.line]
    if at then at[#at + 1] = m else by_line[m.line] = { m } end
  end
  st.by_line, st.sorted = by_line, nil
  st.version = st.version + 1
end

-- The decoration store for a target, or nil. Pass `create` to make one.
function marks.store(target, create)
  local key, doc = key_of(target)
  local st = key and stores[key] or (doc and anon[doc])
  if not st and create then
    st = { list = {}, by_line = {}, n = 0, version = 0 }
    if key then stores[key] = st else anon[doc] = st end
  end
  return st
end

-- Attach a decoration to a line. `opts` may carry:
--   kind   "added" | "changed" | "removed" | "info" | "error"
--   text   virtual text drawn past the end of the line, dimmed
--   hl     a colour for the whole-line wash, overriding the kind's
--   group   an opaque tag, so the marks of one hunk can be cleared together
--   data   anything at all; handed back by get/all and used by revert
function marks.set(target, line, opts)
  opts = opts or {}
  local st = marks.store(target, true)
  if not st then return nil end
  next_id = next_id + 1
  local m = {
    id = next_id,
    line = math.max(1, math.floor(tonumber(line) or 1)),
    kind = opts.kind or "info",
    text = opts.text, hl = opts.hl, data = opts.data, group = opts.group,
  }
  st.list[#st.list + 1] = m
  local at = st.by_line[m.line]
  if at then at[#at + 1] = m else st.by_line[m.line] = { m } end
  st.n, st.version, st.sorted = st.n + 1, st.version + 1, nil
  return m.id
end

-- `which` is a mark id, a kind, or nil for everything on the target.
function marks.clear(target, which)
  local st = marks.store(target)
  if not st or st.n == 0 then return 0 end
  if which == nil then
    local n = st.n
    st.list, st.by_line, st.n, st.sorted = {}, {}, 0, nil
    st.version = st.version + 1
    return n
  end
  local keep, gone = {}, 0
  for _, m in ipairs(st.list) do
    if m.id == which or m.kind == which then gone = gone + 1
    else keep[#keep + 1] = m end
  end
  if gone == 0 then return 0 end
  st.list, st.n = keep, #keep
  reindex(st)
  return gone
end

function marks.clear_group(target, group)
  local st = marks.store(target)
  if not st or group == nil then return 0 end
  local keep, gone = {}, 0
  for _, m in ipairs(st.list) do
    if m.group == group then gone = gone + 1 else keep[#keep + 1] = m end
  end
  if gone == 0 then return 0 end
  st.list, st.n = keep, #keep
  reindex(st)
  return gone
end

-- The marks on one line, or nil. This is the frame path: one hash lookup, and
-- the table handed back is the store's own. Treat it as read-only.
function marks.get(target, line)
  local st = marks.store(target)
  return st and st.by_line[line] or nil
end

-- Every mark on the target, in line order. Cached against the store's version
-- so that repeated calls between edits are free; used by navigation, which is a
-- command, not a frame.
function marks.all(target)
  local st = marks.store(target)
  if not st then return {} end
  if st.sorted and st.sorted.version == st.version then return st.sorted end
  local out = { version = st.version }
  for i, m in ipairs(st.list) do out[i] = m end
  table.sort(out, function(a, b)
    if a.line ~= b.line then return a.line < b.line end
    return a.id < b.id
  end)
  st.sorted = out
  return out
end

function marks.count(target)
  local st = marks.store(target)
  return st and st.n or 0
end

function marks.by_id(target, id)
  local st = marks.store(target)
  for _, m in ipairs(st and st.list or {}) do
    if m.id == id then return m end
  end
end

-- The first mark strictly after `line`, wrapping to the top of the file. The
-- wrap is deliberate: reviewing a file's changes is a loop, and stopping dead
-- at the last one makes you scroll back by hand.
function marks.next(target, line)
  local all = marks.all(target)
  if #all == 0 then return nil end
  for _, m in ipairs(all) do
    if m.line > line then return m.line, m end
  end
  return all[1].line, all[1]
end

function marks.prev(target, line)
  local all = marks.all(target)
  if #all == 0 then return nil end
  for i = #all, 1, -1 do
    local m = all[i]
    if m.line < line then return m.line, m end
  end
  local last = all[#all]
  return last.line, last
end

-- ---------------------------------------------------------------------------
-- Tracking edits
-- ---------------------------------------------------------------------------

-- Move every mark at or below `at` by `delta` lines. O(marks), and called from
-- an edit or a tool call -- never from a frame.
function marks.shift(target, at, delta)
  if delta == 0 then return end
  local st = marks.store(target)
  if not st or st.n == 0 then return end
  local moved = false
  for _, m in ipairs(st.list) do
    if m.line >= at then
      m.line = math.max(1, m.line + delta)
      moved = true
    end
  end
  if moved then reindex(st) end
end

-- Called from Doc:raw_insert. `nlines` is how many new lines the inserted text
-- created; when it is zero -- which is what almost every keystroke is -- there
-- is nothing to do and nothing is walked.
function marks.on_insert(doc, line, col, nlines)
  if nlines == 0 then return end
  local st = marks.store(doc)
  if not st or st.n == 0 then return end
  for _, m in ipairs(st.list) do
    -- Text inserted at the very start of a line pushes that line's content
    -- down with it, so a mark sitting on it goes too. Inserting mid-line
    -- leaves the start of the line where it was, and so the mark.
    if m.line > line or (m.line == line and col == 1) then
      m.line = m.line + nlines
    end
  end
  reindex(st)
end

-- Called from Doc:raw_remove, before the lines are spliced away.
function marks.on_remove(doc, line1, col1, line2, col2)
  local span = line2 - line1
  if span == 0 then return end
  local st = marks.store(doc)
  if not st or st.n == 0 then return end
  for _, m in ipairs(st.list) do
    if m.line > line2 then
      m.line = m.line - span
    elseif m.line > line1 then
      -- This mark's line has been spliced into line1. The mark goes with the
      -- surviving line rather than being dropped: deleting part of an agent
      -- hunk should still show that the agent was here, and a mark that
      -- vanishes when you touch it is a mark you cannot trust.
      m.line = line1
    end
  end
  reindex(st)
end

-- ---------------------------------------------------------------------------
-- From an agent edit
-- ---------------------------------------------------------------------------

-- Turn a before/after pair into marks: the same diff the approval gate shows,
-- put on the lines it describes. `opts.path` and `opts.tool` are carried in the
-- mark's data for whoever wants to know where it came from.
--
-- Context is zero here on purpose -- the approval pane wants surrounding lines
-- to read, the buffer already has them.
function marks.from_edit(target, old_text, new_text, opts)
  opts = opts or {}
  local d = difflib.compute(old_text or "", new_text or "", 0)
  if d.unchanged then return {} end

  local a, b = difflib.lines(old_text or ""), difflib.lines(new_text or "")
  local at = d.start_line
  local old_lines, new_lines = {}, {}
  for i = at, at + d.removed - 1 do old_lines[#old_lines + 1] = a[i] end
  for i = at, at + d.added - 1 do new_lines[#new_lines + 1] = b[i] end

  -- Marks below this hunk have to move by whatever it changed. They cannot
  -- find out any other way: the agent writes through the filesystem and the
  -- buffer is reloaded rather than edited, so raw_insert never sees it.
  marks.shift(target, at + d.removed, d.added - d.removed)

  local kind = (d.added == 0 and "removed")
    or (d.removed == 0 and "added" or "changed")
  local first = math.max(1, math.min(at, math.max(1, #b)))
  local last = d.added > 0 and (at + d.added - 1) or first
  local group = "hunk" .. tostring(next_id + 1)
  local ids = {}

  for line = first, last do
    -- Only the first line of a hunk carries the label and the controls. A
    -- "revert" button against every line of a fifty-line change is noise, and
    -- the thing being reverted is the hunk anyway.
    local head = (line == first)
    ids[#ids + 1] = marks.set(target, line, {
      kind = kind, group = group,
      text = head and string.format("agent +%d -%d", d.added, d.removed) or nil,
      data = head and {
        path = opts.path, tool = opts.tool, group = group,
        revert = { lines = old_lines, after = new_lines, count = d.added },
      } or nil,
    })
  end
  return ids
end

-- ---------------------------------------------------------------------------
-- Undoing one hunk
-- ---------------------------------------------------------------------------

-- Put back what the agent replaced, for the hunk this mark heads.
--
-- Refuses rather than guesses. The recorded text is what the agent wrote; if
-- the buffer no longer says that, something has edited it since, and pasting
-- the old text over the top would destroy that edit instead of the agent's.
function marks.revert(doc, m)
  if type(m) == "number" then m = marks.by_id(doc, m) end
  local r = m and m.data and m.data.revert
  if not r then return false, "no recorded change on this mark" end

  local line = m.line
  for i, want in ipairs(r.after) do
    local have = doc.lines[line + i - 1]
    if not have or (have:gsub("\n$", "")) ~= want then
      return false, "the buffer has changed since the agent wrote it"
    end
  end

  -- Drop the hunk's own marks first. What follows is a real buffer edit, and
  -- letting it drag these marks around only to delete them afterwards means a
  -- frame could be drawn with them halfway.
  marks.clear_group(doc, r.group or (m.data and m.data.group))

  local last = line + r.count - 1
  if r.count > 0 then
    if last >= #doc.lines then
      -- The final line keeps its newline: removing to the end of the last
      -- line's text stops short of it, so the text put back must not carry
      -- one of its own.
      doc:remove(line, 1, #doc.lines, #doc.lines[#doc.lines])
      doc:insert(line, 1, table.concat(r.lines, "\n"))
    else
      doc:remove(line, 1, last + 1, 1)
      doc:insert(line, 1, table.concat(r.lines, "\n") .. (#r.lines > 0 and "\n" or ""))
    end
  elseif #r.lines > 0 then
    doc:insert(line, 1, table.concat(r.lines, "\n") .. "\n")
  end

  doc:set_selection(line, 1)
  return true
end

-- ---------------------------------------------------------------------------
-- Binding a store to a document
-- ---------------------------------------------------------------------------

-- The agent names a file the way it was asked to -- often relatively -- and a
-- Doc names it however it was opened. `abs` reconciles most of that, but a file
-- marked before it was ever opened can still land under a different spelling.
-- Called from Doc:load, once, so a store keyed by a path that resolves to this
-- document's path is adopted rather than orphaned.
function marks.attach(doc)
  local key = key_of(doc)
  if not key or stores[key] then return end
  for k, st in pairs(stores) do
    if k ~= key and (k:sub(-#key) == key or key:sub(-#k) == k) then
      stores[key], stores[k] = st, nil
      return
    end
  end
end

return marks
