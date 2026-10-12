-- json_c.lua -- the C JSON codec (src/ljson.c, BOG-12) against the pure-Lua
-- one (lua/json.lua) as oracle: identical encode output byte for byte,
-- identical decoded values (math.type included), identical errors; the C
-- UTF-8 repair against util.lua's; and the speed-up on a transcript-sized value.
local json = require("json")
local util = require("util")
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
ok(json.c ~= nil, "the C codec is wired in")
local C, Lenc, Ldec = json.c, json.lua_encode, json.lua_decode

local function deq(a, b)
  if a == json.null or b == json.null then return a == b end
  if type(a) ~= type(b) then return false end
  if type(a) == "number" then return math.type(a) == math.type(b) and (a == b or (a ~= a and b ~= b)) end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- ---- encode: a corpus of edge cases -------------------------------------------------------
local corpus = {
  0, -1, 42, math.maxinteger, math.mininteger, 1.5, -0.25, 1e300, 1e-300, 0.1, 2^53, 3.0, -0.0,
  "", "plain", "quote \" backslash \\ slash /", "\b\f\n\r\t", "\0\1\31\127", "naïve ✓ 🙂", "\255\254 raw bytes",
  true, false, json.null, json.array, {}, { 1, 2, 3 }, { 1, nil, 3 }, { a = 1, b = { c = { d = "deep" } } },
  { [1] = "a", [2] = "b", x = "mixed" }, { [2] = "sparse" }, { [1.5] = "float key", [10] = "ten", z = 1 },
  { ["key \"q\""] = "esc", ["\0k"] = "nul in key", ["Ü"] = "utf8 key" }, { true, false, json.null, {} },
  { msgs = { { role = "user", content = { { type = "text", text = "hi\n" } } } } },
}
for i, v in ipairs(corpus) do
  local a, b = Lenc(v), C.encode(v)
  ok(a == b, "encode #" .. i .. " identical -- lua " .. a .. " | c " .. b)
end
-- deep nesting and errors
local deep = {}
local t = deep
for _ = 1, 200 do t.n = {}; t = t.n end
ok(Lenc(deep) == C.encode(deep), "200-deep nesting identical")
local cyc = {}; cyc.self = cyc
ok(not pcall(C.encode, cyc), "a cycle is an error, not a hang")
ok(not pcall(C.encode, { f = print }), "a function value is an error")
ok(select(2, pcall(C.encode, 0/0)):find("non-finite", 1, true), "NaN is an error")
ok(select(2, pcall(C.encode, math.huge)):find("non-finite", 1, true), "inf is an error")

-- ---- decode: identical values and errors ------------------------------------------------------
local docs = {
  '{"a":1,"b":[1,2.5,"x",true,false,null],"c":{"d":"e"}}', '[]', '{}', '  [ 1 , 2 ]  ', '"\\u00e9\\u2713"',
  '"\\ud83d\\ude42"', '"\\ud83d lone high"', '"\\ude42 lone low"', '"a\\/b\\b\\f\\n\\r\\t"', '-0', '1.0', '1e3', '1E-2',
  '123456789012345678901234567890', '1.', '0.5e+10', '"raw\tcontrol"', '{"dup":1,"dup":2}', 'null', 'true',
  '[[[[["deep"]]]]]', '{"k\\u0000z":1}', '"\xff\xfe raw"',
}
for i, d in ipairs(docs) do
  local oka, va = pcall(Ldec, d)
  local okb, vb = pcall(C.decode, d)
  ok(oka == okb and (not oka or deq(va, vb)), "decode #" .. i .. " identical: " .. d)
end
local bad = { '', '{', '[1,', '{"a"}', '{"a":}', '[1 2]', 'tru', 'nul', '"unterminated', '"bad \\x escape"',
  '"\\u12"', '01x', '{"a":1}x', '-', '+1', '.5', '[1,]', '{"a":1,}' }
for i, d in ipairs(bad) do
  local oka, ea = pcall(Ldec, d)
  local okb, eb = pcall(C.decode, d)
  local ma = not oka and tostring(ea):match("json decode error at %d+: .*$")
  local mb = not okb and tostring(eb):match("json decode error at %d+: .*$")
  ok(oka == okb and ma == mb, "error #" .. i .. " identical for " .. string.format("%q", d) .. ": " .. tostring(ma) .. " | " .. tostring(mb))
end

-- ---- randomized round trip + mutation ------------------------------------------------------------
math.randomseed(1234)
local function rstr()
  local n = math.random(0, 12)
  local t = {}
  for i = 1, n do
    local r = math.random()
    t[i] = r < 0.7 and string.char(math.random(32, 126)) or r < 0.85 and string.char(math.random(0, 31))
      or ({ "é", "✓", "🙂", "\"", "\\" })[math.random(5)]
  end
  return table.concat(t)
