local terminal = require "terminal"
local json = require "json"
local passed = 0
local function check(value, name) assert(value, name); passed = passed + 1 end
local t <close> = terminal.new(8, 2, 2)
t:feed("é👩‍💻🇬🇧日")
local row = t:row(1)
check(row.cells[1].codepoint == 101 and row.cells[1].text == "é", "base codepoint and full combining text")
check(row.cells[2].text == "👩‍💻" and row.cells[2].width == 2 and row.cells[3].text == "" and row.cells[3].width == 0, "emoji pair text")
check(row.cells[4].text == "🇬🇧" and row.cells[6].text == "日" and t:state().col == 8, "cluster widths advance cursor")
check(t:state().modes & terminal.GRAPHEME ~= 0, "Unicode mode defaults on")
t:feed("\27[?2027$p\27[?2027l\27[?2027$p")
check(t:replies() == "\27[?2027;1$y\27[?2027;2$y", "mode query reports enabled and disabled")
t:feed("\27[?2027:1$p\27[?2027;1$p\27[2027$p\27[?9999$p")
check(t:replies() == "", "unsupported and malformed queries are ignored")
t:reset();t:feed("e" .. ("́"):rep(10000))
check(t:row(1).cells[1].text == "e" .. ("́"):rep(64) and t:state().col == 2, "snapshot preserves the bounded cluster")
t:reset();t:feed("\27]8;id=unicode;https://example.com\aé👩‍💻\27]8;;\a\r\nnext\r\n")
local snapshot = t:snapshot(true)
check(snapshot.scrollback[1].cells[1].text == "é" and snapshot.scrollback[1].cells[2].text == "👩‍💻", "history retains cluster text")
check(json.decode(json.encode(snapshot)).scrollback[1].cells[2].link.id == "unicode", "cluster links survive JSON copying")
t:reset()
check(snapshot.scrollback[1].cells[2].text == "👩‍💻" and row.cells[1].text == "é", "copies outlive reset and pool recycling")
local stream = "abcde❤️\r\n👩‍💻🇬🇧é\27[1G\27[2@日\27[2P\27]8;id=x;uri\aक्क\27]8;;\a\xe2"
local full <close> = terminal.new(6, 3, 4);full:feed(stream);full:finish()
local expected = json.encode(full:snapshot(true))
for cut = 0, #stream do
  local part <close> = terminal.new(6, 3, 4)
  part:feed(stream:sub(1, cut));part:feed(stream:sub(cut + 1));part:finish()
  check(json.encode(part:snapshot(true)) == expected, "snapshot byte split " .. cut)
end

-- Force finalizers to run while snapshots allocate. Before copying the core
-- into rooted userdata this deterministically exposed an ASan use-after-free.
local finalized = 0
for _, method in ipairs { "row", "snapshot" } do
  for _, action in ipairs { "close", "mutate" } do
    local triggered = 0
    for attempt = 1, 10 do
      collectgarbage("collect");collectgarbage("stop")
      local target = terminal.new(method == "row" and 4096 or 100, method == "row" and 1 or 100, 0);target:feed("é👩‍💻")
      local ran = false
      do local garbage = setmetatable({}, { __gc = function()
        ran = true;finalized = finalized + 1
        if action == "close" then target:close() else target:reset();target:feed("new") end
      end }) end
      collectgarbage("incremental", 100, 1000, 0);collectgarbage("restart")
      local ok, result = pcall(function()
        if method == "row" then return target:row(1) else return target:snapshot() end
      end)
      if ran then triggered = triggered + 1 end
      if ok then
        local cells = method == "row" and result.cells or result.screen[1].cells
        check(cells[1].text == "é" or cells[1].text == "n", "copied image survives finalizer")
        if cells[1].text == "é" then check(cells[2].text == "👩‍💻", "finalizer cannot mix old and new cells") end
      else check(tostring(result):find("closed terminal", 1, true) ~= nil, "closed during image allocation fails safely") end
      target:close()
    end
    check(triggered > 0, "finalizer ran inside " .. method .. " for " .. action)
  end
end
collectgarbage("incremental");collectgarbage("restart")
check(finalized == 40, "all finalizers exercised")
io.write(string.format("terminal Unicode: %d passed\n", passed))
