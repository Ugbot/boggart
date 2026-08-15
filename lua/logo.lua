-- logo.lua -- the boggart mascot as terminal art: a wardrobe with a little robot
-- peeking around the door. Used by the scrolling REPL welcome and the cTUI.
-- The glyphs are all display-width 1 (box-drawing, bullet, undertie) so the frame
-- stays a clean rectangle in any monospace terminal.
local M = {}

M.art = [[
   ╭──────────────────────╮
   │  ┌────┐       ┌────┐ │
   │  │    │  ╷    │    │ │
   │  │    │(•‿•)  │    │ │
   │  │    │  ╰┘   │    │ │
   │  └────┘       └────┘ │
   ╰─────┰───────────┰────╯
         ╹           ╹]]

-- 256-colour version: plum wardrobe (97), marigold robot (214). The robot glyphs
-- toggle to marigold and back to plum; a single reset closes it. ANSI is only for
-- the scrolling REPL -- the cTUI draws the plain art into its cell grid.
local PLUM, MARI, RST = "\27[38;5;97m", "\27[38;5;214m", "\27[0m"
local function mari(s) return MARI .. s .. PLUM end
M.color = (PLUM .. M.art:gsub("%(•‿•%)", mari("(•‿•)"))
                        :gsub("╷", mari("╷"))
                        :gsub("╰┘", mari("╰┘"))) .. RST

-- A one-line mark for compact places (a prompt prefix, a narrow header).
M.small = "▐▛▜▌ boggart"

function M.render(color) return color and M.color or M.art end

return M
