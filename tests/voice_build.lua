-- voice_build.lua -- the voice_build skill (lua/skills/voice_build.lua): it is a valid,
-- lint-clean, model-invocable skill; its `before` inventories a book's voice kit from
-- disk (POVs, voice card, exemplars by pov/mode, golden, baseline, voice notes) with no
-- network; its instructions carry that inventory and the author-only rules; and the
-- router finds it for a tone-of-voice request.
for _, t in ipairs{ "sty_books", "sty_files", "sty_fts", "sty_chapters", "sty_entities", "sty_mentions", "sty_payoffs" } do
  bog.db:run("DROP TABLE IF EXISTS " .. t)
end
local skills = require("skills")
local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function has(s, needle, n) ok(type(s) == "string" and s:find(needle, 1, true) ~= nil, n .. " -- got: " .. tostring(s)) end
local function put(path, text)
  sys.mkdir_p(path:match("^(.*)/[^/]+$"))
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

local s = skills.load("voice_build")
ok(s ~= nil, "voice_build loads")
ok(skills.validate(s) == nil, "voice_build is a valid skill")
local lint = skills.lint("voice_build")
ok(lint and lint.ok, "voice_build is lint-clean -- " .. table.concat(lint and lint.issues or {}, "; "))
ok(s.invocation == "model", "the model may reach for it")
local _, allow = skills.resolve({ "voice_build" })
ok(allow.story and allow.read and allow.write and allow.edit, "grants story and the file tools")

-- no book: before says so instead of failing
local nob = s.before({ book = "/nonexistent-voice-book" })
has(nob.set.voice_inventory, "No book here", "before: no book is reported, not raised")

-- a small book with a partial kit
local root = os.getenv("HOME") .. "/vb-book-" .. tostring(os.time())
put(root .. "/.boggart/story.json", '{ "title": "VB", "povs": ["mara"], "characters": ["mara.md", "tomas.md"],'
  .. ' "manuscript": { "glob": ["ch*.md"], "number": "ch(%d+)" } }')
put(root .. "/.boggart/style.lua", 'return { default_set = "third-past", voice = { "Plain words.", "Short lines." },'
  .. ' pov = { mara = { "Mara counts things." } } }')
put(root .. "/.boggart/style/exemplars/mara-quiet-1.md", "---\npov: mara\nmode: quiet\ngolden: true\n---\n"
  .. string.rep("She counted the cups twice and said nothing. ", 40) .. "\n")
put(root .. "/.boggart/style/exemplars/any-action-1.md", "---\nmode: action\n---\n"
  .. string.rep("He ran. The door gave. ", 60) .. "\n")
put(root .. "/voice/house-voice.md", "# House voice\n")
put(root .. "/voice/characters/mara.md", "# Mara\n")
put(root .. "/ch01.md", "# One\n\nMara counted the cups.\n")

local r = s.before({ book = root })
local inv = r.set.voice_inventory
has(inv, "POVs: mara", "before: POVs from the manifest")
has(inv, "Characters in the manifest: 2", "before: characters counted")
has(inv, "Voice card lines: 2; per-POV voices: 1", "before: voice card and per-POV lines")
has(inv, "Exemplars: 2 (1 golden)", "before: exemplars and golden counted")
has(inv, "mara/quiet=1", "before: the exemplar mix by pov/mode")
has(inv, "any/action=1", "before: exemplars with no pov count as 'any'")
has(inv, "Baseline: none", "before: no baseline yet")
has(inv, "voice/house-voice.md", "before: existing voice notes are listed")
has(inv, "voice/characters/mara.md", "before: character sheets are listed too")

local text = s.instructions({ voice_inventory = inv })
has(text, "Exemplars: 2 (1 golden)", "instructions carry the inventory")
has(text, "never from model drafts", "instructions: the voice comes from the author's prose")
has(text, "/story style exemplars add", "instructions: exemplars are proposed as author commands")
has(text, "never invent canon", "instructions: no invented canon or dialogue")
has(text, "action=baseline op=build", "instructions: the exact baseline call")

-- the router finds it for a tone-of-voice request
local router = require("skillrouter")
local hits = router.route("build the tone of voice and character dialogue sheets for this book", 5) or {}
local found = false
for i, h in ipairs(hits) do if h.name == "voice_build" and i <= 2 then found = true end end
ok(found, "find_skill ranks voice_build in the top two for a tone-of-voice request")

sys.rmtree(root)
io.write(string.format("voice_build: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
