-- prompt.lua -- the project-instructions file loader (lua/prompt.lua): the
-- per-repo steering file (BOGGART.md / AGENTS.md / CLAUDE.md) injected into the
-- system prompt. Driven by pointing project_root_cached at a throwaway dir.
local prompt = require("prompt")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

local dir = os.tmpname() .. "_projinstr"
sys.mkdir_p(dir)
local function write(name, s) local f = assert(io.open(dir .. "/" .. name, "w")); f:write(s); f:close() end
local function rm(name) os.remove(dir .. "/" .. name) end

-- Point the project root at our throwaway dir for the duration.
local saved = bog.tools.project_root_cached
bog.tools.project_root_cached = function() return dir end

-- nothing present
ok(prompt.project_instructions() == nil, "no file -> nil")

-- AGENTS.md found and wrapped
write("AGENTS.md", "use tabs")
local text, name = prompt.project_instructions()
ok(text and text:find("use tabs") and name == "AGENTS.md", "finds AGENTS.md")
ok(text:find("Project instructions %(from AGENTS.md%)"), "titled header")

-- BOGGART.md wins the priority order
write("BOGGART.md", "native rules")
ok(select(2, prompt.project_instructions()) == "BOGGART.md", "BOGGART.md beats AGENTS.md")

-- capping
rm("BOGGART.md")
write("AGENTS.md", string.rep("x", 40 * 1024))
text = prompt.project_instructions()
ok(#text < 34 * 1024 and text:find("truncated"), "huge file capped with a marker")

-- whitespace-only ignored
rm("AGENTS.md")
write("BOGGART.md", "  \n\n ")
ok(prompt.project_instructions() == nil, "whitespace-only ignored")

-- system() includes the block only when a file exists
rm("BOGGART.md")
local function has_proj(blocks)
  for _, b in ipairs(blocks) do if b.text and b.text:find("Project instructions") then return true end end
  return false
end
ok(not has_proj(prompt.system()), "system() omits the block with no file")
write("AGENTS.md", "team conventions")
ok(has_proj(prompt.system()), "system() includes the block when present")

bog.tools.project_root_cached = saved
sys.rmtree(dir)

io.write(string.format("prompt: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
