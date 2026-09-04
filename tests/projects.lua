-- projects.lua -- the unit of context.
--
-- One rule carries the whole feature: a read returns THIS project's rows first,
-- then `global`'s underneath, and never another project's. Everything else --
-- roots, chats, forget, promote -- is machinery around that sentence, so it is
-- the sentence these tests spend most of their assertions on.
--
-- `global` is itself a project (loose chat), not a separate tier, which is what
-- makes the migration a no-op: a row with no project already means global, so
-- every memory and chat that existed before projects did is correctly
-- classified without rewriting anything.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_projects"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

local proj = require "project"
local mem = bog.memory

-- ---- global exists and is where you start --------------------------------
eq(proj.current(), "global", "you start in global")
ok(proj.get("global") ~= nil, "the global project exists from the first run")
ok(select(1, proj.delete("global")) == nil, "global cannot be deleted")

-- ---- creating and switching ----------------------------------------------
local nj = proj.create("nightjar", {})
ok(nj ~= nil, "a project can be created")
eq(nj.name, "nightjar", "under its name")
ok(proj.create("nightjar", {}) == nil, "creating the same name twice is refused")
eq(proj.normalize("My Story!"), "my-story", "names are normalised into keys")

ok(select(1, proj.switch("no-such-project")) == nil, "switching to a project that does not exist fails")
eq(proj.current(), "global", "and leaves you where you were")
proj.switch("nightjar")
eq(proj.current(), "nightjar", "switching works")

-- ---- THE RULE: own first, global underneath, never a sibling -------------
proj.switch("global")
mem.remember("house-style", "terse commit messages")     -- a global memory

proj.switch("nightjar")
mem.remember("protagonist", "Wren, a lighthouse keeper")

local rw = proj.create("redwing", {})
proj.switch("redwing")
mem.remember("protagonist", "Alder, a cartographer")

-- a sibling's memory is invisible, even under the same title
local seen = mem.recall("protagonist")
ok(seen:find("Alder", 1, true), "a project sees its own memory")
ok(not seen:find("Wren", 1, true), "THE RULE: it cannot see a sibling project's memory")

-- global is visible underneath, and labelled so you can tell
local g = mem.recall("commit messages")
ok(g:find("terse commit messages", 1, true), "global is readable from inside a project")
ok(g:find("(global)", 1, true), "and a global hit is labelled as global")

