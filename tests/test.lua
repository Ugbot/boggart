-- test.lua -- pure-Lua unit tests, run via `./boggart --eval tests/test.lua`.
-- No network. Exercises json, serialize/overlay, the edit single-match rule,
-- bounded read, result-shaping, and define_tool round-trip.
local json = require("json")
local util = require("util")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- point memory/tools/store at a throwaway userdir so we don't touch the real one
bog.userdir = os.tmpname() .. "_boggart_test"
sys.mkdir_p(bog.userdir .. "/lua/tools")
-- reopen the store against the throwaway dir (boot already opened the real one)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

-- ---- json ----
do
  local v = { a = 1, b = { 2, 3, 4 }, c = "hi\n\"x\"", d = true, e = json.null }
  local s = json.encode(v)
  local r = json.decode(s)
  eq(r.a, 1, "json int")
  eq(r.b[2], 3, "json array elem")
  eq(r.c, 'hi\n"x"', "json string escapes")
  eq(r.d, true, "json bool")
  eq(r.e, json.null, "json null")
  -- decode of an SSE-style event
  local ev = json.decode('{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}')
  eq(ev.delta.text, "Hi", "json nested decode")
  eq(json.encode({}), "{}", "empty table -> {}")
  eq(json.encode({ 1, 2 }), "[1,2]", "array encode")
end

