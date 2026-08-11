-- studio.lua -- the studio's Lua actually compiles.
--
-- Written after a read-only-for-loop-variable slip in agentview.lua took the
-- whole window down: the app came up, core.studio failed to load, and the only
-- symptom was an editor with no agent in it. A compile error in a UI file is
-- not a subtle bug, but it is an invisible one -- nothing else in the suite
-- loads these files, and the app funnels the error into a log view that nobody
-- reads in CI. loadfile() catches the whole class in milliseconds, headlessly,
-- on every platform.
--
-- This checks that they compile, not that they work: these modules need a
-- window and a running editor to do anything at all. Behaviour is covered by
-- `ninja ui-check`, which renders a real frame and therefore cannot run here.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- Tests run from the build directory, so find the source tree from this file.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]+$") or "."
local root = here:match("^(.*)[/\\][^/\\]+$") or "."

local dirs = {
  root .. "/studio/data/core",
  root .. "/studio/data/core/commands",
  root .. "/studio/data/core/doc",
  root .. "/studio/data/plugins",
}

local files = {}
for _, dir in ipairs(dirs) do
  for _, name in ipairs(sys.listdir(dir) or {}) do
    if name:match("%.lua$") then files[#files + 1] = dir .. "/" .. name end
  end
end

ok(#files > 20, "found the studio's Lua (" .. #files .. " files)")

for _, path in ipairs(files) do
  local fn, err = loadfile(path)
  local short = path:sub(#root + 2)
  ok(fn ~= nil, "compiles: " .. short .. (fn and "" or ("  -- " .. tostring(err))))
end

-- The pieces the app cannot start without, named so that a rename losing one
-- fails here rather than at launch.
for _, must in ipairs {
  "studio/data/core/init.lua",
  "studio/data/core/agentview.lua",
  "studio/data/core/sidebarview.lua",
  "studio/data/core/studio.lua",
  "studio/data/core/widgets.lua",
  "studio/data/core/recipes.lua",
  "studio/data/core/diff.lua",
  "studio/data/core/rootview.lua",
} do
  ok(loadfile(root .. "/" .. must) ~= nil, "present and compiles: " .. must)
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
