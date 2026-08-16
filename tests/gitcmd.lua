-- gitcmd.lua -- the common-git slash commands (lua/gitcmd.lua): run git
-- directly, fall back to the model only on failure. sys.exec is stubbed so the
-- decision logic is tested without touching a real repo.
local gitcmd = require("gitcmd")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

-- stub sys.exec: the next result is scripted per test
local real_exec = sys.exec
local scripted = { out = "", code = 0 }
local last_cmd = nil
sys.exec = function(cmd) last_cmd = cmd; return scripted end -- luacheck: ignore

local function script(out, code) scripted = { out = out, code = code } end

-- status / diff are read-only -> always { text = ... }
script("## main\n M foo.lua", 0)
eq(gitcmd.run("status").text, "## main\n M foo.lua", "status returns git output as text")
script("", 0)
eq(gitcmd.run("diff").text, "(no unstaged changes)", "diff on a clean tree says so")

-- commit WITH a message: success -> text; failure -> model fallback
script("[main abc123] tidy up\n 1 file changed", 0)
local c = gitcmd.run("commit", "tidy up")
ok(c.text and c.text:find("tidy up"), "commit with message + success -> text")
ok(last_cmd:find("git add %-A") and last_cmd:find("commit %-m"), "commit stages all then commits")
script("nothing to commit, working tree clean", 1)
local cf = gitcmd.run("commit", "tidy up")
ok(cf.run and cf.run:find("failed") and cf.run:find("tidy up"),
   "commit failure -> { run } with the error and the intended message")

-- commit with NO message: straight to the model to write one
local cn = gitcmd.run("commit", "")
ok(cn.run and cn.run:find("commit message"), "commit without a message asks the model to write one")

-- push: success -> text; failure -> model fallback
script("Everything up-to-date", 0)
ok(gitcmd.run("push").text:find("pushed"), "push success -> text")
script("! [rejected] main -> main (fetch first)", 1)
local pf = gitcmd.run("push")
ok(pf.run and pf.run:find("rejected") and pf.run:find("upstream"),
   "push failure -> { run } handing the rejection to the agent")

-- sync failure -> model fallback
script("CONFLICT (content): Merge conflict in x", 1)
ok(gitcmd.run("sync").run:find("Resolve"), "sync failure -> { run } for conflict resolution")

-- unknown command
eq(gitcmd.run("nope"), nil, "an unknown git command returns nil")

sys.exec = real_exec -- luacheck: ignore

io.write(string.format("gitcmd: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