end
local function rval(depth)
  local r = math.random()
  if depth > 3 or r < 0.25 then return math.random(-1000, 1000)
  elseif r < 0.35 then return math.random() * 1e6
  elseif r < 0.55 then return rstr()
  elseif r < 0.6 then return json.null
  elseif r < 0.65 then return math.random() < 0.5
  elseif r < 0.82 then
    local a = {}
    for i = 1, math.random(0, 5) do a[i] = rval(depth + 1) end
    return a
  else
    local o = {}
    for _ = 1, math.random(0, 5) do o[rstr()] = rval(depth + 1) end
    return o
  end
end
local same_enc, same_dec, same_mut = true, true, true
for i = 1, 400 do
  local v = rval(0)
  local a, b = Lenc(v), C.encode(v)
  if a ~= b then same_enc = false; io.write("  enc diverged: ", a, " | ", b, "\n"); break end
  if not deq(Ldec(a), C.decode(a)) then same_dec = false; break end
  -- mutate one byte: both must agree on success/failure and value
  local p = math.random(1, math.max(1, #a))
  local m = a:sub(1, p - 1) .. string.char(math.random(0, 127)) .. a:sub(p + 1)
  local oka, va = pcall(Ldec, m)
  local okb, vb = pcall(C.decode, m)
  if oka ~= okb or (oka and not deq(va, vb)) then same_mut = false; io.write("  mutation diverged: ", m, "\n"); break end
end
ok(same_enc, "400 random values encode identically")
ok(same_dec, "and decode identically")
ok(same_mut, "and 400 one-byte mutations fail or succeed identically")

-- ---- UTF-8 -------------------------------------------------------------------------------------
local same_u = true
for i = 1, 2000 do
  local t = {}
  for k = 1, math.random(0, 16) do t[k] = string.char(math.random(0, 255)) end
  local s = table.concat(t)
  if util.lua_to_valid_utf8(s) ~= C.to_valid_utf8(s) then same_u = false; break end
end
ok(same_u, "to_valid_utf8: C and Lua agree on 2000 random byte strings")
local v = "already valid ✓"
ok(C.to_valid_utf8(v) == v, "valid input comes back unchanged")
ok(C.utf8_safe_len("abc") == 3, "safe_len: ASCII")
ok(C.utf8_safe_len("ab\226\156") == 2, "safe_len: a cut 3-byte char is held back")
ok(C.utf8_safe_len("ab\226\156\147") == 5, "safe_len: a complete char is not")
ok(C.utf8_safe_len("ab\240\159\153") == 2, "safe_len: a cut 4-byte char is held back")
ok(C.utf8_safe_len("ab\255") == 3, "safe_len: an invalid byte is not held back (it is not a prefix)")

-- the stream carry: a character split across deltas reaches the display whole
local api = require("api")
local got = {}
local feed, flush = api._utf8_carry(function(t) got[#got + 1] = t end)
local whole = "naïve ✓ 🙂 end"
for i = 1, #whole do feed(whole:sub(i, i)) end    -- one byte per delta
flush()
local all_valid = true
for _, g in ipairs(got) do if C.to_valid_utf8(g) ~= g then all_valid = false end end
ok(all_valid, "no delta handed to the display ends mid-character")
ok(table.concat(got) == whole, "and nothing is lost or reordered")

-- ---- speed on a transcript-sized value -----------------------------------------------------------
local msgs = {}
for i = 1, 400 do
  msgs[i] = { role = i % 2 == 0 and "assistant" or "user", content = { { type = "text",
    text = string.rep("The quick brown fox jumps over the lazy dog. ", 130) .. i },
    { type = "tool_use", id = "tu_" .. i, name = "read", input = { path = "/x/" .. i, start_line = i } } } }
end
local doc = { model = "m", messages = msgs, max_tokens = 4096 }
local function time(f, n) local t0 = os.clock(); for _ = 1, n do f() end; return (os.clock() - t0) / n end
local s_c = C.encode(doc)
ok(s_c == Lenc(doc), "transcript encodes identically (" .. #s_c .. " bytes)")
local te_l, te_c = time(function() Lenc(doc) end, 2), time(function() C.encode(doc) end, 5)
local td_l, td_c = time(function() Ldec(s_c) end, 2), time(function() C.decode(s_c) end, 5)
io.write(string.format("  %.1f MB: encode lua %.1f ms / C %.1f ms (x%.0f); decode lua %.1f ms / C %.1f ms (x%.0f)\n",
  #s_c / 1048576, te_l * 1000, te_c * 1000, te_l / te_c, td_l * 1000, td_c * 1000, td_l / td_c))
ok((te_l + td_l) / (te_c + td_c) >= 10, "encode+decode at least 10x faster")

io.write(string.format("json_c: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