-- ---- UTF-8 sanitizer + turn-assembly robustness ----
-- Regression: a tool_result that is not valid UTF-8 (e.g. `cat` on a binary)
-- passed raw through json.encode into the request body and made the Messages
-- API reject the whole turn with HTTP 400 "invalid unicode code point". Content
-- is now scrubbed to valid UTF-8 (U+FFFD for ill-formed bytes) at ingest.
do
  local REPL = "\239\191\189" -- U+FFFD
  local emoji = "\240\159\152\128"        -- U+1F600, valid 4-byte
  local cjko  = "\228\184\173\230\150\135" -- "中文", valid 3-byte x2

  -- valid multibyte survives byte-for-byte
  eq(util.to_valid_utf8(emoji), emoji, "emoji preserved unchanged")
  eq(util.to_valid_utf8(cjko), cjko, "CJK preserved unchanged")
  eq(util.to_valid_utf8("plain ascii"), "plain ascii", "ascii preserved unchanged")

  -- lone bad bytes -> replacement chars; utf8.len confirms well-formedness
  local bad1 = util.to_valid_utf8("\255\254")
  eq(bad1, REPL .. REPL, "0xff 0xfe -> two U+FFFD")
  ok(utf8.len(bad1) ~= nil, "scrubbed 0xff/0xfe is valid utf8")

  -- lone surrogate encoded as bytes (ED A0 80 = U+D800) is rejected
  local sur = util.to_valid_utf8("a\237\160\128b")
  ok(utf8.len(sur) ~= nil and sur:sub(1,1) == "a" and sur:sub(-1) == "b",
     "lone surrogate bytes scrubbed, surrounding ascii kept")
  ok(not sur:find("\237"), "no raw surrogate lead byte remains")

  -- truncated 3-byte sequence at end-of-string
  local trunc = util.to_valid_utf8("ok\228\184")
  eq(trunc, "ok" .. REPL .. REPL, "truncated 3-byte -> replacement")

  -- mixed: valid emoji + CJK survive, invalid bytes between them are scrubbed
  local mixed = util.to_valid_utf8(emoji .. "\255" .. cjko)
  eq(mixed, emoji .. REPL .. cjko, "valid multibyte survives around a bad byte")
  ok(utf8.len(mixed) ~= nil, "mixed result is valid utf8")

  -- idempotent
  eq(util.to_valid_utf8(mixed), mixed, "sanitizer is idempotent")

  -- the actual failure mode: a scrubbed tool_result JSON-encodes to a body that
  -- is valid UTF-8 (the API's requirement), whereas the raw bytes would not.
  local raw_result = "canon_search char_sheet: \255\254 name" .. emoji
  ok(utf8.len(raw_result) == nil, "raw bad tool output is NOT valid utf8")
  local scrubbed = util.to_valid_utf8(raw_result)
  local body = json.encode({ role = "user", content = {
    { type = "tool_result", tool_use_id = "x", content = scrubbed } } })
  ok(utf8.len(body) ~= nil, "encoded request body is valid utf8")
  ok(json.decode(body).content[1].content:find(REPL), "bad bytes became U+FFFD in body")
  ok(json.decode(body).content[1].content:find(emoji), "emoji survived into body")

  -- end-to-end through the tool registry: a session tool that emits raw bytes
  -- comes back scrubbed, so no tool can inject invalid UTF-8 into a turn.
  bog.tools.run("define_tool", {
    name = "emit_bad_bytes", description = "returns non-utf8 bytes", scope = "session",
    lua = "return 'pre \\255\\254 post'",
  })
  local tout = bog.tools.run("emit_bad_bytes", {})
  ok(utf8.len(tout) ~= nil, "tool output centrally scrubbed to valid utf8")
  ok(not tout:find("\255"), "no raw 0xff in tool output")
  ok(tout:find("pre ") and tout:find(" post"), "tool output text preserved")
end

-- ---- serialize round-trips through Lua load ----
do
  local schema = { type = "object", properties = { x = { type = "string" } }, required = { "x" } }
  local lit = util.serialize(schema)
  local back = load("return " .. lit)()
  eq(back.type, "object", "serialize type")
  eq(back.properties.x.type, "string", "serialize nested")
  eq(back.required[1], "x", "serialize array")
end

-- ---- read (bounded) + write + edit single-match ----
do
  local p = bog.userdir .. "/sample.txt"
  util.write_file(p, "l1\nl2\nl3\nl4\nl5\n")
  local r = bog.tools.run("read", { path = p, start_line = 2, max_lines = 2 })
  ok(r:find("continue_offset=4"), "read reports continue_offset")
  ok(r:find("2\tl2") and r:find("3\tl3") and not r:find("4\tl4"), "read bounded slice")

  local e1 = bog.tools.run("edit", { path = p, old = "l3", new = "L3" })
  ok(e1:find("Post%-edit context"), "edit returns post-edit context")
  eq(util.read_file(p), "l1\nl2\nL3\nl4\nl5\n", "edit applied")

  util.write_file(p, "dup\ndup\n")
  local e2 = bog.tools.run("edit", { path = p, old = "dup", new = "x" })
  ok(e2:sub(1, 11) == "Tool error:", "edit rejects non-unique old")

  local e3 = bog.tools.run("edit", { path = p, old = "nope", new = "x" })
  ok(e3:sub(1, 11) == "Tool error:", "edit rejects missing old")
end

-- ---- result shaping ----
do
  local small = "short output"
  eq(util.shape_result(small), small, "small output inline")
  local big = string.rep("x\n", 5000)
  local shaped = util.shape_result(big, { max_bytes = 500, head_lines = 10 })
  ok(#shaped < #big, "big output truncated")
  ok(shaped:find("output truncated"), "shaped mentions truncation")
  ok(shaped:find("read the read tool") or shaped:find("read tool"), "shaped points at read tool")
end

-- ---- define_tool round-trip + reload picks it up ----
do
  local res = bog.tools.run("define_tool", {
    name = "shout",
    description = "uppercase the text arg",
    input_schema = { type = "object", properties = { text = { type = "string" } }, required = { "text" } },
    lua = "return (args.text or ''):upper()",
  })
  ok(res:find("Defined tool 'shout'"), "define_tool succeeds")
  eq(bog.tools.run("shout", { text = "hi" }), "HI", "defined tool runs live")

  -- the file was persisted and a reload re-registers it
  -- define_tool now defaults to scope=project, so the file lands under the
  -- project bucket rather than the old global directory.
  ok(sys.stat(bog.tools.tools_dir("project") .. "/shout.lua") == "file",
     "tool persisted to disk (project scope)")
  local names = {}
  for _, n in ipairs(bog.tools.names()) do names[n] = true end
  ok(names.shout, "shout in registry")

  bog.reload()
  eq(bog.tools.run("shout", { text = "ok" }), "OK", "defined tool survives reload")

  -- a bad body is rejected without corrupting state
  local bad = bog.tools.run("define_tool", { name = "b", description = "x", lua = "this is ! not lua" })
  ok(bad:sub(1, 11) == "Tool error:", "define_tool rejects bad body")
end

-- ---- schemas() shape sent to the API ----
do
  local schemas = bog.tools.schemas()
  ok(#schemas > 0, "schemas non-empty")
  local byname = {}
  for _, s in ipairs(schemas) do byname[s.name] = s end
  ok(byname.read and byname.read.input_schema.type == "object", "read schema present")
  ok(byname.define_tool and byname.reload, "meta-tools present")
end

-- ---- store: kv ----
do
  bog.store.kv_set("greeting", "hi")
  eq(bog.store.kv_get("greeting"), "hi", "kv set/get")
  bog.store.kv_set("greeting", "yo")
  eq(bog.store.kv_get("greeting"), "yo", "kv upsert")
  bog.store.kv_del("greeting")
  eq(bog.store.kv_get("greeting"), nil, "kv del")
end

-- ---- store: memory + FTS recall ----
do
  bog.memory.remember("apples", "I like green apples and tart fruit")
  bog.memory.remember("cars", "the user prefers electric vehicles")
  local items = bog.memory.list()
  eq(#items, 2, "memory list count")
  local hit = bog.memory.recall("apples")
  ok(hit:find("green apples"), "FTS recall finds apples note")
  ok(not hit:find("electric"), "FTS recall excludes non-match")
  ok(bog.memory.recall(""):find("electric"), "empty query returns all")
  ok(bog.memory.index_text():find("apples"), "index_text lists titles")
  ok(bog.memory.forget("apples"), "forget removes")
  eq(#bog.memory.list(), 1, "memory count after forget")
end

-- ---- store: sessions round-trip ----
do
  local id = bog.store.sess_create("test session", "claude-opus-5")
  ok(type(id) == "number", "sess_create returns id")
  local msgs = { { role = "user", content = "hi" }, { role = "assistant", content = { { type = "text", text = "yo" } } } }
  bog.store.sess_save(id, "test session", "claude-opus-5", msgs)
  local s = bog.store.sess_load(id)
  eq(s.title, "test session", "session title round-trip")
  eq(s.messages[1].content, "hi", "session messages round-trip (string)")
  eq(s.messages[2].content[1].text, "yo", "session messages round-trip (blocks)")
  local list = bog.store.sess_list(10)
  ok(#list >= 1, "sess_list non-empty")
end

-- ---- gold stdlib ----
do
  local g = gold
  eq(#g.str.split("a b  c"), 3, "str.split whitespace")
  eq(g.str.split("a,b,c", ",")[2], "b", "str.split sep")
  eq(g.str.trim("  x  "), "x", "str.trim")
  ok(g.str.starts("hello", "he") and g.str.ends("hello", "lo"), "str.starts/ends")
  eq(#g.str.lines("a\nb\nc"), 3, "str.lines")
  eq(g.tbl.map({ 1, 2, 3 }, function(x) return x * 2 end)[3], 6, "tbl.map")
  eq(#g.tbl.filter({ 1, 2, 3, 4 }, function(x) return x % 2 == 0 end), 2, "tbl.filter")
  eq(g.tbl.reduce({ 1, 2, 3 }, function(a, b) return a + b end, 0), 6, "tbl.reduce")
  eq(g.fs.join("a", "b", "c"), "a/b/c", "fs.join")
  eq(g.fs.join("a/", "/b"), "a/b", "fs.join dedup slashes")
  eq(g.fs.basename("/x/y/z.lua"), "z.lua", "fs.basename")
  eq(g.fs.dirname("/x/y/z.lua"), "/x/y", "fs.dirname")
  eq(g.fs.ext("z.lua"), "lua", "fs.ext")
  ok(type(g.pp.pretty({ a = 1, b = { 2 } })) == "string", "pp.pretty")
  ok(g.sh.ok("true") and not g.sh.ok("false"), "sh.ok exit codes")
  eq(g.sh.out("printf hey"), "hey", "sh.out trims")
  eq(#g.args.tokenize('a "b c" d'), 3, "args.tokenize quotes")
  local p = g.args.parse({ "--name", "bob", "-v", "file.txt" })
  ok(p.flags.name == "bob" and p.flags.v == true and p.positional[1] == "file.txt", "args.parse")
  local t = g.test.new()
  t.eq(1, 1, "x"); t.ok(false, "y")
  local pn, fn = t.summary()
  ok(pn == 1 and fn == 1, "gold.test harness")
end

-- ---- sql + kv tools ----
do
  ok(bog.tools.run("sql", { sql = "CREATE TABLE widgets(id INTEGER PRIMARY KEY, name TEXT)", write = true })
    :find("ok:"), "sql tool create")
  ok(bog.tools.run("sql", { sql = "INSERT INTO widgets(name) VALUES(?)", params = { "gizmo" }, write = true })
    :find("rowid=1"), "sql tool insert")
  local q = bog.tools.run("sql", { sql = "SELECT name FROM widgets" })
  ok(q:find("gizmo"), "sql tool query returns rows")
  eq(bog.tools.run("kv", { op = "set", key = "k", value = "v" }), "ok", "kv tool set")
  eq(bog.tools.run("kv", { op = "get", key = "k" }), "v", "kv tool get")
end

-- cleanup. sys.rmtree rather than a shell command: cmd.exe has no such thing,
-- so on Windows the old spelling failed silently and left the tree behind.
if bog.db then bog.db:close() end
sys.rmtree(bog.userdir)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
