-- story/cli.lua -- `boggart story ...`: the story layer from a shell or a git hook.
--
--   boggart story                                  the books (what /story shows)
--   boggart story chapters [book]                  the chapter navigator
--   boggart story <noun> <action> key=value ...    any `story` tool call, e.g.
--       boggart story book init path=.
--       boggart story style check n=7 book=novel
--
-- Exit status is 1 when the answer is an error (a style check that finds
-- issues is NOT an error; grep its VERDICT line).
local M = {}

-- -> text, exit code
function M.run(args)
  args = args or {}
  local parts = {}
  for _, w in ipairs(args) do
    local k, v = w:match("^([%w_]+)=(.*)$")
    if k and v:find("%s") then parts[#parts + 1] = k .. '="' .. v .. '"' else parts[#parts + 1] = w end
  end
  local width = tonumber(os.getenv("COLUMNS")) or 100
  local out = require("story.view").command(table.concat(parts, " "), width)
  return out, (out:find("^Error:") or out:find("^story: ")) and 1 or 0
end

return M
