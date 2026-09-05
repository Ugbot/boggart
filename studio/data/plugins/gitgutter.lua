-- gitgutter.lua -- changed-line bars against HEAD, and inline blame.
--
-- The buffer is diffed against `git show HEAD:file` (fetched once per doc,
-- again on save), so the gutter shows what THIS editing session has changed
-- whether or not it is saved yet. Deliberately not built on core.marks: marks
-- feed the agent-review surface (marks.review, alt+n), and a few hundred git
-- lines in there would bury the hunks the reviewer actually has to answer
-- for. This keeps its own per-doc line table and draws a 2px bar at the far
-- left of the gutter, beside -- not instead of -- the mark sign column.
--
-- All git commands run inside core.add_thread coroutines, where sys.exec
-- yields ("proc", handle) and the frame loop keeps running (the libraryview
-- lesson: a synchronous exec on the render path stalls every frame it takes).
-- The diff itself is in-memory (core.diff), debounced against change_id, and
-- only ever run for the active document.
--
-- Blame is `git blame --line-porcelain`, parsed into a dense per-line array
-- (every line carries full metadata in porcelain, so this is one pass), drawn
-- dim and right-aligned on the caret's line only. Off by default; toggling it
-- on fetches lazily.
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local difflib = require "core.diff"
local DocView = require "core.docview"
local Doc = require "core.doc"

config.git_gutter = true
config.git_blame = false

local M = {}

-- Per-doc state, weak keys so a closed doc takes its state with it:
--   head       HEAD's text, false when untracked/unreadable, nil = not fetched
--   rev        change_id the current line table was diffed at
--   lines      { [line] = "added"|"changed"|"removed" }
--   blame      { [line] = "author · date" }, nil until fetched
--   busy       a fetch/diff is in flight; don't start another
local state = setmetatable({}, { __mode = "k" })

local function st_of(doc)
  local st = state[doc]
  if not st then st = {} state[doc] = st end
  return st
end

local function dir_and_name(doc)
  if not doc.filename then return nil end
  local abs = system.absolute_path(doc.filename) or doc.filename
  local dir, name = abs:match("^(.*)[/\\]([^/\\]+)$")
  if not dir then return ".", abs end
  return dir, name
end

-- Diff HEAD against the buffer as it stands, into the per-line kind table.
-- Pure in-memory work; the exec that fetched HEAD already happened.
local function rediff(doc, st)
  local a = difflib.lines(st.head)
  local b = difflib.lines(table.concat(doc.lines))
  local out = {}
  for _, h in ipairs(difflib.hunks(a, b)) do
    if h.new_n == 0 then
      out[math.max(1, math.min(h.new, #b))] = "removed"
    else
      local kind = h.old_n == 0 and "added" or "changed"
      for l = h.new, h.new + h.new_n - 1 do out[l] = kind end
    end
  end
  st.lines, st.rev = out, doc:get_change_id()
end

-- Fetch HEAD's copy of the file, then diff. Runs on a studio thread so the
-- exec yields instead of blocking a frame.
local function fetch_head(doc)
  local st = st_of(doc)
  if st.busy then return end
  local dir, name = dir_and_name(doc)
  if not dir then st.head = false return end
  st.busy = true
  core.add_thread(function()
    local ok, out = pcall(sys.exec,
      string.format("git -C %q show HEAD:./%s", dir, name), 10)
    st.head = (ok and type(out) == "string" and out) or false
    if st.head then rediff(doc, st) end
    st.busy = false
    core.redraw = true
  end)
end

-- One porcelain pass into a dense per-line array. Every line of
-- --line-porcelain output carries its own header and metadata, so this is a
-- single forward scan: header gives the final line number, author/author-time
-- fill it in.
local function fetch_blame(doc)
  local st = st_of(doc)
  if st.blame or st.busy then return end
  local dir, name = dir_and_name(doc)
  if not dir then return end
  st.busy = true
  core.add_thread(function()
    local ok, out = pcall(sys.exec,
      string.format("git -C %q blame --line-porcelain -- %q", dir, name), 20)
    local blame = {}
    if ok and type(out) == "string" then
      local line, author, when
      for row in out:gmatch("[^\n]*") do
        local final = row:match("^%x+ %d+ (%d+)")
        if final then
          line, author, when = tonumber(final), nil, nil
        elseif row:match("^author ") then
          author = row:sub(8)
        elseif row:match("^author%-time ") then
          when = os.date("%Y-%m-%d", tonumber(row:sub(13)))
        elseif line and row:byte(1) == 9 then -- the content line closes a record
          blame[line] = (author or "?") .. " \u{00b7} " .. (when or "")
          line = nil
        end
      end
    end
    st.blame = blame
    st.busy = false
    core.redraw = true
  end)
end

-- The debounced re-diff: once per half second, only for the active doc, only
-- when the buffer actually changed since the last diff.
core.add_thread(function()
  while true do
    local view = core.active_view
    local doc = config.git_gutter and view and view.doc
    if doc and doc.filename and doc.get_change_id then
      local st = st_of(doc)
      if st.head == nil then
        fetch_head(doc)
      elseif st.head and st.rev ~= doc:get_change_id() then
        rediff(doc, st)
        core.redraw = true
      end
      if config.git_blame and not st.blame then fetch_blame(doc) end
    end
    coroutine.yield(0.5)
  end
end)

-- HEAD moves when the file is saved (and, close enough, when branches move
-- underneath us): refetch on save, and drop blame so it reloads lazily.
local save = Doc.save
function Doc:save(...)
  save(self, ...)
  local st = state[self]
  if st then st.head, st.blame, st.rev = nil, nil, nil end
end

local BAR = {
  added   = style.good,
  changed = style.warn,
  removed = style.error,
}

local draw_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(idx, x, y)
  draw_gutter(self, idx, x, y)
  if not config.git_gutter then return end
  local st = state[self.doc]
  local kind = st and st.lines and st.lines[idx]
  if kind then
    -- Far-left edge: the mark sign column sits at padding.x * 0.3, so the git
    -- bar at x+1 reads as a second, thinner rail rather than a collision.
    renderer.draw_rect(x + 1, y + 1, math.max(2, math.floor(2 * SCALE)),
      self:get_line_height() - 2, BAR[kind])
  end
end

local draw_body = DocView.draw_line_body
function DocView:draw_line_body(idx, x, y)
  draw_body(self, idx, x, y)
  if not config.git_blame then return end
  local line = self.doc:get_selection()
  if idx ~= line or core.active_view ~= self then return end
  local st = state[self.doc]
  local text = st and st.blame and st.blame[idx]
  if not text then return end
  -- Right-aligned in the view, clear of both the code and any mark controls.
  local font = self:get_font()
  local w = font:get_width(text)
  local tx = self.position.x + self.size.x - w - style.padding.x * 2
  renderer.draw_text(font, text, tx, y + self:get_line_text_y_offset(), style.dim)
end

command.add("core.docview", {
  ["git:toggle-gutter"] = function()
    config.git_gutter = not config.git_gutter
    core.log("git gutter: %s", config.git_gutter and "on" or "off")
  end,
  ["git:toggle-blame"] = function()
    config.git_blame = not config.git_blame
    core.log("git blame: %s", config.git_blame and "on" or "off")
  end,
})

return M
