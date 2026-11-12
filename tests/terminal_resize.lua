local terminal = require 'terminal'
local json = require 'json'
local f = assert(io.open('tests/fixtures/ghostty-resize.json', 'rb'))
local fixtures = json.decode(f:read('a')); f:close()
local function compare(actual, expected, path)
  assert(type(actual) == type(expected), path .. ': mismatched types')
  if type(expected) ~= 'table' then
    assert(actual == expected, path .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    return
  end
  for k, value in pairs(expected) do compare(actual[k], value, path .. '.' .. tostring(k)) end
  for k in pairs(actual) do assert(expected[k] ~= nil, path .. ': unexpected key ' .. tostring(k)) end
end
local function rows(input)
  local result = {}
  for y, row in ipairs(input) do
    local cells = {}
    for x, c in ipairs(row.cells) do
      local cps, uri = {}, {}
      for _, cp in utf8.codes(c.text) do cps[#cps + 1] = cp end
      if c.link then for i = 1, #c.link.uri do uri[i] = c.link.uri:byte(i) end end
      cells[x] = {cps = cps, width = c.width, head = c.flags & 4 ~= 0,
        protected = c.flags & 2 ~= 0, style = {c.style.fg, c.style.bg, c.style.underline, c.style.attrs}, uri = uri}
    end
    result[y] = {wrapped = row.wrapped, cells = cells}
  end
  return result
end
local function normalized(t)
  local s = t:snapshot(true)
  return {cols = s.cols, rows = s.rows, x = s.state.col - 1, y = s.state.row - 1,
    pending_wrap = s.state.pending_wrap, alternate = s.state.alternate,
    screen = rows(s.screen), scrollback = rows(s.scrollback)}
end
local count = 0
for _, case in ipairs(fixtures.cases) do
  local t <close> = terminal.new(case.columns, case.rows, fixtures.history_limit)
  compare(normalized(t), case.snapshots[1], case.name .. '.initial')
  count = count + 1
  for index, operation in ipairs(case.operations) do
    if operation.feed_hex then
      t:feed(operation.feed_hex:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end))
    else t:resize(operation.resize[1], operation.resize[2]) end
    compare(normalized(t), case.snapshots[index + 1], case.name .. '.operation' .. index)
    count = count + 1
  end
end
local expected_count = 0
for _, case in ipairs(fixtures.cases) do
  assert(#case.snapshots == #case.operations + 1, case.name .. ': incomplete fixture')
  expected_count = expected_count + #case.snapshots
end
assert(count == expected_count)
print(('Ghostty resize parity: %d cases, %d snapshots'):format(#fixtures.cases, count))
