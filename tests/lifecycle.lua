-- lifecycle.lua -- install, self-repair and diagnosis (lua/lifecycle.lua,
-- lua/store.lua's open path, sys.paths() in src/lsys.c, `boggart doctor`).
--
-- Half of this suite runs the real binary against a throwaway HOME rather than
-- calling the functions in-process, and that is the point: every failure this
-- covers was a failure of *wiring* -- boot.lua resolving a path itself, a
-- traceback escaping bog.try, a store opened before anyone checked the
-- directory. A test that only calls store.open() proves none of that.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local lifecycle = require("lifecycle")
local caps = sys.caps()

-- Can a write to a directory actually be denied to *this* process?
--
-- The read-only cases below are skipped on the answer rather than on the
-- platform name. Two situations say no for unrelated reasons: Windows, where
-- chmod 0500 does not deny a directory write and the ACL that would is not
-- something sys.chmod can set; and running as root, where uid 0 ignores the
-- mode entirely -- which is every Docker container that has not created a
-- user, so this suite failed in CI for a reason that had nothing to do with
-- the code under test. Probing answers both without naming either.
local function can_be_denied(base)
  local probe = base .. "/deny_probe"
  sys.mkdir_p(probe)
  sys.chmod(probe, 0x140) -- 0500
  local wrote = bog.util.write_file(probe .. "/canary", "x")
  sys.chmod(probe, 0x1C0) -- 0700, so cleanup can remove it
  if wrote then os.remove(probe .. "/canary") end
  return not wrote
end

bog.userdir = os.tmpname() .. "_boggart_lifecycle"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.paths = nil -- re-resolved below; this process's own paths are not the subject

-- ===========================================================================
-- Path policy (decided in C, asked for from Lua)
-- ===========================================================================
do
  local p, err = sys.paths()
  ok(p ~= nil, "sys.paths() resolves a data directory (" .. tostring(err) .. ")")
  if p then
    ok(type(p.data) == "string" and #p.data > 0, "paths.data is a path")
    ok(type(p.source) == "string" and #p.source > 0, "paths.source says which rule chose it")
    ok(p.legacy ~= nil and p.legacy:find("%.boggart$") ~= nil,
       "paths.legacy points at ~/.boggart whether or not it exists")
    ok(p.data:sub(-1) ~= "/", "no trailing separator on the data directory")
    -- The suite runs with HOME=build/testhome/lifecycle, so this must not have
    -- resolved to the developer's real directory.
    ok(p.data:find(p.home, 1, true) == 1, "the data directory is under this run's HOME")
  end
end

-- ===========================================================================
-- ensure_dir: creates what is missing, explains what it cannot
-- ===========================================================================
do
  local base = bog.userdir .. "/ensure"
  local nested = base .. "/a/b/c"
  ok(lifecycle.ensure_dir(nested), "ensure_dir creates missing parents")
  eq(sys.stat(nested), "dir", "...and the directory is really there")
  ok(lifecycle.ensure_dir(nested), "ensure_dir is idempotent on an existing directory")

  -- A file where the directory should be.
  local occupied = base .. "/occupied"
  bog.util.write_file(occupied, "in the way")
  local good, err = bog.try(lifecycle.ensure_dir, occupied)
  ok(not good, "a file in place of the data directory is refused")
  ok(type(err) == "table" and err.boggart_error,
     "...as a diagnosed error, so bog.try attaches no traceback")
  local text = tostring(err)
  ok(text:find(occupied, 1, true) ~= nil, "...naming the path")
  ok(text:find("not a directory", 1, true) ~= nil, "...saying what is wrong with it")
  ok(text:find("BOGGART_HOME", 1, true) ~= nil, "...and what to do about it")
  ok(text:find("traceback") == nil, "...with no stack traceback anywhere in it")

  if can_be_denied(base) then
    local ro = base .. "/readonly"
    sys.mkdir_p(ro)
    sys.chmod(ro, 0x140) -- 0500
    local ok2, err2 = bog.try(lifecycle.ensure_dir, ro .. "/child")
    ok(not ok2, "an unwritable parent is refused")
    ok(type(err2) == "table" and tostring(err2):find("cannot create", 1, true) ~= nil,
       "...with a sentence naming the directory it could not create")
    sys.chmod(ro, 0x1C0) -- 0700, so cleanup can remove it
  end
end

-- ===========================================================================
-- store.open: creation, repair, and the schema gate
-- ===========================================================================
local function fresh_store(name)
  local dir = bog.userdir .. "/" .. name
  sys.mkdir_p(dir)
  bog.userdir = dir
  if bog.db then bog.db:close() end
  bog.db = nil
  bog.store.open()
  return dir
end

local ROOT = bog.userdir
do
  local dir = fresh_store("store_new")
  eq(sys.stat(dir .. "/boggart.db"), "file", "open() creates the database on a new machine")
  ok(bog.store.state.first_run, "...and reports it as a first run")
  eq(bog.store.schema_version(bog.db), bog.store.SCHEMA_VERSION,
     "...with the current schema version recorded")
  local meta = bog.db:query("SELECT value FROM meta WHERE key='installed_at'")
  ok(meta[1] ~= nil, "...and an installed_at stamp")
  bog.store.mem_put("a memory", "body")

  -- Reopening an existing store is not a first run and keeps the data.
  bog.db:close(); bog.db = nil
  bog.store.open()
  ok(not bog.store.state.first_run, "reopening an existing store is not a first run")
  eq(#bog.store.mem_list(), 1, "...and the memory survived")
  bog.userdir = ROOT
end

do
  -- Corruption: moved aside, never deleted, and the new store works.
  local dir = fresh_store("store_corrupt")
  bog.store.mem_put("doomed", "this is lost, and we say so")
  bog.db:close(); bog.db = nil
  bog.util.write_file(dir .. "/boggart.db", "GARBAGE, not a database")

  bog.store.open() -- prints its loud notice on stderr; that is the behaviour
  ok(bog.store.state.recovered ~= nil, "a damaged store is recovered")
  ok(not bog.store.state.first_run,
     "...and is not mistaken for a first install (no welcome for an old user)")
  local moved = bog.store.state.recovered
  eq(sys.stat(moved), "file", "...the damaged file is still on disk")
  ok(moved:find("corrupt%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d") ~= nil,
     "...under a timestamped name")
  eq(bog.util.read_file(moved), "GARBAGE, not a database",
     "...with its bytes untouched, so it can still be salvaged")
  eq(#bog.store.mem_list(), 0, "...and the new store is empty, as advertised")
  eq(bog.store.schema_version(bog.db), bog.store.SCHEMA_VERSION,
     "...with a full schema in it")
  bog.userdir = ROOT
end

do
  -- A database from the future is refused, not half-migrated.
  local dir = bog.userdir .. "/store_future"
  sys.mkdir_p(dir)
  bog.userdir = dir
  if bog.db then bog.db:close() end
  bog.db = nil
  local c = db.open(dir .. "/boggart.db")
  c:exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);" ..
         "CREATE TABLE sessions (id INTEGER PRIMARY KEY, title TEXT);")
  c:run("INSERT INTO meta(key,value) VALUES('schema_version','99')")
  c:close()

  local good, err = bog.try(bog.store.open)
  ok(not good, "a newer schema is refused")
  local text = tostring(err)
  ok(type(err) == "table" and err.boggart_error, "...as a diagnosed error, not a traceback")
  ok(text:find("newer boggart", 1, true) ~= nil, "...explaining that the store is newer")
  ok(text:find("99", 1, true) ~= nil and text:find(tostring(bog.store.SCHEMA_VERSION), 1, true) ~= nil,
     "...naming both versions")
  ok(bog.db == nil, "...and leaves no half-open connection behind")

  -- The important half: nothing was written to it.
  local c2 = db.open(dir .. "/boggart.db")
  local cols = {}
  for _, r in ipairs(c2:query("PRAGMA table_info(sessions)")) do cols[r.name] = true end
  ok(not cols.parent_id, "the additive migrations did NOT run against it")
  eq(#c2:query("SELECT name FROM sqlite_master WHERE name='memory'"), 0,
     "...and neither did the schema")
  c2:close()
  bog.userdir = ROOT
end

do
  -- The additive migrations still work on an older, legitimate store.
  local dir = bog.userdir .. "/store_old"
  sys.mkdir_p(dir)
  bog.userdir = dir
  if bog.db then bog.db:close() end
  bog.db = nil
  local c = db.open(dir .. "/boggart.db")
  c:exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);" ..
         "CREATE TABLE sessions (id INTEGER PRIMARY KEY, title TEXT, model TEXT," ..
         " created INTEGER, updated INTEGER, messages TEXT);")
  c:run("INSERT INTO sessions(title,messages) VALUES('from an old boggart','[]')")
  c:close()

  bog.store.open()
  local cols = {}
  for _, r in ipairs(bog.db:query("PRAGMA table_info(sessions)")) do cols[r.name] = true end
  ok(cols.parent_id and cols.status and cols.subscriptions and cols.spec,
     "a pre-swarm store is migrated in place by ensure_column")
  eq(#bog.db:query("SELECT id FROM sessions"), 1, "...without losing its rows")
  eq(bog.store.schema_version(bog.db), bog.store.SCHEMA_VERSION, "...and is stamped current")
  bog.userdir = ROOT
end

-- ===========================================================================
-- doctor, in process (what the GUI calls)
-- ===========================================================================
do
  local dir = fresh_store("doctor_ok")
  local text, good = lifecycle.doctor()
  ok(text:find("data directory", 1, true) ~= nil, "doctor reports the data directory")
  ok(text:find(dir, 1, true) ~= nil, "...by path")
  ok(text:find("writable", 1, true) ~= nil, "...and whether it can be written")
  ok(text:find("integrity    ok", 1, true) ~= nil, "doctor checks database integrity")
  ok(text:find("schema", 1, true) ~= nil, "...and reports the schema version")
  ok(text:find("api key", 1, true) ~= nil, "doctor reports the credential state")
  ok(text:find("endpoint", 1, true) ~= nil, "...and the endpoint")
  ok(text:find("mcp servers", 1, true) ~= nil, "doctor reports MCP servers")
  ok(text:find("overlay files", 1, true) ~= nil, "...and overlay files")
  ok(text:find("free of", 1, true) ~= nil, "...and disk space")
  ok(type(good) == "boolean", "doctor returns a verdict the caller can branch on")

  -- Overlay shadowing is called out by name.
  sys.mkdir_p(dir .. "/lua")
  bog.util.write_file(dir .. "/lua/store.lua", "return {}")
  bog.util.write_file(dir .. "/lua/notamodule.lua", "return {}")
  local text2 = lifecycle.doctor()
  ok(text2:find("shadowing", 1, true) ~= nil, "doctor notices an overlay shadowing a built-in")
  ok(text2:find("\n               store\n") ~= nil, "...and names the module")
  os.remove(dir .. "/lua/store.lua")
  os.remove(dir .. "/lua/notamodule.lua")

  -- A damaged store is reported rather than repaired: doctor diagnoses.
  bog.db:close(); bog.db = nil
  bog.util.write_file(dir .. "/boggart.db", "NOT A DATABASE")
  local text3, good3 = lifecycle.doctor()
  ok(text3:find("integrity    FAILED", 1, true) ~= nil, "doctor reports a damaged store")
  ok(not good3, "...and fails its verdict")
  eq(bog.util.read_file(dir .. "/boggart.db"), "NOT A DATABASE",
     "...without touching the file it is diagnosing")
  bog.userdir = ROOT
  bog.db = nil
end

-- ===========================================================================
-- The real binary against a throwaway HOME
-- ===========================================================================
-- POSIX only, and on the shell capability rather than the platform name: the
-- `VAR=value cmd` prefix and `env -u` below are sh syntax, and cmd.exe spells
-- both differently (`set VAR=...` plus USERPROFILE, which is what sysfs_home
-- reads there). A Windows harness would need its own runner.
if caps.shell_kind ~= "cmd" then
  local HOMES = ROOT .. "/homes"
  sys.mkdir_p(HOMES)
  local probe = ROOT .. "/probe.lua"
  bog.util.write_file(probe, [[
io.write("userdir=", bog.userdir, "\n")
io.write("source=", bog.paths.source, "\n")
io.write("firstrun=", tostring(bog.store.state and bog.store.state.first_run), "\n")
return 0
]])

  -- Every child starts from a known environment: the developer running ctest
  -- may well have a key exported, and "doctor exits non-zero when broken" is
  -- not a test if the answer depends on that.
  local n = 0
  local function run(env, args)
    n = n + 1
    local home = HOMES .. "/h" .. n
    sys.mkdir_p(home)
    local cmd = string.format(
      "env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u BOGGART_HOME -u XDG_DATA_HOME " ..
      "HOME=%q %s ./boggart %s 2>&1", home, env or "", args)
    local r = sys.exec(cmd, 60)
    return r, home
  end

  -- ---- a genuinely new install -------------------------------------------
  -- The expected path is spelled out per platform rather than "something under
  -- HOME": the whole point of the policy is *which* directory, and CI runs this
  -- on Linux, where the XDG branch is the one under test.
  local PLATFORM_DIR = ({
    macos = "/.boggart",
    linux = "/.local/share/boggart",
  })[caps.name]
  do
    local r, home = run(nil, "--eval " .. string.format("%q", probe))
    eq(r.code, 0, "a first run on a new machine succeeds")
    if PLATFORM_DIR then
      ok(r.out:find("userdir=" .. home .. PLATFORM_DIR .. "\n", 1, true) ~= nil,
         "...in the platform location, " .. PLATFORM_DIR ..
         " (" .. r.out:gsub("\n", " ") .. ")")
    end
    ok(r.out:find("firstrun=true", 1, true) ~= nil, "...reported as a first run")
    ok(r.out:find("traceback") == nil, "...with no traceback")
    local data = r.out:match("userdir=([^\n]+)")
    eq(sys.stat(data .. "/boggart.db"), "file", "...and the database exists afterwards")
  end

  -- ---- $XDG_DATA_HOME, where the desktop convention applies ---------------
  if caps.name == "linux" then
    local xdg = ROOT .. "/xdg"
    local r = run("XDG_DATA_HOME=" .. string.format("%q", xdg),
                  "--eval " .. string.format("%q", probe))
    ok(r.out:find("userdir=" .. xdg .. "/boggart\n", 1, true) ~= nil,
       "XDG_DATA_HOME moves the data directory")
    ok(r.out:find("source=$XDG_DATA_HOME", 1, true) ~= nil, "...and doctor can say why")
  end

  -- ---- an existing ~/.boggart is adopted, never relocated ------------------
  do
    local r0, home = run(nil, "--version")
    eq(r0.code, 0, "--version works before anything is installed")
    ok(r0.out:find("boggart 0.", 1, true) ~= nil, "...and prints the version")
    eq(sys.stat(home .. "/.boggart"), nil, "--version touches no disk at all")

    sys.mkdir_p(home .. "/.boggart")
    bog.util.write_file(home .. "/.boggart/marker", "mine")
    local cmd = string.format(
      "env -u ANTHROPIC_API_KEY -u BOGGART_HOME HOME=%q ./boggart --eval %q 2>&1", home, probe)
    local r = sys.exec(cmd, 60)
    ok(r.out:find("userdir=" .. home .. "/.boggart\n", 1, true) ~= nil,
       "an existing ~/.boggart keeps being used, whatever the platform default is")
    ok(r.out:find("source=existing ~/.boggart", 1, true) ~= nil,
       "...and doctor can say that is why")
    eq(bog.util.read_file(home .. "/.boggart/marker"), "mine", "...and nothing was moved")
  end

  -- ---- BOGGART_HOME overrides everything ----------------------------------
  do
    local elsewhere = ROOT .. "/elsewhere"
    local r, home = run("BOGGART_HOME=" .. string.format("%q", elsewhere),
                        "--eval " .. string.format("%q", probe))
    eq(r.code, 0, "BOGGART_HOME start succeeds")
    ok(r.out:find("userdir=" .. elsewhere .. "\n", 1, true) ~= nil,
       "BOGGART_HOME wins over the platform location")
    ok(r.out:find("source=BOGGART_HOME", 1, true) ~= nil, "...and says so")
    eq(sys.stat(elsewhere .. "/boggart.db"), "file", "...and the store is created there")
    eq(sys.stat(home .. "/.boggart"), nil, "...leaving HOME alone")
  end

  -- ---- a corrupt store heals, loudly --------------------------------------
  do
    local dir = ROOT .. "/corrupt_home"
    local envs = "BOGGART_HOME=" .. string.format("%q", dir)
    local r1 = run(envs, "--eval " .. string.format("%q", probe))
    eq(r1.code, 0, "install into a fresh BOGGART_HOME")
    bog.util.write_file(dir .. "/boggart.db", "GARBAGE")

    local r2 = run(envs, "--eval " .. string.format("%q", probe))
    eq(r2.code, 0, "a corrupt store does not stop the program")
    ok(r2.out:find("MOVED ASIDE", 1, true) ~= nil, "...it says so, loudly")
    ok(r2.out:find("are NOT in the new store", 1, true) ~= nil,
       "...and admits the sessions and memory are gone")
    ok(r2.out:find("traceback") == nil, "...with no traceback")
    local found
    for _, name in ipairs(sys.listdir(dir) or {}) do
      if name:match("^boggart%.db%.corrupt%-") then found = name end
    end
    ok(found ~= nil, "...the damaged file was kept, not deleted")
    eq(bog.util.read_file(dir .. "/" .. found), "GARBAGE", "...byte for byte")

    -- doctor sees the quarantined file and the healthy new store.
    local r3 = sys.exec(string.format(
      "env -u ANTHROPIC_API_KEY BOGGART_HOME=%q ANTHROPIC_API_KEY=x ./boggart doctor 2>&1", dir), 60)
    ok(r3.out:find("quarantined", 1, true) ~= nil, "doctor lists the quarantined store")
    ok(r3.out:find("integrity    ok", 1, true) ~= nil, "...and the new one is sound")
  end

  -- ---- an occupied or unwritable data directory ---------------------------
  do
    local afile = ROOT .. "/a-file-not-a-dir"
    bog.util.write_file(afile, "x")
    local r = run("BOGGART_HOME=" .. string.format("%q", afile), "--eval " .. string.format("%q", probe))
    ok(r.code ~= 0, "a data directory that is a file stops the program")
    ok(r.out:find(afile, 1, true) ~= nil, "...naming the path")
    ok(r.out:find("not a directory", 1, true) ~= nil, "...and what is wrong with it")
    ok(r.out:find("traceback") == nil, "...with no traceback")
    ok(r.out:find("boggart doctor", 1, true) ~= nil, "...and points at `boggart doctor`")

    -- doctor itself must survive the same install and diagnose it.
    local d = sys.exec(string.format("env BOGGART_HOME=%q ./boggart doctor 2>&1", afile), 60)
    ok(d.code ~= 0, "doctor exits non-zero on a broken install")
    ok(d.out:find("not a directory", 1, true) ~= nil, "...having diagnosed the same thing")
    ok(d.out:find("traceback") == nil, "...and it never tracebacks either")
  end

  if can_be_denied(ROOT) then
    local ro = ROOT .. "/readonly_home"
    sys.mkdir_p(ro)
    sys.chmod(ro, 0x140) -- 0500
    local target = ro .. "/boggart"
    local r = run("BOGGART_HOME=" .. string.format("%q", target), "--eval " .. string.format("%q", probe))
    ok(r.code ~= 0, "an uncreatable data directory stops the program")
    ok(r.out:find(target, 1, true) ~= nil, "...naming the directory")
    ok(r.out:find("traceback") == nil, "...with no traceback")
    local d = sys.exec(string.format("env BOGGART_HOME=%q ./boggart doctor 2>&1", target), 60)
    ok(d.code ~= 0, "doctor exits non-zero for it too")
    sys.chmod(ro, 0x1C0)
  end

  -- ---- doctor's verdict tracks reality ------------------------------------
  do
    local dir = ROOT .. "/healthy"
    local envs = "BOGGART_HOME=" .. string.format("%q", dir)
    run(envs, "--eval " .. string.format("%q", probe))

    local broke = sys.exec(string.format("env -u ANTHROPIC_API_KEY BOGGART_HOME=%q ./boggart doctor 2>&1", dir), 60)
    ok(broke.code ~= 0, "no credentials at all counts as broken")
    ok(broke.out:find("cannot reach a model", 1, true) ~= nil, "...and says why in one sentence")

    local fine = sys.exec(string.format(
      "env BOGGART_HOME=%q ANTHROPIC_API_KEY=sk-ant-test-0123456789 ./boggart doctor 2>&1", dir), 60)
    eq(fine.code, 0, "a healthy, credentialed install exits 0")
    ok(fine.out:find("Everything checks out", 1, true) ~= nil, "...and says so")
    ok(fine.out:find("from ANTHROPIC_API_KEY in the environment", 1, true) ~= nil,
       "...naming where the credential came from")
    ok(fine.out:find("OVERRIDES", 1, true) ~= nil,
       "...and warning that the environment beats the stored file")
    ok(fine.out:find("sk%-ant%-test%-0123456789") == nil, "doctor never prints the key itself")
  end

  -- ---- the subcommand is discoverable -------------------------------------
  do
    local r = sys.exec("./boggart --help 2>&1", 30)
    eq(r.code, 0, "--help exits 0")
    ok(r.out:find("boggart doctor", 1, true) ~= nil, "--help mentions doctor")
    ok(r.out:find("BOGGART_HOME", 1, true) ~= nil, "--help documents BOGGART_HOME")
  end
end

-- ---- cleanup ---------------------------------------------------------------
if bog.db then bog.db:close(); bog.db = nil end
bog.userdir = ROOT
sys.rmtree(ROOT)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
