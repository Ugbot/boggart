-- ghosttext.lua -- inline completion as real buffer bytes painted a ghost
-- colour. Off by default; `ghost-text:toggle` turns it on. The popup
-- provider is the default surface; both would fight over one prefix.
--
-- The suffix is spliced into the buffer and dimmed via the colour-span hook,
-- so layout, wrap, cursor and scroll math need no phantom-text cases. Rules:
--
--   * Ghost splices use raw_insert/raw_remove with a scratch undo stack:
--     no undo noise, and undo cannot resurrect ghost bytes. Accept removes
--     the ghost the same way and re-inserts as one commit_undo edit.
--   * The caret never moves for a ghost. Typing, caret movement, or any
--     edit dismisses first; the keystroke then does what it always did.
--   * ~300ms debounce, live-buffer prefix, prefix guard (only a candidate
--     that starts with the typed prefix, case-insensitive; splicing a fuzzy
--     match corrupts the word), staleness by caret+prefix key, single line.
--
-- tab accepts all, alt+right accepts a word, escape dismisses.
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local translate = require "core.doc.translate"
local DocView = require "core.docview"

config.ghost_text = false

local GHOST = { style.dim[1], style.dim[2], style.dim[3], 255 }

-- The one live ghost: { dv, doc, line, col (ghost start), text }
local ghost = nil
local scratch = { idx = 1 } -- throwaway undo stack for ghost splices

local function paint(on)
  if not ghost then return end
  local dv = ghost.dv
  if on then
    dv:set_color_spans(ghost.line, {
      { ghost.col, ghost.col + #ghost.text, GHOST },
    })
  else
    dv:set_color_spans(ghost.line, nil)
  end
end

local function dismiss()
  if not ghost then return end
  local g = ghost
  ghost = nil
  paint(false)
  g.dv:set_color_spans(g.line, nil)
  -- Scratch-stack removal, only if the span still holds what we spliced.
  local have = g.doc:get_text(g.line, g.col, g.line, g.col + #g.text)
  if have == g.text then
    g.doc:raw_remove(g.line, g.col, g.line, g.col + #g.text, scratch, 0)
  end
  core.redraw = true
end

local function stage(dv, line, col, text)
  dismiss()
  text = text:match("^[^\n]*") or ""
  if text == "" then return end
  local doc = dv.doc
  doc:raw_insert(line, col, text, scratch, 0)
  -- Pin the caret at the prefix end; typing continues there.
  doc:set_selection(line, col)
  ghost = { dv = dv, doc = doc, line = line, col = col, text = text }
  paint(true)
  core.redraw = true
end

local function accept(words)
  if not ghost then return end
  local g = ghost
  local take = g.text
  if words then
    -- One word: the ghost's leading run of word characters.
    take = g.text:match("^%s*[%w_]+") or g.text:sub(1, 1)
  end
  local rest = g.text:sub(#take + 1)
  ghost = nil
  paint(false)
  g.dv:set_color_spans(g.line, nil)
  local have = g.doc:get_text(g.line, g.col, g.line, g.col + #g.text)
  if have ~= g.text then core.redraw = true return end
  g.doc:raw_remove(g.line, g.col, g.line, g.col + #g.text, scratch, 0)
  g.doc:commit_undo()
  g.doc:insert(g.line, g.col, take) -- the real edit; this is the undo step
  g.doc:commit_undo()
  g.doc:set_selection(g.line, g.col + #take)
  if words and rest ~= "" then
    -- The tail returns as a fresh ghost after the caret.
    stage(g.dv, g.line, g.col + #take, rest)
  end
  core.redraw = true
end

-- Cancel on edit and on caret movement, at the view seams.
local on_text_input = DocView.on_text_input
function DocView:on_text_input(text)
  if ghost and ghost.dv == self then dismiss() end
  return on_text_input(self, text)
end

local update = DocView.update
function DocView:update()
  if ghost and ghost.dv == self then
    local line, col = self.doc:get_selection()
    if line ~= ghost.line or col ~= ghost.col then dismiss() end
  end
  update(self)
end

-- Fetch loop: stationcomplete's cadence, top candidate only, prefix-guarded.
core.add_thread(function()
  local last_key
  while true do
    coroutine.yield(0.15)
    local stn = rawget(_G, "bog") and bog.station
    local av = core.active_view
    local dv = config.ghost_text and stn and av
      and getmetatable(av) == DocView and av.doc and av or nil
    if dv and dv.doc.filename and not ghost then
      local doc = dv.doc
      local line2, col2 = doc:get_selection()
      local line1, col1 = doc:position_offset(line2, col2, translate.start_of_word)
      local prefix = doc:get_text(line1, col1, line2, col2)
      local key = doc.filename .. ":" .. line2 .. ":" .. col2 .. ":" .. prefix
      if #prefix >= 3 and key ~= last_key then
        coroutine.yield(0.15)
        local l2b, c2b = doc:get_selection()
        if l2b == line2 and c2b == col2 and (stn.up() or stn.ensure()) then
          last_key = key
          local okr, h = pcall(function()
            return stn.conn:request("query", "tool_exec", "smart_complete", {
              file = doc.filename, line = tostring(line2),
              column = tostring(col2 - 1), prefix = prefix,
              line_text = doc.lines[line2], limit = "1", format = "json",
            }, 600)
          end)
          if okr and h then
            while not h:done() do coroutine.yield(0.02) end
            local p = h:wait()
            local l3, c3 = doc:get_selection()
            if p and p.data and l3 == line2 and c3 == col2 then
              local okj, decoded = pcall(require("json").decode, p.data)
              local top = okj and decoded and decoded.completions
                and decoded.completions[1]
              local label = top and top.label or ""
              -- Prefix guard: the candidate must start with what was typed.
              if #label > #prefix
                 and label:sub(1, #prefix):lower() == prefix:lower() then
                stage(dv, line2, col2, label:sub(#prefix + 1))
              end
            end
          end
        end
      end
    end
  end
end)

local function ghost_active()
  return ghost ~= nil and core.active_view == ghost.dv
end

command.add(ghost_active, {
  ["ghost-text:accept"] = function() accept(false) end,
  ["ghost-text:accept-word"] = function() accept(true) end,
  ["ghost-text:dismiss"] = function() dismiss() end,
})

command.add(nil, {
  ["ghost-text:toggle"] = function()
    config.ghost_text = not config.ghost_text
    if not config.ghost_text then dismiss() end
    core.log("ghost text: %s", config.ghost_text and "on" or "off")
  end,
})

keymap.add {
  ["tab"] = "ghost-text:accept",
  ["alt+right"] = "ghost-text:accept-word",
  ["escape"] = "ghost-text:dismiss",
}

return {}
