-- auth_file.lua -- the credential file shared by several boggart processes
-- (src/lauth.c). The bug: each process read the file once, then rewrote it
-- whole from that stale copy on any change, so a /model switch in a TUI left
-- open for days erased a key added in the studio since. Another process is
-- simulated by editing the file directly, the way it would.
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local path = auth.path and auth.path() or (bog.userdir .. "/auth")
auth.clear()
ok(auth.set("api_key", "sk-deepseek-test-key-0123456789abcdef", "deepseek"), "store a key")
local function file() local f = io.open(path, "rb"); local s = f and f:read("a") or ""; if f then f:close() end; return s end
ok(file():find("key.deepseek=sk-deepseek-test-key", 1, true) ~= nil, "it is in the file")
-- "another process" adds a key after this one last read the file
local f = assert(io.open(path, "ab")); f:write("key.anthropic=sk-ant-test-key-abcdefghijklmnopqrstuvwxyz\n"); f:close()
-- this process changes something unrelated (a /model switch)
ok(auth.set("model", "some-model"), "an unrelated change")
local s = file()
ok(s:find("key.anthropic=sk-ant-test-key", 1, true) ~= nil, "the other process's key survives an unrelated write")
ok(s:find("key.deepseek=sk-deepseek-test-key", 1, true) ~= nil, "and so does ours")
ok(s:find("model=some-model", 1, true) ~= nil, "and the change is made")
-- readers see a key another process added, without a restart
f = assert(io.open(path, "ab")); f:write("key.openai=sk-openai-test-key-abcdefghijklmnop\n"); f:close()
local m = auth.masked("openai")
ok(m ~= "(unset)", "a key added elsewhere is seen at once -- got " .. tostring(m))
-- the file stays owner-only, and no temp file is left behind
local kind, _, _, mode = sys.stat(path)
ok(mode == tonumber("600", 8), "the file is 0600 -- got " .. string.format("%o", mode or 0))
local leftovers = sys.glob(path .. ".tmp.*") or {}
ok(#leftovers == 0, "no temp file left behind")
-- clear removes only what it names
auth.clear("model")
s = file()
ok(s:find("key.anthropic", 1, true) and s:find("key.openai", 1, true) and not s:find("model=", 1, true), "clear touches only its field")
auth.clear()
io.write(string.format("auth_file: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
