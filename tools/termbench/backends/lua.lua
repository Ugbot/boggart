-- Historical reference: the exact Studio v1 parser frozen before native pane
-- integration. Window/PTY dependencies are inert and isolated
-- from package.loaded, so measuring bytes does not launch an app or a shell.
local M = { name = "studio-lua-reference", features = {
  alt_screen = false, scroll_regions = false, truecolor = false,
  color256 = false, wide = false, graphemes = false,
} }
local here = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local root = assert(here:match("^(.*)tools/termbench/backends/lua%.lua$"))
local Object = assert(loadfile(root .. "studio/data/core/object.lua"))()
local font = { get_width = function() return 1 end, get_height = function() return 1 end }
local deps = {
  core = {}, ["core.view"] = Object,
  ["core.style"] = { code_font = font },
  ["core.common"] = {
    clamp = function(n, lo, hi) return math.max(lo, math.min(hi, n)) end,
    color = function() return 0, 0, 0, 255 end,
  },
}
local env = setmetatable({ pty = {}, require = function(name)
  return assert(deps[name], "unsupported headless dependency: " .. name)
end }, { __index = _G })
local source_path = "tools/termbench/reference/terminalview-v1.lua"
local file = assert(io.open(root .. source_path, "rb"))
local source = file:read("a")
file:close()
M.source = { path = source_path, sha256 = require("hash_c").sha256(source) }
local TerminalView = assert(load(source, "@" .. root .. source_path, "t", env))()

function M.new(opts)
  opts = opts or {}
  local view = TerminalView { cmd = "termbench" }
  view.cols, view.rows = opts.cols or 80, opts.rows or 24
  view.lines = {}
  for i = 1, view.rows do view.lines[i] = {} end
  return {
    feed = function(_, bytes) view:feed(bytes) end,
    snapshot = function()
      local screen, scrollback = {}, {}
      for r, row in ipairs(view.lines) do
        local cells = {}
        for c = 1, view.cols do
          local cell = row[c]
          cells[c] = cell and { ch = cell.ch, fg = cell.fg, bg = cell.bg,
            bold = cell.bold, reverse = cell.reverse, underline = cell.underline }
            or { ch = " " }
        end
        local target = r < view:top() and scrollback or screen
        target[#target + 1] = cells
      end
      return { screen = screen, scrollback = scrollback,
        cursor = { row = view.cursor.row - view:top() + 1, col = view.cursor.col,
          visible = view.cursor_visible }, saved_cursor = view.saved_cursor,
        pen = { fg = view.fg, bg = view.bg, bold = view.bold,
          reverse = view.reverse, underline = view.underline },
        pending = { state = view.parse_state, csi = view.csi_buf,
          utf8 = view.utf8_buf, utf8_need = view.utf8_need } }
    end,
    close = function() view.lines = {} end,
  }
end
return M
