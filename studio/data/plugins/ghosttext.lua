-- ghosttext.lua -- inline (Copilot-style) completion as REAL buffer bytes
-- painted a ghost colour. Off by default; `ghost-text:toggle` or
-- config.ghost_text = true turns it on (the popup provider stationcomplete
-- is the default surface -- running both would fight over the same prefix).
--
-- The representation is the NED ai_tab trick: the candidate's suffix is
-- spliced into the buffer for real and dimmed via the DocView colour-span
-- hook (BSTUD-65), so every piece of layout, wrap, cursor and scroll math
-- just works -- there is no phantom text with its own geometry. What keeps
-- it honest:
--
--   * Ghost splices go through doc:raw_insert/raw_remove with a SCRATCH
--     undo stack, so a dismissed ghost leaves no undo noise and undo can
--     never resurrect ghost bytes. Accepting removes the ghost the same
--     way and re-inserts the text as a normal edit in one commit_undo
--     bracket -- the undo step is exactly the accepted text.
--   * The caret never moves for a ghost: it stays at the prefix end, the
--     ghost begins after it. Typing, caret movement, or any other edit
--     dismisses first (the cancel-on-edit rule), then the keystroke does
--     what it always did.
--   * The protocol side is the unwired EditorProtocol's: ~300ms debounce,
--     live-buffer prefix, the prefix-guard rule (only a candidate that
--     case-insensitively STARTS WITH the typed prefix may complete it --
--     splicing a fuzzy match corrupts the word), request staleness by
--     caret+prefix key, single-line only.
--
-- Keys while a ghost is visible: tab accepts all, alt+right accepts one
-- word (pure index arithmetic on the ghost span), escape dismisses.
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
  -- Remove the ghost bytes via the scratch stack: no undo entry, and the
  -- refuse-don't-guess check first -- if the span no longer says what we
  -- spliced, something else edited it and we must not touch it.
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
  -- The splice moved the caret's sanity but not its position; pin it back to
  -- the prefix end so typing continues where the user left off.
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
    -- One word: the ghost's leading run of word chars plus any joiner right
    -- after it (pure index arithmetic, the ai_tab acceptWord rule).
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
  g.doc:insert(g.line, g.col, take) -- a real edit: THIS is the undo step
  g.doc:commit_undo()
  g.doc:set_selection(g.line, g.col + #take)
  if words and rest ~= "" then
    -- The unaccepted tail returns as a fresh ghost after the caret.
    stage(g.dv, g.line, g.col + #take, rest)
  end
  core.redraw = true
end

-- Cancel-on-edit and cancel-on-move, at the view seams (every buffer change
-- a user can make arrives through one of these or through a command that
-- moves the caret, which update() sees).
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

-- The fetch loop: same cadence and staleness discipline as stationcomplete,
-- but it takes only the TOP candidate and only under the prefix guard.
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
              -- The prefix guard: only a candidate that starts with what was
              -- typed may complete it.
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
