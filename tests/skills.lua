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

sys.rmtree(bog.userdir)
bog.userdir = saved_userdir

io.write(string.format("skills: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