-- ranking: own results come before global ones
proj.switch("nightjar")
mem.remember("style-note", "long sentences, few adverbs")
proj.switch("global")
mem.remember("style-note-global", "global style note")
proj.switch("nightjar")
local list = mem.list()
ok(#list >= 2, "the project sees its own and global's memories")
eq(list[1].is_global, false, "own memories rank above global ones")

-- global itself sees only global
proj.switch("global")
local gl = mem.recall("protagonist")
ok(not gl:find("Wren", 1, true), "global does not see a project's memories")
ok(not gl:find("Alder", 1, true), "nor another's")

-- ---- forget is scoped ----------------------------------------------------
proj.switch("nightjar")
ok(mem.forget("protagonist"), "a memory can be forgotten in this project")
ok(not mem.recall("protagonist"):find("Wren", 1, true), "and is gone from it")
proj.switch("redwing")
ok(mem.recall("protagonist"):find("Alder", 1, true),
   "forgetting in one project leaves the sibling's untouched")
proj.switch("global")
ok(mem.recall("commit messages"):find("terse", 1, true),
   "and leaves global untouched")

-- ---- promotion is the only way into global -------------------------------
proj.switch("nightjar")
mem.remember("shared-fact", "the sea is cold")
proj.switch("redwing")
ok(not mem.recall("shared-fact"):find("the sea is cold", 1, true),
   "before promotion a sibling cannot see it")
proj.switch("nightjar")
ok(mem.promote("shared-fact"), "a memory can be promoted to global")
proj.switch("redwing")
ok(mem.recall("shared-fact"):find("the sea is cold", 1, true),
   "after promotion every project can")

-- ---- chats belong to projects, and can be reassigned ---------------------
proj.switch("nightjar")
local s1 = bog.store.sess_create("scene one", "m", "nightjar")
bog.store.sess_save(s1, "scene one", "m", { { role = "user", content = "hi" } })
proj.switch("redwing")
local s2 = bog.store.sess_create("chapter one", "m", "redwing")
bog.store.sess_save(s2, "chapter one", "m", { { role = "user", content = "hi" } })

local rl = bog.store.sess_list(50, "redwing")
local names = {}
for _, r in ipairs(rl) do names[r.title or ""] = true end
ok(names["chapter one"], "the recents list shows this project's chats")
ok(not names["scene one"], "and not a sibling's")

ok(bog.store.sess_assign(s1, "redwing"), "a chat can be assigned to another project")
local rl2 = bog.store.sess_list(50, "redwing")
local moved = false
for _, r in ipairs(rl2) do if r.title == "scene one" then moved = true end end
ok(moved, "and it moves")

-- ---- roots ---------------------------------------------------------------
local dir = bog.userdir .. "/root-a"
sys.mkdir_p(dir)
proj.switch("nightjar")
local roots = proj.add_root("nightjar", dir)
ok(roots and #roots == 1, "a root can be added")
ok(proj.owns(dir .. "/chapter.md", "nightjar"), "the project owns paths under its root")
ok(not proj.owns("/somewhere/else", "nightjar"), "and not paths outside it")
ok(select(1, proj.add_root("nightjar", "/definitely/not/here")) == nil,
   "a root that is not a directory is refused")

eq(proj.for_directory(dir), "nightjar", "a directory resolves to the project that owns it")
-- ambiguity must not guess: two projects claiming one directory resolves to nothing
proj.add_root("redwing", dir)
local who, n = proj.for_directory(dir)
eq(who, nil, "a directory owned by two projects resolves to neither")
eq(n, 2, "and says how many claimed it")

-- ---- deleting a project keeps its contents -------------------------------
proj.switch("global")
local before = #bog.store.sess_list(100, "global")
local absorbed = proj.delete("redwing")
ok(absorbed and absorbed > 0, "deleting a project reports what it absorbed")
ok(proj.get("redwing") == nil, "the project is gone")
local after = #bog.store.sess_list(100, "global")
ok(after > before, "and its chats came home to global rather than vanishing")

-- ---- skills are keyed to projects, not copied into them ------------------
-- One direction of reference: the skill names its projects, nothing names its
-- skills. A skill with no row is global, which is what every existing skill is.
local skills = require "skills"
proj.switch("nightjar")
local before = #skills.list()
skills.key_to_project("tdd", "nightjar")
eq(skills.project_keys()["tdd"][1], "nightjar", "a skill can be keyed to a project")
local here_list = {}
for _, sk in ipairs(skills.list()) do here_list[sk.name] = true end
ok(here_list["tdd"], "the keyed skill is available in its own project")

proj.switch("global")
local there = {}
for _, sk in ipairs(skills.list()) do there[sk.name] = true end
ok(not there["tdd"], "and is NOT offered in another project")
ok(there["core"], "while unkeyed skills stay available everywhere")
eq(before > 0, true, "the skill list is non-empty to begin with")

-- ---- the manifest travels; it never installs -----------------------------
proj.switch("nightjar")
local mdir = bog.userdir .. "/manifest-root"
sys.mkdir_p(mdir)
proj.add_root("nightjar", mdir)
local path, doc = proj.write_manifest("nightjar")
ok(path ~= nil, "a manifest is written into the project's first root")
ok(path and path:find("%.boggart/project%.json$"), "at .boggart/project.json")
ok(doc and doc.name == "nightjar", "naming the project")
local wrote = bog.util.read_file(path)
ok(wrote and wrote:find("tdd", 1, true), "listing the skills it expects")
ok(wrote and not wrote:find("instructions", 1, true),
   "and NOT their bodies -- the repo never receives executable behaviour")

local rep = proj.reconcile_report("nightjar")
ok(rep and rep:find("present", 1, true), "reconcile reports a satisfied manifest: " .. tostring(rep))

-- a manifest naming something this machine lacks reports it, and installs nothing
local f = io.open(path, "w")
f:write('{"name":"nightjar","roots":["."],"skills":["tdd","not-on-this-machine"]}')
f:close()
local r2 = proj.reconcile("nightjar")
eq(#r2.missing, 1, "a missing skill is reported")
eq(r2.missing[1], "not-on-this-machine", "by name")
eq(#r2.have, 1, "alongside what is present")
local after_reconcile = {}
for _, sk in ipairs(skills.list()) do after_reconcile[sk.name] = true end
ok(not after_reconcile["not-on-this-machine"], "reconcile never installs anything")

-- ---- the named project is the working anchor -----------------------------
-- project_root() decided where project-scoped tools live, by inferring a git
-- repo from the shell. A named project is a better answer to the same question.
-- nightjar already had root-a added above, so its FIRST root is that one --
-- which is the point: project_root() is the anchor, and a project's roots are
-- ordered.
eq(bog.tools.project_root(), proj.roots("nightjar")[1],
   "the project's first root IS the project root")
ok(#proj.roots("nightjar") == 2, "and a project can hold several roots at once")
proj.switch("global")
ok(bog.tools.project_root() ~= nil, "global still resolves to something (git, else cwd)")

io.write(string.format("projects: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
