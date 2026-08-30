-- markdownview.lua -- a rendered, read-only view of a Markdown document.
--
-- Opens for .md/.markdown files (see the dispatch in rootview.lua) and renders
-- them proportionally with headings, syntax-highlighted code, lists, quotes and
-- clickable links via the markdown.lua layout engine. `markdown:toggle-source`
-- swaps between this and an editable DocView on the same Doc; `markdown:preview`
-- opens a preview from a DocView.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local View = require "core.view"
local markdown = require "core.markdown"

local MarkdownView = View:extend()

local FONT_OPTS = { antialiasing = "grayscale", hinting = "slight" }
local function loadf(px)
  local ok, f = pcall(renderer.font.load, DATADIR .. "/fonts/font.ttf", px * SCALE, FONT_OPTS)
  return (ok and f) or style.font
end

function MarkdownView:new(doc)
  MarkdownView.super.new(self)
  self.scrollable = true
  self.cursor = "arrow"
  self.doc = doc
  self.hits = {}                 -- clickable link rects, rebuilt per draw
  self.fonts = {
    body = loadf(15), em = loadf(15), code = style.code_font,
    h = { loadf(26), loadf(22), loadf(19), loadf(17), loadf(16), loadf(15) },
  }
  self._layout, self._w, self._rev = nil, nil, nil
end

function MarkdownView:get_name()
  local n = (self.doc and self.doc:get_name() or "markdown"):match("[^/\\]*$")
  return n .. (self.doc and self.doc:is_dirty() and "*" or "") .. "  (preview)"
end

function MarkdownView:try_close(do_close) do_close() end

function MarkdownView:get_text()
  if not self.doc then return "" end
  return table.concat(self.doc.lines):gsub("\n$", "")
end

-- Load (and cache) a local image referenced from the document. Remote URLs are
-- skipped (shown as alt text); paths resolve against the .md file's directory.
-- The cache keeps each Image referenced so it is never GC'd while on screen, and
-- so a relayout does not re-decode it.
function MarkdownView:load_image(url)
  if type(url) ~= "string" or url:match("^%a[%w+.%-]*://") then return nil end
  self._imgcache = self._imgcache or {}
  local hit = self._imgcache[url]
  if hit ~= nil then
    if hit == false then return nil end
    return hit.img, hit.w, hit.h
  end
  local dir = (self.doc and self.doc.filename or ""):match("^(.*)[/\\][^/\\]*$") or "."
  local path = url:match("^[/\\~]") and url or (dir .. "/" .. url)
  local img = renderer.image_from_file(path)
  if not img then self._imgcache[url] = false; return nil end
  local w, h = img:size()
  self._imgcache[url] = { img = img, w = w, h = h }
  return img, w, h
end

function MarkdownView:ctx()
  local f = self.fonts
  local view = self
  return {
    body = f.body, em = f.em, code = f.code, h = f.h, syntax = true,
    measure = function(font, s) return font:get_width(s) end,
    load_image = function(url) return view:load_image(url) end,
    colors = {
      text = style.text, heading = style.accent,
      code = style.inline_code or style.text, quote = style.dim,
      link = style.link or style.accent, rule = style.divider,
      code_bg = style.background2, marker = style.dim, done = style.good,
    },
  }
end

function MarkdownView:relayout()
  self._layout = markdown.layout(self:get_text(), self.size.x, self:ctx())
  self._w = self.size.x
  self._rev = self.doc and self.doc:get_change_id()
end

function MarkdownView:get_scrollable_size()
  if not self._layout then return self.size.y end
  return math.max(self.size.y, self._layout.height)
end

function MarkdownView:update()
  local rev = self.doc and self.doc:get_change_id()
  if not self._layout or self._w ~= self.size.x or self._rev ~= rev then
    self:relayout()
  end
  MarkdownView.super.update(self)
end

