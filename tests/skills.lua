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
name: diff-notes
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
ok(skill and name == "diff_notes", "frontmatter name parsed and normalised")
ok(skill.description == "Review a diff for correctness", "description parsed")
ok(#skill.tools == 3 and skill.tools[2] == "git_diff", "allowed-tools parsed")
ok(skill.instructions:find("real defects"), "body becomes instructions")
ok(skills.parse_markdown("   ") == nil, "empty document rejected")

-- ---- validation ------------------------------------------------------------
ok(skills.validate({ description = "d", instructions = "i", tools = { "a" } }) == nil, "valid passes")
ok(skills.validate({ tools = "nope" }):find("list of tool names"), "tools must be a list")
ok(skills.validate({ instructions = 5 }):find("string or a function"), "instructions type checked")

-- ---- the compile step ------------------------------------------------------
local src = skills.to_lua("diff_notes", skill, "SKILL.md")
ok(load(src) ~= nil, "generated Lua compiles")
ok(load(src)().description == skill.description, "generated Lua round-trips")
local tricky = skills.to_lua("t", { description = "d", instructions = "has ]] inside", tools = {} })
ok(load(tricky) and load(tricky)().instructions == "has ]] inside",
   "instructions containing ]] still compile and round-trip")

-- ---- import produces a real, requireable skill -----------------------------
local iname, path = skills.import(MD, nil, "SKILL.md")
ok(iname == "diff_notes" and path:find("diff_notes%.lua$"), "import writes a Lua skill file")
local loaded = skills.load("diff_notes")
ok(loaded and loaded.description == "Review a diff for correctness", "imported skill loads")

local instr, allow, unknown = skills.resolve({ "diff_notes" })
ok(instr:find("## Skill: diff_notes"), "resolve emits instructions")
ok(allow.git_diff and allow.read, "resolve grants the skill's tools")
ok(#unknown == 0, "no unknowns for a real skill")

-- ---- the gap that mattered: unknown skills are reported, not dropped -------
local _, _, unk = skills.resolve({ "diff_notes", "gti_worktree" })
ok(#unk == 1 and unk[1] == "gti_worktree", "a misspelled skill is reported")

-- ---- listing ---------------------------------------------------------------
local byname = {}
for _, r in ipairs(skills.list()) do byname[r.name] = r.source end
ok(byname.core == "builtin", "list includes baked-in skills")
ok(byname.diff_notes == "overlay", "list includes imported overlay skills")

-- ---- wiring + the tools through the real registry --------------------------
ok(tools.registry.skills ~= nil, "skills tool registered")
ok(tools.registry.define_skill ~= nil, "define_skill registered")
ok(tools.registry.import_skill ~= nil, "import_skill registered")

ok(tools.run("import_skill", { text = MD, name = "renamed" }):find("Imported skill 'renamed'"),
   "import_skill tool compiles markdown to a Lua skill")
ok(skills.load("renamed") ~= nil, "renamed import is loadable")
ok(tools.run("define_skill", { name = "hand-made", instructions = "do the thing",
     description = "d", tools = { "read" } }):find("Defined skill 'hand_made'"),
   "define_skill authors and normalises the name")
ok(skills.load("hand_made").tools[1] == "read", "defined skill persisted with its tools")
ok(tools.run("define_skill", { name = "1bad", instructions = "x" }):find("invalid skill name"),
   "define_skill rejects a bad name")
ok(tools.run("skills"):find("diff_notes"), "skills tool lists them")
ok(tools.run("skills", { name = "nope" }):find("no skill named"), "skills tool reports unknown")

-- ---- skills that carry CODE (`provides`, a table keyed by tool name) --------
-- shape validation
ok(skills.validate({ provides = { x = { body = "return '1'" } } }) == nil,
   "provides with a body validates")
ok(skills.validate({ provides = { x = {} } }):find("exactly one"),
   "provides entry needs exactly one of body/run")
ok(skills.validate({ provides = { ["1bad"] = { body = "x" } } }):find("must match"),
   "provides key must be an identifier")

-- a BUILTIN skill carrying a real trusted `run` function (the selfmod demonstrator),
-- materialized at tools load
ok(tools.registry.skill__selfmod__word_count ~= nil,
   "builtin skill's provided run() is materialized")
ok(tools.run("skill__selfmod__word_count", { text = "a b c" }) == "3",
   "builtin provided function runs")

-- a MODEL-authored skill carrying a sandboxed body, end to end
local dmsg = tools.run("define_skill", {
  name = "counter", description = "counts words", instructions = "use words",
  provides = {
    words = {
      description = "count whitespace-separated words in args.text",
      input_schema = { type = "object", properties = { text = { type = "string" } } },
      body = "local n=0 for _ in tostring(args.text or ''):gmatch('%S+') do n=n+1 end return tostring(n)",
    },
  },
})
ok(dmsg:find("1 provided"), "define_skill accepts provides")
ok(skills.load("counter").provides.words ~= nil, "provides round-trips keyed by name")

local _, callow = skills.resolve({ "counter" })
ok(callow["skill__counter__*"], "resolve grants the skill's namespace with a wildcard (like MCP)")
ok(tools.registry.skill__counter__words ~= nil, "save re-materialized the provided tool")

local snames = {}
for _, sc in ipairs(tools.schemas_for(callow)) do snames[sc.name] = true end
ok(snames.skill__counter__words, "provided tool appears in schemas_for(allow) via the wildcard")

local dnames = {}
for _, sc in ipairs(tools.schemas()) do dnames[sc.name] = true end
ok(not dnames.skill__counter__words, "provided tool is NOT in the unrestricted default schemas()")

ok(tools.run("skill__counter__words", { text = "a b c d" }) == "4",
   "provided body runs (sandboxed)")

ok(tools.run("define_skill", { name = "broken", instructions = "x",
     provides = { oops = { body = "this is not lua(" } } }):find("validation_error"),
   "define_skill rejects an uncompilable provided body")

-- ---- importing markdown WITH code (a `## Tools` section) --------------------
local MDT = "---\nname: text-kit\ndescription: text helpers\n---\n"
  .. "Use these for text.\n\n## Tools\n\n### shout\nUppercase args.text.\n\n"
  .. "```lua\nreturn tostring(args.text or \"\"):upper()\n```\n"
local sk2 = skills.parse_markdown(MDT)
ok(sk2 and sk2.provides and sk2.provides.shout ~= nil, "## Tools section becomes provides.shout")
ok(sk2.provides.shout.body:find("upper"), "the fenced lua becomes the tool body")
ok(sk2.provides.shout.description:find("Uppercase"), "the prose becomes the tool description")
ok(not sk2.instructions:find("## Tools"), "the Tools section is lifted out of the instructions")
ok(tools.run("import_skill", { text = MDT }):find("1 provided tool"), "import reports the code it found")
local _, tkallow = skills.resolve({ "text_kit" })
ok(tkallow["skill__text_kit__*"], "an imported skill grants its namespace like any other")
ok(tools.run("skill__text_kit__shout", { text = "hi" }) == "HI", "the imported provided tool runs")

-- ---- DB-backed storage (store="db") ----------------------------------------
pcall(function() if not bog.db then bog.store.open() end end)
if bog.db then
  local dbmsg = tools.run("define_skill", {
    name = "dbskill", instructions = "lives in the db",
    provides = { echo = { description = "echo args.text", body = "return tostring(args.text or '')" } },
    store = "db",
  })
  ok(dbmsg:find("in the database"), "define_skill store=db reports DB storage")
  ok(sys.stat(bog.userdir .. "/lua/skills/dbskill.lua") ~= "file", "no file is written for a db skill")
  ok(skills.load("dbskill") ~= nil, "a db skill loads via M.load")
  local dbsrc = {}
  for _, r in ipairs(skills.list()) do dbsrc[r.name] = r.source end
  ok(dbsrc.dbskill == "database", "list marks the db skill's source")
  ok(tools.registry.skill__dbskill__echo ~= nil, "a db skill's provided tool materializes")
  ok(tools.run("skill__dbskill__echo", { text = "yo" }) == "yo", "a db skill's provided tool runs")
end

-- ---- fallback skills: backups granted for graceful degradation -------------
ok(skills.validate({ instructions = "i", fallback = "base" }) == nil, "fallback string validates")
ok(skills.validate({ instructions = "i", fallback = { "a", "b" } }) == nil, "fallback list validates")
ok(skills.validate({ fallback = 5 }):find("skill name"), "fallback of the wrong type is rejected")

-- to_lua round-trips the fallback field
local fsrc = skills.to_lua("pref", { description = "d", instructions = "i", tools = {}, fallback = "base" })
ok(load(fsrc) and load(fsrc)().fallback == "base", "to_lua round-trips a fallback")

-- resolve grants BOTH the preferred and the fallback skill's tools
do
  local dir = bog.userdir .. "/lua/skills/"
  local f1 = io.open(dir .. "base_search.lua", "w")
  f1:write('return { description="d", instructions="use grep", tools={"bash"} }'); f1:close()
  local f2 = io.open(dir .. "rich_search.lua", "w")
  f2:write('return { description="d", instructions="prefer station", '
    .. 'tools={"mcp__llm-station__bm25"}, fallback="base_search" }'); f2:close()

  local instr, allow = skills.resolve({ "rich_search" })
  ok(allow["mcp__llm-station__bm25"], "resolve grants the preferred (rich) tool")
  ok(allow["bash"], "resolve also grants the fallback skill's tools")
  ok(instr:find("prefer station") and not instr:find("use grep"),
     "a fallback contributes tools, not a second instruction block")
end

-- ---- invocation (model vs user) --------------------------------------------
ok(skills.validate({ instructions = "i", invocation = "model" }) == nil, "invocation=model ok")
ok(skills.validate({ instructions = "i", invocation = "user" }) == nil, "invocation=user ok")
ok(skills.validate({ instructions = "i", invocation = "both" }):find("invocation"),
   "bad invocation rejected")

local UMD = [[
---
name: only-user
description: User-only interview skill
disable-model-invocation: true
---
Ask hard questions.
]]
local uskill = skills.parse_markdown(UMD)
ok(uskill and uskill.invocation == "user", "disable-model-invocation maps to user")

-- baked gold skills load and lint clean
for _, n in ipairs({ "tdd", "diagnosing_bugs", "code_review", "research",
                     "resolving_merge_conflicts", "grilling", "grill_me" }) do
  local s = skills.load(n)
  ok(s ~= nil, "gold skill loads: " .. n)
  if s then
    local lint = skills.lint(n)
    ok(lint.ok, "gold skill lints: " .. n .. (lint.ok and "" or (" " .. table.concat(lint.issues, "; "))))
    if n == "grill_me" then
      ok(s.invocation == "user", "grill_me is user-invoked")
    else
      ok(s.invocation == "model", n .. " is model-invoked")
    end
  end
end

sys.rmtree(bog.userdir)
bog.userdir = saved_userdir

io.write(string.format("skills: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
