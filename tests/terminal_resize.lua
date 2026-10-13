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
assert(count == 123)
print(('Ghostty resize parity: %d cases, %d snapshots'):format(#fixtures.cases, count))

local t <close> = terminal.new(12, 3, 1)
t:feed('\27[2;3r\27[1;4H\27H\27[?2004;1004h\27[>31u\27]0;kept\a\27[6n\xe2')
t:clipboard_policy(true, false); t:focus(false); t:ack_damage()
local before, input, policy = t:snapshot(true), t:input_state(), t:clipboard_policy()
t:resize(12, 3)
compare(t:snapshot(true), before, 'same_size_state')
assert(#t:damage() == 0)
for _, dimensions in ipairs{{0, 3}, {12, 0}, {4097, 3}, {12, 4097}, {1.5, 3}} do
  assert(not pcall(t.resize, t, dimensions[1], dimensions[2]))
  compare(t:snapshot(true), before, 'invalid_resize_state')
end
t:resize(14, 5)
compare(t:input_state(), input, 'resize_input_policy')
compare(t:clipboard_policy(), policy, 'resize_clipboard_policy')
compare(t:snapshot().pending, before.pending, 'resize_parser_fragment')
assert(t:state().top == 1 and t:state().bottom == 5 and #t:damage() == 5)
assert(#t:events() == 1 and t:replies():find('R', 1, true))
t:feed('\x82\xac')
assert(t:row(t:state().row).cells[t:state().col - 1].text == '€')
t:resize(4096, 1); assert(t:snapshot().cols == 4096 and t:snapshot().rows == 1)
t:resize(1, 4096); assert(t:snapshot().cols == 1 and t:snapshot().rows == 4096)
local copied = t:snapshot()
t:close(); assert(not pcall(t.resize, t, 2, 2) and copied.rows == 4096)
local tabs <close> = terminal.new(12, 3, 0)
tabs:feed('\27[1;4H\27H\27[H'); tabs:resize(12, 5); tabs:feed('\tZ')
assert(tabs:row(1).cells[4].text == 'Z', 'height-only resize preserves custom tabs')

for _, method in ipairs{'row', 'snapshot'} do
  local triggered = 0
  for iteration = 1, 10 do
    collectgarbage('collect'); collectgarbage('stop')
    local target <close> = terminal.new(method == 'row' and 4096 or 100, method == 'row' and 1 or 100, 0)
    target:feed('é👩‍💻')
    local inside, ran = false, false
    do local garbage = setmetatable({}, {__gc = function()
      if inside then ran = true end
      target:resize(method == 'row' and 2048 or 120, method == 'row' and 2 or 105)
    end}) end
    collectgarbage('incremental', 100, 1000, 0); collectgarbage('restart')
    inside = true
    local ok, result = pcall(function()
      if method == 'row' then return target:row(1) else return target:snapshot() end
    end)
    inside = false
    if ran then triggered = triggered + 1 end
    if ok then
      local cells = method == 'row' and result.cells or result.screen[1].cells
      assert(cells[1].text == 'é' and cells[2].text == '👩‍💻')
      assert(method == 'row' and (#cells == 4096 or #cells == 2048) or (#cells == 100 or #cells == 120))
      if method == 'snapshot' then assert(result.cols == #cells and #result.screen == result.rows) end
    else assert(tostring(result):find('terminal changed while creating snapshot', 1, true)) end
    collectgarbage('collect'); target:close()
  end
  assert(triggered > 0, 'resize finalizer ran inside ' .. method)
end
collectgarbage('incremental'); collectgarbage('restart')
print('resize validation, no-op, parser/policy/queues, damage and dimension limits passed')
