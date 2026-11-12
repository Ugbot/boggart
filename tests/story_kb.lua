-- story_kb.lua -- the optional shared knowledge base client (lua/story/kb.lua,
-- docs/story-kb.md): off by default with no network call, manifest and env
-- configuration, the text search merge, record lookup, `about`, the mandatory
-- dataset.bundles on every SPARQL call, unreachable/slow daemons, bounded
-- output, the `kb` noun, the skill, and the drafting packet's optional tier.
-- Gestalt is a stubbed http.request throughout: nothing here touches a network.
for _, t in ipairs{ "sty_books", "sty_files", "sty_fts", "sty_chapters", "sty_entities", "sty_mentions", "sty_payoffs" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
local json = require("json")
local sb, sc, sv = require("story.book"), require("story.core"), require("story.view")
local kb = require("story.kb")
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function has(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) ~= nil, n .. " -- got: " .. tostring(s)) end
local function hasnt(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) == nil, n .. " -- got: " .. tostring(s)) end
local function iserr(s, n) ok(type(s) == "string" and s:find("^Error:") ~= nil, n .. " -- got: " .. tostring(s)) end

-- ---- the stubs: environment and http ----------------------------------------------------------
local real_getenv, real_request = os.getenv, http.request
local ENV = { BOGGART_KB_URL = false, BOGGART_KB_NAME = false, BOGGART_KB_API_KEY = false }
os.getenv = function(k)
  if ENV[k] ~= nil then return ENV[k] or nil end
  return real_getenv(k)
end

