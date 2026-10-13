local terminal = require "terminal"
local hash = require "hash_c"
local M = { name = "boggart-c", features = {
  alt_screen = true, scroll_regions = true, truecolor = true, color256 = true,
  wide = false, graphemes = false,
} }
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local root = assert(here:match("^(.*)tools/termbench/backends/native%.lua$"))
M.source = terminal.source()
for _, file in ipairs(M.source.files) do
  local f = assert(io.open(root .. file.path, "rb")); local bytes = f:read("a"); f:close()
  assert(hash.sha256(bytes) == file.sha256, "stale terminal build; rebuild before measuring " .. file.path)
end
function M.new(opts)
  opts = opts or {}
  local t = terminal.new(opts.cols or 80, opts.rows or 24, 2000)
  return { feed = function(_, bytes) t:feed(bytes) end,
    snapshot = function() return t:snapshot(true) end,
    close = function() t:close() end }
end
return M
