-- http_body.lua -- http.request's response buffer (src/lhttp.c, BOG-7): a
-- multi-MiB body streamed in small chunks, with an on_chunk callback that
-- churns the Lua stack and the GC between appends -- the conditions under
-- which a luaL_Buffer-backed body could write through a misplaced box. The
-- body must come back byte-exact. Skipped without python3 (the test server).
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local p = io.popen("command -v python3")
local py = p and p:read("l")
if p then p:close() end
if not py or py == "" then io.write("http_body: skipped (no python3)\n"); return end

local srv = io.popen("python3 tests/fixtures/http/chunked_server.py 2>/dev/null", "r")
local port = tonumber(srv:read("l"))
ok(port ~= nil, "test server started")

local chunks, junk = 0, {}
local status, body = http.request{
  url = "http://127.0.0.1:" .. port .. "/big", method = "GET", timeout = 30,
  on_chunk = function(c)
    chunks = chunks + 1
    -- stress: deep stack use, allocation, a GC step -- all between appends
    local t = {}
    for i = 1, 64 do t[i] = string.rep(c:sub(1, 8), 4) end
    junk[#junk + 1] = table.concat(t)
    if #junk > 32 then junk = {} end
    collectgarbage("step", 1)
    return select("#", table.unpack(t))
  end,
}
srv:close()
ok(status == 200, "200 -- got " .. tostring(status))
ok(type(body) == "string" and #body == 48 * 1024 * 65, "the whole 3 MiB body -- got " .. tostring(body and #body))
local intact = true
local i = 0
for line in body:gmatch("([^\n]*)\n") do
  if line:sub(1, 8) ~= string.format("%07d:", i) then intact = false; break end
  i = i + 1
end
ok(intact and i == 48 * 1024, "every line intact and in order")
ok(chunks > 10, "it arrived in many chunks (" .. chunks .. ")")

-- an on_chunk that raises aborts the transfer as an error, without a leak or crash
local srv2 = io.popen("python3 tests/fixtures/http/chunked_server.py 2>/dev/null", "r")
local port2 = tonumber(srv2:read("l"))
local okc, err = pcall(http.request, { url = "http://127.0.0.1:" .. port2 .. "/big", timeout = 30,
  on_chunk = function() error("stop") end })
srv2:close()
ok(not okc and tostring(err):find("on_chunk callback error", 1, true), "a raising callback is a clean error")

io.write(string.format("http_body: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
