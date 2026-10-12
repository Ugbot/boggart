-- store_save.lua -- saving a session encodes once and decodes never (BOG-13):
-- the search index is built from the messages the caller already holds, and
-- search results are what they were.
local json = require("json")
local store = bog.store
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local enc, dec = 0, 0
local real_enc, real_dec = json.encode, json.decode
json.encode = function(...) enc = enc + 1; return real_enc(...) end
json.decode = function(...) dec = dec + 1; return real_dec(...) end

local id = store.sess_create("Kettle notes", "m")
local msgs = {
  { role = "user", content = { { type = "text", text = "the eleven-minute kettle in the archive" } } },
  { role = "assistant", content = { { type = "text", text = "Viktor counted the stamped cards." } } },
}
enc, dec = 0, 0
store.sess_save(id, "Kettle notes", "m", msgs)
ok(enc == 1, "one encode per save -- got " .. enc)
ok(dec == 0, "and no decode -- got " .. dec)
local function hits(q)
  local r = store.sess_search(q, 10) or {}
  for _, row in ipairs(r) do if row.id == id then return true end end
  return false
end
ok(hits("kettle"), "the title/body is searchable")
ok(hits("stamped cards"), "message text is searchable")

-- the index body is the same whether built from the table or read back
local fts1 = bog.db:query("SELECT body FROM sessions_fts WHERE rowid=?", { id })[1].body
store._fts_index_session(id)   -- the read-back path
local fts2 = bog.db:query("SELECT body FROM sessions_fts WHERE rowid=?", { id })[1].body
ok(fts1 == fts2, "index text identical either way")

-- thread updates: status alone does not touch the index or decode anything
local tid = store.thread_create and store.thread_create({ title = "worker thread", model = "m" })
if tid then
  dec = 0
  store.thread_save(tid, { status = "done" })
  ok(dec == 0, "a status update decodes nothing -- got " .. dec)
  store.thread_save(tid, { messages = { { role = "user", content = "zeppelin sightings" } } })
  ok(dec == 0, "a messages update decodes nothing")
  local found = false
  for _, row in ipairs(store.sess_search("zeppelin", 10) or {}) do if row.id == tid then found = true end end
  ok(found, "thread messages are searchable")
end

json.encode, json.decode = real_enc, real_dec
io.write(string.format("store_save: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