function MarkdownView:draw()
  self:draw_background(style.background)
  if not self._layout then self:relayout() end
  local ox, oy = self:get_content_offset()
  local top, bot = self.scroll.y, self.scroll.y + self.size.y
  self.hits = {}
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  for _, row in ipairs(self._layout.rows) do
    if row.y + row.h >= top and row.y <= bot then
      local ry = oy + row.y
      if row.bg then
        renderer.draw_rect(ox + (row.x or 0), ry, row.w or self.size.x, row.h, row.bg)
      end
      if row.rule then
        renderer.draw_rect(ox + (row.x or 0), ry + math.floor(row.h / 2),
          row.w or self.size.x, math.max(1, SCALE), style.divider)
      end
      if row.kind == "image" and row.img then
        renderer.draw_image(row.img, ox + (row.x or 0), ry, row.w, row.h)
      end
      for _, run in ipairs(row.runs or {}) do
        local tx = ox + run.x
        local ty = ry + math.floor((row.h - run.font:get_height()) / 2)
        renderer.draw_text(run.font, run.text, tx, ty, run.color)
        if run.bold then
          renderer.draw_text(run.font, run.text, tx + math.max(1, SCALE * 0.5), ty, run.color)
        end
        if run.underline then
          renderer.draw_rect(tx, ty + run.font:get_height(), run.w, math.max(1, SCALE), run.color)
        end
        if run.url and run.text ~= "" then
          self.hits[#self.hits + 1] = { x = tx, y = ry, w = run.w, h = row.h, url = run.url }
        end
      end
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

function MarkdownView:open_link(url)
  if url:match("^%a[%w+.%-]*://") or url:match("^mailto:") then
    local plat = rawget(_G, "PLATFORM") or ""
    local opener = (plat == "Windows" and 'start ""')
      or (plat == "Mac OS X" and "open") or "xdg-open"
    core.log("Opening %s", url)
    pcall(system.exec, string.format("%s %q", opener, url))
  else
    local dir = (self.doc and self.doc.filename or ""):match("^(.*)[/\\][^/\\]*$") or "."
    local path = url:match("^[/\\]") and url or (dir .. "/" .. url)
    local ok = pcall(function()
      core.root_view:open_doc(core.open_doc(path))
    end)
    if not ok then core.log("Cannot open %s", path) end
  end
end

function MarkdownView:on_mouse_moved(x, y, dx, dy)
  MarkdownView.super.on_mouse_moved(self, x, y, dx, dy)
  self.cursor = "arrow"
  for _, h in ipairs(self.hits) do
    if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then
      self.cursor = "hand"; break
    end
  end
end

function MarkdownView:on_mouse_pressed(button, x, y, clicks)
  if MarkdownView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  for _, h in ipairs(self.hits) do
    if x >= h.x and x < h.x + h.w and y >= h.y and y < h.y + h.h then
      self:open_link(h.url); return true
    end
  end
  return true
end

-- Replace `oldview` in its node with a fresh view of the same Doc as `cls`.
local function swap_view(oldview, cls)
  local root = core.root_view.root_node
  local node = root:get_node_for_view(oldview)
  if not node then return end
  local newview = cls(oldview.doc)
  node:add_view(newview)                       -- becomes active, added after old
  node:set_active_view(oldview)
  node:close_active_view(root)                 -- closes old; active falls to new
  node:set_active_view(newview)
  core.set_active_view(newview)
  return newview
end

command.add(MarkdownView, {
  ["markdown:toggle-source"] = function()
    local DocView = require "core.docview"
    swap_view(core.active_view, DocView)
  end,
})

command.add(function()
  local v = core.active_view
  if not (v and v.doc and v.doc.filename) then return false end
  if v:is(MarkdownView) then return false end
  local ext = v.doc.filename:lower():match("%.([%w]+)$")
  return ext == "md" or ext == "markdown"
end, {
  ["markdown:preview"] = function()
    swap_view(core.active_view, MarkdownView)
  end,
})

keymap.add {
  ["ctrl+shift+m"] = "markdown:preview",
  ["ctrl+shift+e"] = "markdown:toggle-source",
}

return MarkdownView
