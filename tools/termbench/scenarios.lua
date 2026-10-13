-- Complete repeating units keep workload size independent of escape/UTF-8 cuts.
local M = {}
local ESC = "\27["
local units = {
  { name = "plain", requires = {},
    data = "The quick brown fox jumps over the lazy dog. 0123456789\r\n" },
  { name = "dense-sgr", requires = { "truecolor", "color256" },
    data = ESC .. "31;1mred" .. ESC .. "0m " .. ESC .. "38;5;196mindexed"
      .. ESC .. "48;2;20;40;60m background" .. ESC .. "0m\r\n" },
  { name = "unicode", requires = { "wide", "graphemes" },
    data = "café Ελληνικά 日本語 e\u{301} 👩\u{200d}💻\r\n" },
  { name = "scroll", requires = {},
    data = ("scrolling row 0123456789\r\n"):rep(32) },
  { name = "alt-screen", requires = { "alt_screen", "scroll_regions" },
    data = ESC .. "?1049h" .. ESC .. "2J" .. ESC .. "H" .. "alternate"
      .. ESC .. "2;20r" .. ESC .. "20;1H" .. ("scroll\r\n"):rep(24)
      .. ESC .. "r" .. ESC .. "?1049l" .. "primary\r\n" },
}
function M.generate(bytes)
  assert(type(bytes) == "number" and bytes > 0 and bytes % 1 == 0,
    "bytes must be a positive integer")
  local out = {}
  for _, unit in ipairs(units) do
    out[#out + 1] = { name = unit.name, requires = unit.requires,
      data = unit.data:rep(math.ceil(bytes / #unit.data)) }
  end
  return out
end
return M
