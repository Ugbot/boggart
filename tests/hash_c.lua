-- hash_c.lua -- SHA-256 in C (src/lhash.c, BOG-14) against the pure-Lua
-- workflow.hash: known vectors, every length across the padding boundaries,
-- random data, and the speed target (1 MiB in under 5 ms).
local wf = require("workflow")
local c = require("hash_c")
local passed, failed = 0, 0
local function ok(cnd, n) if cnd then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
ok(wf.hash ~= wf.lua_hash, "workflow.hash uses the C version")
local vectors = {
  [""] = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  ["abc"] = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  ["abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"] = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
}
for s, want in pairs(vectors) do
  ok(c.sha256(s) == want and c.sha256_portable(s) == want and wf.lua_hash(s) == want, "vector " .. #s .. " bytes")
end
local same = true
for n = 0, 200 do                      -- every padding case: <56, =56..63, 64, two blocks...
  local s = string.rep("x", n)
  if c.sha256(s) ~= wf.lua_hash(s) or c.sha256_portable(s) ~= wf.lua_hash(s) then same = false; io.write("  len ", n, "\n"); break end
end
ok(same, "identical to the Lua digest for every length 0..200")
math.randomseed(7)
local rs = {}
for i = 1, 70000 do rs[i] = string.char(math.random(0, 255)) end
local r = table.concat(rs)
ok(c.sha256(r) == wf.lua_hash(r) and c.sha256_portable(r) == wf.lua_hash(r), "identical on 70 KB of random bytes")
local mb = string.rep("0123456789abcdef", 65536)   -- 1 MiB
local t0 = os.clock(); for _ = 1, 10 do c.sha256(mb) end; local tc = (os.clock() - t0) / 10
local t1 = os.clock(); wf.lua_hash(mb); local tl = os.clock() - t1
io.write(string.format("  1 MiB: C %.2f ms, Lua %.0f ms (x%.0f)\n", tc * 1000, tl * 1000, tl / tc))
ok(tc < 0.005, "1 MiB in under 5 ms")
ok(not pcall(wf.hash, 42), "non-strings still refused")
io.write(string.format("hash_c: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
