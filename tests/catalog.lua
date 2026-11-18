-- catalog.lua -- the model catalog: DB tables, JSON exchange, credential slots.
--
-- The store is the truth (three tables in lua/store.lua, reached through the C
-- operations in src/lrepo.c); JSON is how a catalog arrives, leaves and gets
-- shared. These tests pin that split, and one property that matters more than
-- the rest: a credential is refused when the host it would go to is not
-- registered for its slot.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_catalog"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local C = require "catalog"

-- ---- the seed -------------------------------------------------------------
ok(boggart.embedded("models.json") ~= nil,
   "the seed catalog is baked into the binary as data, not a module")
-- store.open() seeds an empty catalog, so by the time a test runs the rows are
-- already there. That is the behaviour worth asserting: a fresh install knows
-- about providers without anyone importing anything.
C.seed_if_empty()
ok(#C.providers() > 10, "a fresh store knows providers (" .. #C.providers() .. ")")
ok(#C.models{} > 10, "and models (" .. #C.models{} .. ")")
eq(C.seed_if_empty(), false, "seeding again is a no-op -- a curated catalog is never overwritten")

-- ---- rows come back as Lua values, not SQLite ones ------------------------
-- SQLite has no boolean, so a capability arrives as 0 or 1 -- and BOTH are
-- truthy in Lua. Every row must leave the module with real booleans or
-- `if model.effort then` is silently always true.
local opus = C.model("claude-opus-5")
eq(type(opus.effort), "boolean", "a capability flag is a boolean, not 0/1")
eq(opus.effort, true, "and true is true")
local grok = C.model("grok-4.6")
eq(grok.effort, nil, "an unset flag is absent rather than false-y-but-truthy")
eq(type(grok.context), "number", "a context window is a number")

-- ---- destinations ---------------------------------------------------------
local d = C.destination("grok-4.6")
eq(d.url, "https://api.x.ai/v1", "Grok resolves to xAI")
eq(d.wire, "openai", "on the OpenAI wire")
eq(d.auth, "bearer", "with a Bearer token")
eq(d.key_slot, "xai", "and an explicit slot -- not the 'x' a hostname would give")

-- The combination that was unrepresentable before the catalog: the Anthropic
-- wire authenticated with a Bearer token.
local glm = C.destination("glm-5.3")
eq(glm.wire, "anthropic", "GLM speaks the Anthropic wire")
eq(glm.auth, "bearer", "and authenticates with Bearer -- auth is independent of wire")

local orr = C.destination("openrouter/anthropic/claude-opus-5")
eq(orr.url, "https://openrouter.ai/api/v1", "an OpenRouter model keeps its slashes")
ok(type(orr.headers) == "table" and orr.headers["X-Title"] ~= nil,
   "and carries the provider's extra headers")

eq(C.destination("no-such-model"), nil, "an uncatalogued model has no destination")

-- ---- capability queries ---------------------------------------------------
local vision = C.models{ vision = true }
ok(#vision > 0, "vision models can be queried (" .. #vision .. ")")
for _, m in ipairs(vision) do
  if m.vision ~= true then ok(false, "a vision query returned " .. m.id) end
end
passed = passed + 1
local big = C.models{ min_context = 1000000 }
ok(#big > 0, "long-context models can be queried (" .. #big .. ")")
for _, m in ipairs(big) do
  if (m.context or 0) < 1000000 then ok(false, m.id .. " is below the asked-for context") end
end
passed = passed + 1
local xai = C.models{ provider = "xai" }
eq(#xai, 3, "models can be filtered by provider")

-- ---- import is an upsert, not a replacement -------------------------------
-- The property that makes a small hand-written file safe to hand to `import`.
local before = #C.models{}
C.import({ models = { ["grok-4.6"] = { provider = "xai", context = 12345 } } }, "user")
eq(#C.models{}, before, "importing one model does not erase the others")
eq(C.model("grok-4.6").context, 12345, "it updates the row it names")
eq(C.model("grok-4.6").source, "user", "and records where the row came from")
eq(C.model("glm-5.3").source, "seed", "leaving another row's provenance alone")

C.import({ models = { ["brand-new"] = { provider = "xai", context = 1 } } }, "import")
eq(#C.models{}, before + 1, "a new model is added")
eq(C.model("brand-new").source, "import", "with its own provenance")

-- ---- export / import round trip -------------------------------------------
local text = C.export_json()
ok(#text > 100, "export produces JSON")
local decoded = bog.json.decode(text)
ok(decoded.providers and decoded.models, "in the same shape as the seed")
ok(decoded.models["grok-4.6"] ~= nil, "containing what is in the store")
local count_before = #C.models{}
local n2 = C.import_json(text, "user")
ok(n2 ~= nil, "the export can be imported back")
eq(#C.models{}, count_before, "a round trip changes nothing")

eq(C.import_json("not json at all"), nil, "invalid JSON is refused, not thrown")

-- ---- roles ----------------------------------------------------------------
eq(C.role("default")[1], "claude-opus-5-5", "the seed binds a default role")
eq(C.role("nothing-bound"), nil, "an unbound role is nil")
C.bind_role("critic", { "grok-4.6", "glm-5.3" })
local chain = C.role("critic")
eq(#chain, 2, "a role can be bound to a fallback chain")
eq(chain[1], "grok-4.6", "in order")
C.bind_role("utility", "glm-5.3-flash")
eq(#C.role("utility"), 1, "a single model is still a one-entry chain")
eq(C.role("utility")[1], "glm-5.3-flash", "with the right model")
ok(C.bind_role("bad", {}) == nil, "an empty binding is refused")

-- ---- the credential-slot registry (the security property) -----------------
-- A key must not be sent to a host that is not registered for its slot. This
-- is the one assertion in the file worth reading twice.
ok(auth.slot_allowed("https://api.x.ai/v1", "xai"),
   "a slot registered for a host is allowed")
ok(not auth.slot_allowed("https://evil.example.com/v1", "xai"),
   "THE ATTACK: the xai key is refused for a host it is not registered for")
ok(not auth.slot_allowed("https://evil.example.com", "anthropic"),
   "and so is the anthropic key")
ok(not auth.slot_allowed("https://api.x.ai/v1", "anthropic"),
   "right host, wrong slot is still refused")
ok(auth.slot_allowed("https://api.z.ai/api/anthropic", "zai"),
   "Z.ai's own slot reaches Z.ai")
ok(auth.slot_allowed("https://anything.test", "a-slot-nothing-registers"),
   "a slot the catalog has no opinion on is the caller's own arrangement")

-- ---- keys can be stored for a provider you are not pointed at -------------
ok(auth.set("api_key", "test-key-xai", "xai"), "a key can be stored per provider")
ok(auth.has_key("xai"), "and is found under that provider")

-- ---- merging the baked catalog into an older store ---------------------------
-- A store seeded by an older build never heard of models that shipped later;
-- merge_seed adds them without touching anything someone chose.
do
  bog.db:run("DELETE FROM models WHERE id = ?", { "claude-sonnet-5-5" })
  ok(C.model("claude-sonnet-5-5") == nil, "merge: a shipped model is missing from an old store")
  C.import({ models = { ["claude-fable-5-2"] = { provider = "anthropic", label = "Mine" } } }, "user")
  C.import({ models = { ["claude-haiku-5-5"] = { provider = "anthropic", label = "Stale seed" } } }, "seed")
  C.bind_role("default", "claude-opus-5")          -- what the previous seed chose
  C.bind_role("critic", "grok-4.6")                 -- someone's own role
  local n = C.merge_seed()
  ok(n and n.models > 0, "merge: imports from the baked catalog")
  ok(C.model("claude-sonnet-5-5") ~= nil, "merge: the missing model is added")
  eq(C.model("claude-fable-5-2").label, "Mine", "merge: a user's row is left alone")
  eq(C.model("claude-haiku-5-5").label, "Claude Haiku 5.5", "merge: a row still from the seed is updated")
  eq(C.role("default")[1], "claude-opus-5-5", "merge: a role on the PREVIOUS seed default moves to the new one")
  eq(C.role("critic")[1], "grok-4.6", "merge: a role someone bound is theirs")
  C.bind_role("default", "grok-4.6")
  C.merge_seed()
  eq(C.role("default")[1], "grok-4.6", "merge: a default someone rebound is never moved back")
  C.bind_role("default", "claude-opus-5-5")
  local again = C.merge_seed()
  ok(again ~= nil, "merge: idempotent")
end

-- ---- Anthropic's own model list --------------------------------------------------
do
  local anth = C.provider("anthropic")
  eq(anth and anth.catalog_url, "https://api.anthropic.com/v1/models", "anthropic publishes its catalog")
  local body = '{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5",'
    .. '"max_input_tokens":1000000,"max_tokens":128000}]}'
  local rows = C.parse_openai_models(body, "anthropic")
  local m = rows and rows["claude-opus-5-5"]
  ok(m and m.label == "Claude Opus 5.5", "anthropic list: display_name is the label")
  ok(m and m.context == 1000000 and m.max_output == 128000, "anthropic list: max_input_tokens / max_tokens")
  local real = http.request
  local seen
  http.request = function(req) seen = req; return 200, body end
  local r = C.refresh("anthropic")
  http.request = real
  ok(r and r.models == 1, "refresh anthropic imports its list")
  local hv = false
  for _, h in ipairs((seen and seen.headers) or {}) do hv = hv or h == "anthropic-version: 2023-06-01" end
  ok(hv, "refresh sends anthropic-version on the Messages wire")
  eq(C.model("claude-opus-5-5").source, "refresh", "refreshed rows say where they came from")
  local s = C.sync_summary({ seed = { models = 7 }, refreshed = { anthropic = { models = 9 }, xai = "xai answered 401" } })
  eq(s, "built-in: 7 models; anthropic: 9 models; xai: xai answered 401", "sync summary, one line")
end

io.write(string.format("catalog: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
