local terminal = require 'terminal'
local json = require 'json'
local hash = require 'hash_c'
local f = assert(io.open(os.getenv('BMUX_RESIZE_FIXTURE') or 'tests/fixtures/ghostty-resize-large.json', 'rb'))
local fixtures = json.decode(f:read('a')); f:close()
local target = require('uv').os_uname()
local system = target.sysname == 'Windows_NT' and 'Windows' or target.sysname
assert(system == fixtures.profile.system and target.machine == fixtures.profile.machine,
  'large resize boundary expectations require a verified SDK capture on this target; set BMUX_RESIZE_FIXTURE to its path')
local function digest(s)
  local parts = {'BMUX-RESIZE-1\0', string.pack('<I4I4I4I4BB', s.cols, s.rows,
    s.state.col - 1, s.state.row - 1, s.state.pending_wrap and 1 or 0, s.state.alternate and 1 or 0)}
  for _, input in ipairs({s.scrollback, s.screen}) do
    parts[#parts+1] = string.pack('<I4', #input)
    for _, row in ipairs(input) do
      parts[#parts+1] = string.pack('<BI4', row.wrapped and 1 or 0, #row.cells)
      for _, c in ipairs(row.cells) do
        local cps = {}; for _, cp in utf8.codes(c.text) do cps[#cps+1] = cp end
        local uri = c.link and c.link.uri or ''
        parts[#parts+1] = string.pack('<BBBI4', c.width, c.flags & 4 ~= 0 and 1 or 0,
          c.flags & 2 ~= 0 and 1 or 0, #cps)
        for _, cp in ipairs(cps) do parts[#parts+1] = string.pack('<I4', cp) end
        parts[#parts+1] = string.pack('<I4I4I4I4I4', c.style.fg, c.style.bg, c.style.underline, c.style.attrs, #uri)
        parts[#parts+1] = uri
      end
    end
  end
  return hash.sha256(table.concat(parts))
end
local count, failures = 0, {}
for _, case in ipairs(fixtures.cases) do
  local t <close> = terminal.new(case.columns, case.rows, fixtures.history_limit)
  local function check(step)
    local got = digest(t:snapshot(true)); count = count + 1
    if got ~= case.digests[step+1] then failures[#failures+1] = case.name .. '.step' .. step end
  end
  check(0)
  for index, operation in ipairs(case.operations) do
    if operation.feed_hex then t:feed(operation.feed_hex:gsub('..', function(pair) return string.char(tonumber(pair,16)) end))
    else t:resize(operation.resize[1],operation.resize[2]) end
    check(index)
  end
end
print(('SDK large resize: %d cases, %d snapshots, %d mismatches'):format(#fixtures.cases,count,#failures))
assert(#failures==0, table.concat(failures, '\n'))
