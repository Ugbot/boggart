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

-- ---- one shared, stable head (prefix caching) -------------------------------
-- Providers that cache by exact prompt prefix (vLLM, SGLang, llama.cpp, and
-- Anthropic's breakpoints) only share work up to the first differing byte. A
-- coordinator and its children must therefore start with the same bytes, and
-- the role- and turn-specific parts must come after.
local function concat(blocks, upto)
  local parts = {}
  for i = 1, (upto or #blocks) do parts[#parts + 1] = blocks[i].text end
  return table.concat(parts)
end
local function head_end(blocks)
  -- the head is everything up to and including the first cache breakpoint
  for i, b in ipairs(blocks) do if b.cache_control then return i end end
end

local coord = prompt.agent_system({ may_spawn = true,
  sys_override = "You are the coordinator for a refactor." })
local child = prompt.agent_system({ may_spawn = false,
  instructions = "## reviewer\nOnly real defects." })
local plain = prompt.agent_system(nil)

local hc, hk, hp = head_end(coord), head_end(child), head_end(plain)
ok(hc and hk and hp, "every agent's system carries a head breakpoint")
local head = concat(coord, hc)
ok(head == concat(child, hk) and head == concat(plain, hp),
   "coordinator, child and plain agent share the head byte-for-byte")
ok(concat(coord):sub(1, #head) == head and concat(child):sub(1, #head) == head,
   "the shared head is a byte prefix of each agent's full system text")
ok(coord[1].text == prompt.discipline(), "the head opens with the discipline block")
ok(not head:find("boggart swarm", 1, true) and not head:find("# Memory", 1, true)
   and not head:find("# Where you are", 1, true),
   "the head carries no role-specific or per-turn text")

-- role-specific parts come after the head, per-turn parts last
local function index_of(blocks, needle)
  for i, b in ipairs(blocks) do if b.text:find(needle, 1, true) then return i end end
end
local swarm_i = index_of(coord, "boggart swarm")
local over_i = index_of(coord, "coordinator for a refactor")
local mem_i = index_of(coord, "# Memory (durable")
local place_i = index_of(coord, "# Where you are")
ok(swarm_i and swarm_i > hc, "the swarm preamble sits after the head")
ok(over_i and over_i > hc, "sys_override sits after the head")
local skills_i = index_of(child, "# Skills")
ok(skills_i and skills_i > hk, "skills sit after the head")
ok(mem_i and place_i and mem_i > over_i and place_i == #coord,
   "memory follows the role parts and place is last")
for _, b in ipairs({ swarm_i, over_i }) do
  ok(b < mem_i, "role part precedes the per-turn parts")
end

-- the role part may carry a second 1h breakpoint; Anthropic allows four in
-- all (the request's automatic breakpoint is one), and every 1h breakpoint
-- must precede the 5m one, which sits on the conversation.
local marks = 0
for i, b in ipairs(coord) do
  if b.cache_control then
    marks = marks + 1
    ok(b.cache_control.ttl == "1h", "system breakpoints are 1h")
    ok(i < mem_i, "no breakpoint on a per-turn block")
  end
end
ok(marks >= 1 and marks <= 2, "one or two system breakpoints")

-- two consecutive builds of one agent's system are identical in the head and,
-- with nothing changed in between, in full: no timestamps, counters or live
-- status leak in.
local again = prompt.agent_system({ may_spawn = true,
  sys_override = "You are the coordinator for a refactor." })
ok(concat(again, head_end(again)) == head, "consecutive builds produce the same head")
ok(concat(again) == concat(coord), "consecutive builds produce the same system text")

-- the wire bodies keep the shape: Anthropic keeps the blocks (and breakpoints)
-- in order, OpenAI-compatible flattens them so the head is the string prefix.
local api = require("api")
local function body(sys)
  return { model = "claude-sonnet-5", max_tokens = 100, system = sys,
           messages = { { role = "user", content = "hi" } } }
end
local ab = api._body_for_wire("anthropic", body(coord))
ok(ab.system == coord or concat(ab.system) == concat(coord),
   "anthropic body carries the system blocks unchanged")
local seen_marks, last_ttl_rank = 0, 0
for _, b in ipairs(ab.system) do
  if b.cache_control then
    seen_marks = seen_marks + 1
    local rank = (b.cache_control.ttl == "1h") and 1 or 2
    ok(rank >= last_ttl_rank, "breakpoints in valid TTL order (1h before 5m)")
    last_ttl_rank = rank
  end
end
ok(ab.cache_control and ab.cache_control.ttl == nil,
   "the conversation breakpoint is the request's automatic 5m one")
ok(seen_marks + 1 <= 4, "at most four breakpoints in all")
local oc = api._body_for_wire("openai", body(coord))
local ok2 = api._body_for_wire("openai", body(child))
ok(oc.messages[1].role == "system" and oc.messages[1].content:sub(1, #head) == head
   and ok2.messages[1].content:sub(1, #head) == head,
   "openai system string: coordinator and child share the head as a prefix")

io.write(string.format("prompt: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
