-- shell/theme.lua -- the studio's visual identity. One deliberate system applied
-- across all the shell chrome (menu bar, status bar, workspace tabs, docks) so it
-- reads as one product rather than a lite-xl default.
--
-- Direction: boggart is a shape-shifting agent that lives in the terminal, so the
-- palette is warm and ember-lit rather than the usual cool editor grey. Neutrals
-- are tinted toward the amber accent (a picked grey, not an inherited one); the
-- caret and links are a cool teal so they pop against the warm ground. It sets
-- core.style, so every existing view that draws through style.* is re-skinned for
-- free.
local style = require "core.style"
local common = require "core.common"

local M = {}

-- ember dark (default)
local DARK = {
  background = "#1c1b19", background2 = "#232120", background3 = "#201e1d",
  text = "#b9b3a8", accent = "#e8a33d", dim = "#6a655f",
  divider = "#141312", selection = "#3a342c", caret = "#63d1c6",
  line_highlight = "#262320", line_number = "#4a453f", line_number2 = "#8a847b",
  scrollbar = "#3a342c", scrollbar2 = "#4c453c",
  good = "#8fbf7a", error = "#e5736f", keyword = "#cb8fd0", warn = "#e8a33d",
  inline_code = "#e0a878", link = "#63d1c6",
  -- code syntax: warm to sit on the ember ground, with the teal caret reused for
  -- operators and calls so the eye lands on structure. The prose keyword/error
  -- hues carry straight over, so `code` in chat and code in EDIT rhyme.
  syntax = {
    ["normal"] = "#c9c3b8", ["symbol"] = "#c9c3b8", ["comment"] = "#6a655f",
    ["keyword"] = "#cb8fd0", ["keyword2"] = "#e5736f", ["number"] = "#e8a33d",
    ["literal"] = "#e8a33d", ["string"] = "#d9a866", ["operator"] = "#63d1c6",
    ["function"] = "#63d1c6",
  },
}

-- warm paper light (a picked warm grey, not the cream cliche)
local LIGHT = {
  background = "#eeece6", background2 = "#e6e2d9", background3 = "#eae7e0",
  text = "#37332d", accent = "#b06f14", dim = "#8b857b",
  divider = "#d6d0c4", selection = "#ddd6c7", caret = "#1c887b",
  line_highlight = "#e5e1d6", line_number = "#a79e90", line_number2 = "#5b564e",
  scrollbar = "#cfc7b8", scrollbar2 = "#bbb2a1",
  good = "#4f8f3f", error = "#c0392b", keyword = "#9b3fa0", warn = "#b06f14",
  inline_code = "#a0571c", link = "#1c887b",
  -- code syntax: dark warm ink on paper. normal/symbol were near-white before,
  -- which made EDIT unreadable on #eeece6 -- now they carry the text ink. Hues
  -- are saturated-but-legible, keyword/error kept in step with the prose palette
  -- and the teal caret reused for operators/calls.
  syntax = {
    ["normal"] = "#37332d", ["symbol"] = "#2e2a24", ["comment"] = "#7d776c",
    ["keyword"] = "#9b3fa0", ["keyword2"] = "#c0392b", ["number"] = "#a05e10",
    ["literal"] = "#a05e10", ["string"] = "#7a6414", ["operator"] = "#1c887b",
    ["function"] = "#1c887b",
  },
}

local function put(pal)
  for k, hex in pairs(pal) do
    if k == "syntax" then
      -- overlay only the color keys we define; leave any non-color entries of
      -- style.syntax (e.g. patterns) untouched. Runs on every apply(), so a
      -- dark<->light toggle reflips the syntax palette too.
      for sk, shex in pairs(hex) do style.syntax[sk] = { common.color(shex) } end
    else
      style[k] = { common.color(hex) }
    end
  end
  local core = require "core"
  core.redraw = true
end

M.current = "dark"

function M.apply(which)
  M.current = (which == "light") and "light" or "dark"
  put(M.current == "light" and LIGHT or DARK)
end

function M.toggle() M.apply(M.current == "dark" and "light" or "dark") end

return M