local calls, all_calls = {}, {}
local handler                      -- function(req, body) -> status, text | nil, msg
http.request = function(req)
  local body = req.body and json.decode(req.body) or nil
  local c = { url = req.url, method = req.method, timeout = req.timeout, headers = req.headers, body = body }
  calls[#calls + 1] = c; all_calls[#all_calls + 1] = c
  return handler(req, body)
end
local function reset() calls = {}; kb.reset() end

local BASE = "https://kb.gestalt2.invalid/story-demo/"
local LONG = string.rep("The red door hums when the tide turns. ", 400)
local function doc(layer, rel, typ, title, extra)
  local d = { iri = BASE .. rel, type = typ, title = title, kb = "story-demo", layer = layer,
              authority = kb.AUTHORITY[layer], text = title, body = title }
  for k, v in pairs(extra or {}) do d[k] = v end
  return d
end
local INDEX = {
  ["kbt-story-demo-notes"] = {
    { _score = 10, _source = doc("notes", "passages/notes/doors/001", "Passage", "Doors",
        { path = "notes/doors.md", heading = "The red door", line_start = 1, line_end = 9, role = "note",
          part_of = BASE .. "files/notes/doors", body = LONG }) },
    { _score = 4, _source = doc("notes", "passages/notes/keys/002", "Passage", "Keys",
        { path = "notes/keys.md", heading = "The brass key", line_start = 12, line_end = 30, role = "note",
          body = "The brass key opens the red door only for Vera." }) },
    { _score = 3, _source = doc("notes", "files/01-vera", "Note", "Vera",
        { path = "01-vera.md", role = "character", body = "Vera, the courier." }) },
    { _score = 2, _source = doc("notes", "files/notes/doors", "Note", "Doors",
        { path = "notes/doors.md", role = "note", body = "Vera once guarded the red door." }) },
  },
  ["kbt-story-demo-canon"] = {
    { _score = 8, _source = doc("canon", "canon/entities/red-door", "Entity", "Red Door", { body = "kind: place" }) },
    { _score = 1, _source = doc("canon", "canon/entities/vera", "Entity", "Vera", { body = "kind: character" }) },
  },
  ["kbt-story-demo-manuscript"] = {
    { _score = 15, _source = doc("manuscript", "passages/chapters/01/003", "Passage", "One",
        { path = "chapters/01.md", line_start = 40, line_end = 52, role = "chapter",
          body = "Vera put her hand on the red door." }) },
  },
}
local RECORDS = {
  ["story-demo-manuscript|" .. BASE .. "files/chapters/01"] =
    { iri = BASE .. "files/chapters/01", type = "Chapter", title = "One", revision = "rev-m-9",
      frontmatter = { type = "Chapter", path = "chapters/01.md", layer = "manuscript", authority = "prose",
                      mentions = (function() local t = {} for i = 1, 120 do t[i] = BASE .. "files/c" .. i end return t end)() },
      body = LONG },
  ["story-demo-canon|" .. BASE .. "canon/entities/red-door"] =
    { iri = BASE .. "canon/entities/red-door", type = "Entity", title = "Red Door", frontmatter = { kind = "place" }, body = "" },
  ["kb-registry|https://kb.gestalt2.invalid/registry/stores/story-demo"] =
    { iri = "https://kb.gestalt2.invalid/registry/stores/story-demo", type = "Store", title = "The Demo",
      frontmatter = { kb = "story-demo", kind = "story", title = "The Demo", series = "six", volume = 1,
                      bundles = { "story-demo-notes", "story-demo-manuscript" }, layer_names = { "notes", "manuscript" },
                      layers_json = '[{"layer":"notes","bundle":"story-demo-notes","text_index":"kbt-story-demo-notes","authority":"author-note"}]' },
      body = "" },
}
local function val(v) return { type = "literal", value = v } end
local MENTIONS = {
  { p = val(BASE .. "passages/chapters/01/003"), path = val("chapters/01.md"), ls = val("40"), le = val("52"),
    g = val("urn:gestalt:knowledge:story-demo-manuscript") },
  { p = val(BASE .. "passages/notes/doors/001"), path = val("notes/doors.md"), heading = val("The red door"),
    ls = val("1"), le = val("9"), g = val("urn:gestalt:knowledge:story-demo-notes") },
  { p = val(BASE .. "files/notes/doors"), path = val("notes/doors.md"), g = val("urn:gestalt:knowledge:story-demo-notes") },
  { p = val(BASE .. "passages/chapters/01/001"), path = val("chapters/01.md"), ls = val("3"), le = val("20"),
    g = val("urn:gestalt:knowledge:story-demo-manuscript") },
}
local sparql_mode = "ok"
local store_index = "ok"
local function gestalt(req, body)
  local path = req.url:match("^http://kb%.test:1(/.*)$") or req.url:match("^http://127%.0%.0%.1:17880(/.*)$")
  if not path then return 404, "{}" end
  local index = path:match("^/([^/]+)/_search$")
  if index then
    local rows = INDEX[index]
    if index == "kbt-story-demo" then
      -- the store-wide index: every layer's documents. "absent" answers the way gestaltd really
      -- answers a missing index (200, no hits); "404" the way an Elasticsearch would.
      if store_index == "404" then return 404, '{"error":"no such index"}' end
      rows = {}
      if store_index == "ok" then
        for _, l in ipairs{ "canon", "notes", "manuscript" } do
          for _, h in ipairs(INDEX["kbt-story-demo-" .. l]) do rows[#rows + 1] = h end
        end
      end
    end
    if not rows then return 404, '{"error":"no such index"}' end
    local want, any_layer = {}, nil
    local q = body.query
    for _, f in ipairs(q.bool and q.bool.filter or {}) do
      if f.terms then return 400, '{"error":{"type":"parsing_exception","reason":"unsupported query type"}}' end
      if f.term then for k, v in pairs(f.term) do want[k:gsub("%.keyword$", "")] = v end end
      if f.bool then
        any_layer = {}
        for _, t in ipairs(f.bool.should) do any_layer[t.term["layer.keyword"]] = true end
      end
    end
    local words = {}
    local qt = (q.match or q.bool.must[1].match).text.query:lower()
    for w in qt:gmatch("%a+") do if #w >= 3 then words[#words + 1] = w end end
    local out = {}
    for _, h in ipairs(rows) do
      local hay = (h._source.title .. " " .. h._source.body):lower()
      local keep = false
      for _, w in ipairs(words) do if hay:find(w, 1, true) then keep = true end end
      for k, v in pairs(want) do if h._source[k] ~= v then keep = false end end
      if any_layer and not any_layer[h._source.layer] then keep = false end
      if keep then out[#out + 1] = h end
    end
    return 200, json.encode({ hits = { hits = #out > 0 and out or json.array } })
  end
  if path == "/api/v1/catalog" and body.action == "knowledge.bundles" then
    return 200, json.encode({ ok = true, data = { count = 5, bundles = {
      { bundle = "story-demo-notes", newest_revision_id = "rev-n-7", revisions = 7 },
      { bundle = "story-demo-canon", newest_revision_id = "rev-c-2", revisions = 2 },
      { bundle = "story-demo-manuscript", newest_revision_id = "rev-m-9", revisions = 9 },
      { bundle = "kb-registry", newest_revision_id = "reg-1" },
      { bundle = "story-demos-notes", newest_revision_id = "other" },
      { bundle = "private-notes", newest_revision_id = "p-1" } } } })
  end
  if path == "/api/v1/catalog" and body.action == "knowledge.record" then
    local r = RECORDS[body.params.bundle .. "|" .. body.params.iri]
    if not r then return 200, json.encode({ ok = false, error = { code = "not_found", message = "no record" } }) end
    return 200, json.encode({ ok = true, data = r })
  end
  if path == "/api/v1/compute" and body.action == "sparql.query" then
    if sparql_mode == "no-optional" and body.params.query:find("OPTIONAL", 1, true) then return 400, '{"error":"unsupported"}' end
    return 200, json.encode({ ok = true, data = { head = { vars = { "p", "path" } }, results = { bindings = MENTIONS } } })
  end
  return 404, "{}"
end
handler = gestalt

-- ---- books ----------------------------------------------------------------------------------------
local function fresh_dir(tag)
  local base = real_getenv("HOME") .. "/skb-" .. tag .. "-" .. tostring(os.time())
  local d, i = base, 0
  while sys.stat(d) do i = i + 1; d = base .. "-" .. i end
  sys.mkdir_p(d .. "/.boggart")
  return d
end
local function write(path, text) local f = assert(io.open(path, "w")); f:write(text); f:close() end
local function make_book(tag, manifest)
  local d = fresh_dir(tag)
  write(d .. "/.boggart/story.json", manifest)
  sys.mkdir_p(d .. "/chapters"); sys.mkdir_p(d .. "/notes")
  write(d .. "/chapters/01.md", "# One\n\nVera walked to the harbour and counted the gulls.\n")
  write(d .. "/notes/doors.md", "# Doors\n\nThe red door hums at night and only Vera hears it.\n")
  return d
end
local OFF = make_book("off", '{"title":"No KB"}')
local ON = make_book("on", '{"title":"With KB","kb":{"name":"story-demo","url":"http://kb.test:1"}}')
local NAMED = make_book("named", '{"title":"Name only","kb":{"name":"story-demo"}}')
local NEVER = make_book("never", '{"title":"Opted out","kb":false}')
local off, on = sb.load(OFF), sb.load(ON)

-- ---- off by default: one reason, and no network call at all ---------------------------------------------
do
  reset()
  for name, fn in pairs{ status = function() return kb.status(off) end,
                         search = function() return kb.search(off, "red door") end,
                         record = function() return kb.record(off, "files/01-vera") end,
                         about = function() return kb.about(off, "Vera") end,
                         sparql = function() return kb.sparql(off, "SELECT ?s WHERE { ?s ?p ?o }") end } do
    local r, e = fn()
    ok(r == nil and e == "no shared KB configured", "off: " .. name .. " -> nil, no shared KB configured -- got " .. tostring(e))
  end
  ok(kb.draft_tier(off, "the red door") == nil, "off: no drafting tier")
  for _, act in ipairs{ "status", "search", "about", "record", "sparql" } do
    local out = sc.call{ noun = "kb", action = act, book = OFF, query = "x", name = "x", iri = "files/x" }
    has(out, "The shared KB is not configured for this book", "off: kb " .. act .. " says it is not configured")
    has(out, '"kb": {"name": "<store>"}', "off: kb " .. act .. " says how to configure it")
    ok(not out:find("\n"), "off: kb " .. act .. " answers one line")
  end
  local text, code = require("story.cli").run({ "kb", "status", "book=" .. OFF })
  has(text, "not configured", "off: the CLI says so")
  ok(code == 0, "off: not being configured is not an error exit")
  has(sv.command("kb status book=" .. OFF, 400), "not configured", "off: /story kb says so")
  ok(#calls == 0, "off: no network call was made -- got " .. #calls)
end

-- ---- configuration: manifest, then environment ------------------------------------------------------------
do
  local c = kb.config(on)
  ok(c and c.name == "story-demo" and c.url == "http://kb.test:1" and c.source == "manifest", "manifest names the store and url")
  c = kb.config(sb.load(NAMED))
  ok(c and c.url == "http://127.0.0.1:17880", "url is optional: the machine KB by default")
  ENV.BOGGART_KB_URL = "http://kb.test:1/"
  ok(kb.config(sb.load(NAMED)).url == "http://kb.test:1", "a manifest without url takes BOGGART_KB_URL")
  local c0, e0 = kb.config(off)
  ok(c0 == nil and e0 == kb.OFF, "BOGGART_KB_URL alone names no store: still off")
  ENV.BOGGART_KB_NAME = "story-env"
  c = kb.config(off)
  ok(c and c.name == "story-env" and c.url == "http://kb.test:1" and c.source == "env", "the environment configures a book with no kb key")
  ok(kb.config(on).name == "story-demo" and kb.config(on).source == "manifest", "the manifest wins over the environment")
  ok(kb.config(sb.load(NEVER)) == nil, '"kb": false switches it off whatever the environment says')
  ENV.BOGGART_KB_API_KEY = "sekrit"
  ok(kb.config(off).key == "sekrit", "an env key goes to an env-chosen address")
  ok(kb.config(on).key == nil, "an env key is never sent to an address the manifest chose")
  ENV.BOGGART_KB_NAME = "Bad Name/../x"
  local c1, e1 = kb.config(off)
  ok(c1 == nil and e1:find("not valid", 1, true), "an invalid store name is refused")
  ENV.BOGGART_KB_NAME = "story-env"; ENV.BOGGART_KB_URL = "file:///etc/passwd"
  local c2, e2 = kb.config(off)
  ok(c2 == nil and e2:find("http", 1, true), "only http(s) addresses")
  ENV.BOGGART_KB_URL, ENV.BOGGART_KB_NAME, ENV.BOGGART_KB_API_KEY = false, false, false
  ok(#calls == 0, "configuration never touches the network")
end

-- ---- status ---------------------------------------------------------------------------------------------
do
  reset()
  local s = kb.status(on)
  ok(s and s.kb == "story-demo" and #s.layers == 3, "status lists this store's layers only -- got " .. tostring(s and #s.layers))
  ok(s.layers[1].layer == "canon" and s.layers[1].revision_id == "rev-c-2" and s.layers[1].authority == "canon",
    "layers come highest authority first with their newest revision")
  ok(s.layers[2].layer == "notes" and s.layers[2].text_index == "kbt-story-demo-notes", "the text index name follows the contract")
  ok(s.registry and s.registry.series == "six", "the registry record is read when the registry bundle exists")
  ok(s.registry.layers and s.registry.layers[1].text_index == "kbt-story-demo-notes" and s.registry.layers_json == nil,
    "the registry's layers_json string is decoded")
  local out = sc.call{ noun = "kb", book = ON }
  has(out, "Shared KB story-demo at http://kb.test:1", "kb defaults to status")
  has(out, "story-demo-manuscript", "status names the bundles")
  has(out, "rev-n-7", "status shows revisions")
  hasnt(out, "story-demos", "another store with a longer name is not ours")
  has(out, "Registry: The Demo", "status shows the registry record")
  has(out, "registered layers: notes, manuscript", "status shows the registry's layer names")
end

-- ---- search: the text leg, merged across layers by weight ---------------------------------------------------
do
  reset()
  local r = kb.search(on, "red door")
  ok(r and r.count == 5, "search merges the layers -- got " .. tostring(r and r.count))
  ok(#r.legs == 1 and r.legs[1] == "text", "the result says it is the text leg only")
  -- authority nudges the score, it does not override it: a much better match in prose still comes first
  ok(r.results[1].layer == "manuscript" and math.abs(r.results[1].score - 13.5) < 1e-9, "manuscript 15 x 0.9 = 13.5 outranks ...")
  ok(r.results[2].layer == "notes" and r.results[2].score == 10, "... notes 10 x 1.0, which outranks ...")
  ok(r.results[3].layer == "canon" and math.abs(r.results[3].score - 9.2) < 1e-9, "... canon 8 x 1.15 = 9.2")
  ok(kb.WEIGHT.canon > kb.WEIGHT.notes and kb.WEIGHT.notes > kb.WEIGHT.inbox and kb.WEIGHT.inbox > kb.WEIGHT.manuscript,
    "weights: canon > notes > inbox > manuscript")
  local h = r.results[2]
  ok(h.iri == BASE .. "passages/notes/doors/001" and h.type == "Passage" and h.title == "Doors" and h.authority == "author-note"
    and h.path == "notes/doors.md" and h.heading == "The red door" and h.line_start == 1 and h.line_end == 9 and h.bm25 == 10,
    "a hit carries iri, type, title, layer, authority, path, heading, lines and score")
  ok(#h.snippet <= kb.LIMITS.snippet + 6 and #h.snippet > 50, "the snippet is bounded -- got " .. #h.snippet)
  ok(#calls == 1 and #r.skipped == 0 and r.index == "kbt-story-demo", "ONE request, to the store-wide index -- got " .. #calls)
  ok(calls[1].url == "http://kb.test:1/kbt-story-demo/_search" and calls[1].method == "POST", "the store-wide index is kbt-<store>")
  local cq = calls[1].body.query.bool
  ok(cq.must[1].match.text.query == "red door" and calls[1].body.size == 20, "the contract's match query, with room for the weights to reorder")
  ok(#cq.filter == 1 and #cq.filter[1].bool.should == 4 and cq.filter[1].bool.should[1].term["layer.keyword"] == "canon",
    "the chosen layers are a filter on layer.keyword (a should of terms: gestaltd has no terms query)")
  ok(calls[1].timeout == 3, "search waits 3 seconds at most")

  reset()
  r = kb.search(on, "red door", { layers = "notes,canon", k = 2 })
  ok(r.count == 2 and #calls == 1 and r.layers[1] == "canon" and r.layers[2] == "notes", "layers= and k= narrow the search")
  for _, h2 in ipairs(r.results) do ok(h2.layer == "notes" or h2.layer == "canon", "only the chosen layers come back") end
  r = kb.search(on, "red door", { layers = "manuscript" })
  ok(r.count == 1 and calls[#calls].body.query.bool.filter[1].term["layer.keyword"] == "manuscript", "one layer is a plain term filter")
  r = kb.search(on, "red door", { k = 5000 })
  ok(r.count <= kb.LIMITS.k_max and calls[#calls].body.size == kb.LIMITS.k_max, "k is capped")
  reset()
  local re_, ee = kb.search(on, "red door", { layers = "inbox" })
  ok(re_ and re_.count == 0 and ee == nil and #re_.skipped == 1 and re_.skipped[1].layer == "inbox",
    "a layer with no documents and no index (404) is an empty layer, not an error")
  local rb, eb = kb.search(on, "red door", { layers = "notes,otherstore" })
  ok(rb == nil and eb:find("unknown layer", 1, true), "an unknown layer is refused")
  reset()
  r = kb.search(on, string.rep("door ", 400))
  ok(#calls[1].body.query.bool.must[1].match.text.query <= kb.LIMITS.query, "the query is capped")
  reset()
  r = kb.search(on, "vera", { layers = "notes", type = "Note" })
  local f = calls[1].body.query.bool.filter
  ok(f[1].term["layer.keyword"] == "notes" and f[2].term["type.keyword"] == "Note" and r.count == 2,
    "an exact filter goes in bool.filter on <field>.keyword, after the layer")

  -- a store exported before kbt-<store> existed: the layers' own indexes answer
  for _, mode in ipairs{ "absent", "404" } do
    store_index = mode; reset()
    r = kb.search(on, "red door")
    ok(r and r.count == 5 and r.index == "per-layer", mode .. ": no store-wide index falls back to the per-layer indexes -- got " .. tostring(r and r.count))
    ok(#calls == 5 and calls[1].url == "http://kb.test:1/kbt-story-demo/_search"
      and calls[2].url == "http://kb.test:1/kbt-story-demo-canon/_search", mode .. ": the store-wide index first, then kbt-<store>-<layer> -- got " .. #calls)
    ok(calls[2].body.query.match.text.query == "red door" and calls[2].body.size == 10, mode .. ": the fallback body is the contract's plain match query")
    ok(r.results[1].layer == "manuscript" and r.results[2].layer == "notes" and r.results[3].layer == "canon", mode .. ": the same weights apply")
    local inbox_skipped = false
    for _, sk in ipairs(r.skipped) do if sk.layer == "inbox" then inbox_skipped = true end end
    ok(inbox_skipped and #r.layers == 3, mode .. ": a layer whose own index is missing is skipped, not fatal")
    for _, c in ipairs(calls) do ok(c.timeout == 3, mode .. ": every request waits 3 seconds at most") end
    r = kb.search(on, "vera", { layers = "notes", type = "Note" })
    ok(r.count == 2 and calls[#calls].body.query.bool.filter[1].term["type.keyword"] == "Note", mode .. ": filters carry over to the fallback")
  end
  store_index = "ok"

  local out = sc.call{ noun = "kb", action = "search", book = ON, query = "red door", layers = "notes,canon", k = "3" }
  has(out, "Text search only (no vectors)", "the tool says which leg answered")
  has(out, "notes/doors.md:1-9", "hits are cited path:line_start")
  has(out, "[canon, canon]", "hits name their layer and authority")
  ok(#out <= kb.LIMITS.out, "tool output is bounded")
  iserr(sc.call{ noun = "kb", action = "search", book = ON }, "search needs query=")
  has(sv.command('kb search query="red door" layers=notes book=' .. ON, 300), "notes/doors.md:1-9", "/story kb search works")
  local text, code = require("story.cli").run({ "kb", "search", "query=red door", "book=" .. ON })
  ok(code == 0 and text:find("hit(s) for 'red door'", 1, true), "boggart story kb search works")
end

-- ---- record: the layer from the IRI path, then by trying ------------------------------------------------------
do
  reset()
  local r = kb.record(on, "files/chapters/01")
  ok(r and r.layer == "manuscript" and r.type == "Chapter" and r.revision == "rev-m-9", "files/ is looked up in notes, then manuscript")
  ok(#calls == 2 and calls[1].body.params.bundle == "story-demo-notes" and calls[2].body.params.bundle == "story-demo-manuscript",
    "files/: notes first, then manuscript")
  ok(calls[1].body.action == "knowledge.record" and calls[1].body.params.iri == BASE .. "files/chapters/01", "a path under the base becomes the full IRI")
  ok(#r.body <= kb.LIMITS.body and r.truncated == true, "the body is capped and says so")
  ok(#r.frontmatter.mentions == kb.LIMITS.list + 1, "long frontmatter lists are capped")
  reset()
  r = kb.record(on, BASE .. "canon/entities/red-door")
  ok(r and r.layer == "canon" and #calls == 1 and calls[1].body.params.bundle == "story-demo-canon", "canon/ goes straight to the canon bundle")
  reset()
  r = kb.record(on, "files/chapters/01", { layer = "manuscript" })
  ok(r and #calls == 1, "a known layer skips the lookup")
  reset()
  local r2, e2 = kb.record(on, "passages/nope/001")
  ok(r2 == nil and e2:find("no record", 1, true) and #calls == 3, "a missing record: every candidate layer tried, then a reason")
  reset()
  local r3, e3 = kb.record(on, "https://kb.gestalt2.invalid/otherstore/files/x")
  ok(r3 == nil and e3:find("not in store", 1, true) and #calls == 0, "an IRI of another store is refused without a call")
  local out = sc.call{ noun = "kb", action = "record", book = ON, iri = "files/chapters/01" }
  has(out, "[manuscript, prose]  Chapter", "kb record shows layer, authority and type")
  has(out, "[body trimmed]", "kb record says the body was trimmed")
  ok(#out <= kb.LIMITS.out, "kb record output is bounded")
  iserr(sc.call{ noun = "kb", action = "record", book = ON }, "record needs iri=")
  iserr(sc.call{ noun = "kb", action = "record", book = ON, iri = "passages/nope/001" }, "a missing record is an Error line")
end

-- ---- about: resolve the name, then the graph, grouped by file ----------------------------------------------------
do
  reset()
  local r = kb.about(on, "Vera")
  ok(r and #r.targets == 2, "the name resolves to a note file and a canon entity -- got " .. tostring(r and #r.targets))
  ok(r.targets[1].iri == BASE .. "files/01-vera" and r.targets[2].iri == BASE .. "canon/entities/vera",
    "the character sheet (title match) wins over a file that merely mentions the name")
  local f1, f2 = calls[1].body.query.bool.filter, calls[2].body.query.bool.filter
  ok(f1[1].term["layer.keyword"] == "notes" and f1[2].term["type.keyword"] == "Note"
    and f2[1].term["layer.keyword"] == "canon" and f2[2].term["type.keyword"] == "Entity", "resolution searches file and entity records only")
  ok(#r.files == 2 and r.files[1].path == "chapters/01.md" and r.files[2].path == "notes/doors.md", "mentions are grouped by file")
  ok(r.files[1].count == 2 and r.files[1].passages[1].line_start == 3 and r.files[1].passages[2].line_start == 40,
    "passages are in reading order")
  ok(r.files[2].whole_file == true and r.files[2].count == 1 and r.files[2].passages[1].heading == "The red door",
    "a file record's own mention is not counted as a passage")
  ok(r.files[1].layer == "manuscript" and r.count == 4, "the layer comes from the graph name")
  local q
  for _, c in ipairs(calls) do if c.body and c.body.action == "sparql.query" then q = c.body.params end end
  ok(q.query:find("<http://schema.org/mentions> <" .. BASE .. "files/01-vera>", 1, true)
    or q.query:find("<http://schema.org/mentions> <" .. BASE .. "canon/entities/vera>", 1, true), "the query follows schema:mentions")
  ok(#q.dataset.bundles == 3, "about reads only this store's existing layer bundles")

  reset(); sparql_mode = "no-optional"
  r = kb.about(on, "notes/doors.md")
  ok(r and #r.targets == 1 and r.targets[1].iri == BASE .. "files/notes/doors", "a path resolves to its files/ IRI with no search")
  ok(r.count == 4, "an engine without OPTIONAL falls back to the contract's plain query")
  sparql_mode = "ok"
  ok(kb.path_iri("notes/My File (v2).md") == "notes/My%20File%20%28v2%29", "path segments are percent-encoded")

  local out = sc.call{ noun = "kb", action = "about", book = ON, name = "Vera" }
  has(out, "4 record(s) in 2 file(s) mention it", "kb about summarises")
  has(out, "chapters/01.md:40-52", "kb about cites path:line_start")
  iserr(sc.call{ noun = "kb", action = "about", book = ON }, "about needs name=")
  iserr(sc.call{ noun = "kb", action = "about", book = ON, name = "zzzz nobody" }, "an unknown name is an Error line")
end

-- ---- sparql: the escape hatch, same dataset restriction -----------------------------------------------------------
do
  reset()
  local r = kb.sparql(on, "PREFIX s: <http://schema.org/>\nSELECT ?p ?path WHERE { GRAPH ?g { ?p s:mentions ?x } }")
  ok(r and r.count == 4 and r.rows[1].path == "chapters/01.md", "sparql returns bounded rows")
  ok(#r.bundles == 3 and r.bundles[1] == "story-demo-canon", "it reads this store's layer bundles")
  r = kb.sparql(on, "SELECT ?p WHERE { ?p ?q ?o }", { layers = "notes", limit = 2 })
  ok(#r.bundles == 1 and r.bundles[1] == "story-demo-notes" and r.count == 2 and r.truncated == true, "layers= narrows the dataset; rows are capped")
  local n = #calls
  for _, q in ipairs{ "DELETE WHERE { ?s ?p ?o }", "INSERT DATA { <a:b> <a:c> <a:d> }", "PREFIX x: <http://x/> DROP GRAPH <urn:x>",
                      "CLEAR ALL", "LOAD <http://x/y>" } do
    local w, we = kb.sparql(on, q)
    ok(w == nil and we:find("read", 1, true), "an update is refused: " .. q)
  end
  ok(#calls == n, "a refused update never reaches the network")
  local w2, we2 = kb.sparql(on, "SELECT ?s WHERE { ?s ?p ?o }", { layers = "inbox" })
  ok(w2 == nil and we2:find("no exported layers", 1, true), "no bundle to name: no query is sent")
  has(sc.call{ noun = "kb", action = "sparql", book = ON, query = "ASK { ?s ?p ?o }" }, "bundles story-demo-canon", "kb sparql names its bundles")
  iserr(sc.call{ noun = "kb", action = "sparql", book = ON, query = "DROP ALL" }, "kb sparql refuses updates")
end

-- ---- unreachable, slow, broken: nil + reason, never a raise ---------------------------------------------------------
do
  for name, h in pairs{
    refused = function() return nil, "Couldn't connect to server" end,
    timeout = function() return nil, "Timeout was reached" end,
    raises = function() error("boom") end,
  } do
    handler = h; reset()
    local okc, r, e = pcall(kb.search, on, "red door")
    ok(okc and r == nil and type(e) == "string" and e:find("unreachable", 1, true), name .. ": search -> nil, reason -- got " .. tostring(e))
    ok(#calls == 1, name .. ": search gives up at the first dead request, not once per layer -- got " .. #calls)
    for what, fn in pairs{ status = function() return kb.status(on) end, record = function() return kb.record(on, "files/x") end,
                           about = function() return kb.about(on, "Vera") end,
                           sparql = function() return kb.sparql(on, "SELECT ?s WHERE { ?s ?p ?o }") end } do
      local ok2, r2, e2 = pcall(fn)
      ok(ok2 and r2 == nil and type(e2) == "string" and e2 ~= "", name .. ": " .. what .. " -> nil, reason -- got " .. tostring(e2))
    end
    iserr(sc.call{ noun = "kb", action = "search", book = ON, query = "red door" }, name .. ": the tool answers an Error line")
  end
  for name, h in pairs{
    http500 = function() return 500, "oops" end,
    garbage = function() return 200, "<html>not json</html>" end,
    empty = function() return 200, "" end,
    wrong = function() return 200, '{"hits":"nope","ok":true,"data":7}' end,
  } do
    handler = h; reset()
    for what, fn in pairs{ status = function() return kb.status(on) end, search = function() return kb.search(on, "red door") end,
                           record = function() return kb.record(on, "files/x") end, about = function() return kb.about(on, "Vera") end,
                           sparql = function() return kb.sparql(on, "SELECT ?s WHERE { ?s ?p ?o }") end } do
      local ok2, r2, e2 = pcall(fn)
      local fine = ok2 and ((r2 == nil and type(e2) == "string") or (what == "search" and type(r2) == "table" and r2.count == 0)
        or (what == "status" and type(r2) == "table" and #r2.layers == 0))
      ok(fine, name .. ": " .. what .. " does not raise and does not invent results -- got " .. tostring(r2) .. ", " .. tostring(e2))
    end
  end
  handler = gestalt
end

-- ---- the hard rule: no SPARQL call ever leaves without dataset.bundles ------------------------------------------------
do
  local n = 0
  for _, c in ipairs(all_calls) do
    if c.body and c.body.action == "sparql.query" then
      n = n + 1
      local ds = c.body.params and c.body.params.dataset
      local good = type(ds) == "table" and type(ds.bundles) == "table" and #ds.bundles > 0
      for _, b in ipairs(good and ds.bundles or {}) do if b:sub(1, 11) ~= "story-demo-" then good = false end end
      ok(good, "sparql call " .. n .. " names only this store's bundles in dataset.bundles")
    end
    ok(c.method == "POST" and (c.url:find("/_search$") or c.url:find("/api/v1/catalog$") or c.url:find("/api/v1/compute$")),
      "only the contract's read endpoints are called -- got " .. tostring(c.url))
    local a = c.body and c.body.action
    ok(a == nil or a == "knowledge.bundles" or a == "knowledge.record" or a == "sparql.query", "only read actions are sent -- got " .. tostring(a))
  end
  ok(n >= 8, "the SPARQL rule was exercised -- " .. n .. " calls")
end

-- ---- the drafting packet: unchanged when off, one extra labelled tier when on ------------------------------------------
do
  local sd = require("story.draft")
  local function plan(dir)
    local out = sc.call{ noun = "plan", action = "set", book = dir, n = 2, title = "Two", unit = "line",
      beats = "- Vera reaches the red door at night.\n- The brass key turns." }
    has(out, "Saved .boggart/plans/ch02.md", "a plan for the packet")
  end
  local function packet(dir) return sc.call{ noun = "draft", action = "next", book = dir, n = 2 } end
  plan(OFF)
  reset()
  local P0 = packet(OFF)
  has(P0, "notes/doors.md:3: The red door hums at night", "the local retrieval is in the packet")
  hasnt(P0, "shared knowledge base", "no shared tier without a shared KB")
  ok(#calls == 0, "off: building a packet makes no network call")

  -- the same book through the environment: configured but unreachable -> byte-identical
  ENV.BOGGART_KB_NAME, ENV.BOGGART_KB_URL = "story-demo", "http://kb.test:1"
  handler = function() return nil, "Couldn't connect to server" end
  reset()
  ok(packet(OFF) == P0, "an unreachable KB leaves the packet byte-identical")
  ok(#calls == 1 and calls[1].timeout == kb.TIMEOUT.draft, "one short attempt -- got " .. #calls)
  ok(packet(OFF) == P0 and #calls == 1, "and it is not asked again for a while (a draft run is many packets)")
  handler = function() return 500, "oops" end
  reset()
  ok(packet(OFF) == P0, "a failing KB leaves the packet byte-identical")
  handler = function() error("boom") end
  reset()
  ok(packet(OFF) == P0, "a raising transport leaves the packet byte-identical")
  handler = function() return 200, json.encode({ hits = { hits = json.array } }) end
  reset()
  ok(packet(OFF) == P0, "a KB with nothing to add leaves the packet byte-identical")

  -- a KB that answers: its own labelled section, minus what the local retrieval already picked
  handler = gestalt
  reset()
  local P1 = packet(OFF)
  has(P1, "## " .. kb.DRAFT_TITLE, "the shared tier is its own labelled section")
  has(P1, "notes/keys.md:12: [author-note] The brass key -- The brass key opens the red door only for Vera.", "a shared hit is cited path:line")
  local tier = P1:match("## From the shared knowledge base[^\n]*\n(.-)\n\n## ") or ""
  hasnt(tier, "notes/doors.md", "a hit the local retrieval already picked (same file, overlapping lines) is dropped")
  ok(select(2, tier:gsub("[^\n]+", "")) <= kb.LIMITS.draft_hits, "at most a few hits")
  has(P1, kb.DRAFT_TITLE .. " ", "the packet report counts the tier")
  ok(#calls == 1 and calls[1].url:find("/kbt%-story%-demo/_search$") and calls[1].timeout == kb.TIMEOUT.draft, "the tier is one short request -- got " .. #calls)
  local df = calls[1].body.query.bool.filter
  ok(#df[1].bool.should == 2 and df[1].bool.should[1].term["layer.keyword"] == "notes"
    and df[1].bool.should[2].term["layer.keyword"] == "inbox", "the tier searches the notes and inbox layers")
  ok(df[2].term["type.keyword"] == "Passage", "passages only")
  store_index = "absent"; reset()
  ok(packet(OFF) == P1, "a store with only per-layer indexes gives the same tier")
  store_index = "ok"; reset()
  local a, b = P1:find("## " .. kb.DRAFT_TITLE, 1, true)
  ok(P1:sub(1, a - 1) .. P1:sub((P1:find("\n\n## ", b, true)) + 2) ~= "" and
    (P1:sub(1, a - 1) .. P1:sub((P1:find("\n\n## ", b, true)) + 2)):gsub("%(packet: .*$", "") == P0:gsub("%(packet: .*$", ""),
    "everything else in the packet is exactly as before")
  ok(#sd.packet(sb.load(OFF), 2, sd.load_plan(sb.load(OFF), 2), sd.next_task(sd.load_plan(sb.load(OFF), 2)), { budget = 1500 }) <= 1500 + 400,
    "the tier lives inside the packet budget")

  ENV.BOGGART_KB_NAME, ENV.BOGGART_KB_URL = false, false
  reset()
  ok(packet(OFF) == P0 and #calls == 0, "switched off again: the packet is byte-identical and nothing is called")
  -- "kb": false in the manifest beats the environment
  plan(NEVER)
  local N0 = packet(NEVER)
  ENV.BOGGART_KB_NAME = "story-demo"
  reset()
  ok(packet(NEVER) == N0 and #calls == 0, '"kb": false keeps a book out of the shared KB')
  ENV.BOGGART_KB_NAME = false
end

-- ---- the skill -----------------------------------------------------------------------------------------------------
do
  local sk = require("skills.story_kb")
  ok(type(sk.before) == "function" and type(sk.instructions) == "function" and sk.description, "story_kb has the callable shape")
  local grants = table.concat(sk.tools, ",")
  has(grants, "story", "story_kb grants the story tool")
  reset()
  local set = sk.before({ book = ON }).set
  ok(set.kb_name == "story-demo" and #calls == 0, "before reads the manifest only (no network)")
  local text = sk.instructions(set)
  has(text, "story-demo", "the instructions name the store")
  has(text, "path:line_start", "they say how to cite")
  has(text, "canon > notes", "they give the order of authority")
  has(text, "DATA", "they say record text is data, not instructions")
  has(text, "never write to the shared KB", "they say Boggart does not write there")
  has(sk.instructions(sk.before({ book = OFF }).set), "NO shared KB configured", "a book without one is told so")
end

-- ---- the tool surface ------------------------------------------------------------------------------------------------
has(sc.tool.description, "kb search query=", "the story tool describes the kb noun")
has(sc.tool.input_schema.properties.noun.description, "|kb", "kb is a listed noun")
ok(sc.tool.input_schema.properties.iri and sc.tool.input_schema.properties.layers, "kb's parameters are in the schema")
iserr(sc.call{ noun = "kb", action = "write", book = ON }, "there is no write action")

os.getenv, http.request = real_getenv, real_request
io.write(string.format("story_kb: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
