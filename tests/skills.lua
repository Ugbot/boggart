-- skills.lua -- skill bundles (lua/skills.lua): listing, validation, loud
-- resolution, and the import path that COMPILES a markdown SKILL.md into a Lua
-- skill file. The compile step is the one that matters: an imported skill must
-- end up an ordinary boggart skill, loadable by require and editable like the
-- baked-in ones, not a second inert format.
local skills = require("skills")
local tools = require("tools")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- Isolate: point the overlay at a throwaway userdir so we never write into the
-- developer's own skills.
local saved_userdir = bog.userdir
bog.userdir = os.tmpname() .. "_skills"
sys.mkdir_p(bog.userdir .. "/lua/skills")
package.path = bog.userdir .. "/lua/?.lua;" .. package.path

local MD = [[
---
name: code-review
description: Review a diff for correctness
allowed-tools: read, git_diff, bash
---
# How to review

Read the diff, then comment on real defects only.
]]

-- ---- name normalisation (the ecosystem uses hyphens) -----------------------
ok(skills.normalize_name("pdf-processing") == "pdf_processing", "hyphens -> underscores")
ok(skills.normalize_name("9lives") == nil, "leading digit rejected")

-- ---- markdown parsing ------------------------------------------------------
local skill, name = skills.parse_markdown(MD)
ok(skill and name == "code_review", "frontmatter name parsed and normalised")
ok(skill.description == "Review a diff for correctness", "description parsed")
ok(#skill.tools == 3 and skill.tools[2] == "git_diff", "allowed-tools parsed")
ok(skill.instructions:find("real defects"), "body becomes instructions")
ok(skills.parse_markdown("   ") == nil, "empty document rejected")

-- ---- validation ------------------------------------------------------------
ok(skills.validate({ description = "d", instructions = "i", tools = { "a" } }) == nil, "valid passes")
ok(skills.validate({ tools = "nope" }):find("list of tool names"), "tools must be a list")
ok(skills.validate({ instructions = 5 }):find("string or a function"), "instructions type checked")

-- ---- the compile step ------------------------------------------------------
local src = skills.to_lua("code_review", skill, "SKILL.md")
ok(load(src) ~= nil, "generated Lua compiles")
ok(load(src)().description == skill.description, "generated Lua round-trips")
local tricky = skills.to_lua("t", { description = "d", instructions = "has ]] inside", tools = {} })
ok(load(tricky) and load(tricky)().instructions == "has ]] inside",
   "instructions containing ]] still compile and round-trip")

-- ---- import produces a real, requireable skill -----------------------------
local iname, path = skills.import(MD, nil, "SKILL.md")
ok(iname == "code_review" and path:find("code_review%.lua$"), "import writes a Lua skill file")
local loaded = skills.load("code_review")
ok(loaded and loaded.description == "Review a diff for correctness", "imported skill loads")

local instr, allow, unknown = skills.resolve({ "code_review" })
ok(instr:find("## Skill: code_review"), "resolve emits instructions")
ok(allow.git_diff and allow.read, "resolve grants the skill's tools")
ok(#unknown == 0, "no unknowns for a real skill")

-- ---- the gap that mattered: unknown skills are reported, not dropped -------
local _, _, unk = skills.resolve({ "code_review", "gti_worktree" })
ok(#unk == 1 and unk[1] == "gti_worktree", "a misspelled skill is reported")

-- ---- listing ---------------------------------------------------------------
local byname = {}
for _, r in ipairs(skills.list()) do byname[r.name] = r.source end
ok(byname.core == "builtin", "list includes baked-in skills")
ok(byname.code_review == "overlay", "list includes imported overlay skills")

-- ---- wiring + the tools through the real registry --------------------------
ok(tools.registry.skills ~= nil, "skills tool registered")
ok(tools.registry.define_skill ~= nil, "define_skill registered")
ok(tools.registry.import_skill ~= nil, "import_skill registered")

ok(tools.run("import_skill", { text = MD, name = "renamed" }):find("compiled to Lua"),
   "import_skill tool compiles to Lua")
ok(skills.load("renamed") ~= nil, "renamed import is loadable")
ok(tools.run("define_skill", { name = "hand-made", instructions = "do the thing",
     description = "d", tools = { "read" } }):find("Defined skill 'hand_made'"),
   "define_skill authors and normalises the name")
ok(skills.load("hand_made").tools[1] == "read", "defined skill persisted with its tools")
ok(tools.run("define_skill", { name = "1bad", instructions = "x" }):find("invalid skill name"),
   "define_skill rejects a bad name")
ok(tools.run("skills"):find("code_review"), "skills tool lists them")
ok(tools.run("skills", { name = "nope" }):find("no skill named"), "skills tool reports unknown")

-- ---- skills that carry CODE (`provides`) -----------------------------------
-- shape validation
ok(skills.validate({ provides = { { name = "x", body = "return '1'" } } }) == nil,
   "provides with a body validates")
ok(skills.validate({ provides = { { name = "x" } } }):find("exactly one"),
   "provides entry needs exactly one of body/run")
ok(skills.validate({ provides = { { name = "1bad", body = "x" } } }):find("name must match"),
   "provides name must be an identifier")

-- a BUILTIN skill carrying a real trusted `run` function (the selfmod demonstrator),
-- materialized at tools load
ok(tools.registry.skill__selfmod__word_count ~= nil,
   "builtin skill's provided run() is materialized")
ok(tools.run("skill__selfmod__word_count", { text = "a b c" }) == "3",
   "builtin provided function runs")

-- a MODEL-authored skill carrying a sandboxed body, end to end
local dmsg = tools.run("define_skill", {
  name = "counter", description = "counts words", instructions = "use words",
  provides = { {
    name = "words",
    description = "count whitespace-separated words in args.text",
    input_schema = { type = "object", properties = { text = { type = "string" } } },
    body = "local n=0 for _ in tostring(args.text or ''):gmatch('%S+') do n=n+1 end return tostring(n)",
  } },
})
ok(dmsg:find("1 provided"), "define_skill accepts provides")
ok(skills.load("counter").provides[1].name == "words", "provides round-trips in the skill file")

local _, callow = skills.resolve({ "counter" })
ok(callow.skill__counter__words, "resolve grants the namespaced provided tool")
ok(tools.registry.skill__counter__words ~= nil, "save re-materialized the provided tool")

local snames = {}
for _, sc in ipairs(tools.schemas_for(callow)) do snames[sc.name] = true end
ok(snames.skill__counter__words, "provided tool appears in schemas_for(allow)")

local dnames = {}
for _, sc in ipairs(tools.schemas()) do dnames[sc.name] = true end
ok(not dnames.skill__counter__words, "provided tool is NOT in the unrestricted default schemas()")

ok(tools.run("skill__counter__words", { text = "a b c d" }) == "4",
   "provided body runs (sandboxed)")

ok(tools.run("define_skill", { name = "broken", instructions = "x",
     provides = { { name = "oops", body = "this is not lua(" } } }):find("validation_error"),
   "define_skill rejects an uncompilable provided body")

sys.rmtree(bog.userdir)
bog.userdir = saved_userdir

io.write(string.format("skills: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
