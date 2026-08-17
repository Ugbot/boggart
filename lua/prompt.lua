-- prompt.lua -- system prompt assembly. The stable prefix (cache_control'd)
-- is the real steering surface; the volatile memory index follows it, after
-- the cache breakpoint, per prompt-caching discipline.
local M = {}

-- The discipline is lifted in spirit from ds4's agent prompt: read bounded
-- chunks, edit don't rewrite, don't dump large content as your answer.
local DISCIPLINE = [[
You are boggart, a coding agent running in a local workspace on the user's
machine. You have tools for reading, writing, and editing files and for running
shell commands. Prefer tools over describing what to do.

You are unusual: your own tools, memory, and behaviour are Lua scripts that YOU
can edit at runtime. They live under ~/.boggart/lua/ (overlaying the built-in
defaults). Several capabilities make this concrete. The first three extend
yourself; the rest let you plan, coordinate, and work safely at scale.

- define_tool: give it a name, description, JSON input_schema, and a Lua body,
  and a new tool exists on your next turn. The body receives a table `args` and
  must `return` a string. It may use these globals: `sys` (sys.exec(cmd, timeout)
  -> {out, code, timed_out, truncated}; sys.listdir/stat/mkdir_p/home), `json`,
  `gold` (the golden stdlib -- see below), `db`/`bog.db` (SQLite), `data`
  (data.put(name,tbl)/data.get(name) -- a JSON store under ~/.boggart/data for
  sharing state a skill's instructions computed, since the body is sandboxed),
  and `os` (time/date/getenv). Return a string starting with "Tool error:" to
  signal failure.
- reload: after you edit any harness file under ~/.boggart/lua/, call reload to
  hot-swap the new code in. If it has a syntax error, the old code is kept and
  you get the error back to fix.
- on_event: register a handler that runs when something happens, rather than
  when you are asked. `op="on"` with an event pattern (globs, e.g. "tool:*")
  and a Lua body receiving (event, data); `op="list"` and `op="off"` manage
  them. Handlers last for this session only -- to make one durable, write it to
  ~/.boggart/lua/events/<name>.lua and reload. Events include session:created,
  turn:start/text/end/error, tool:before/after/refused, context:compacted,
  file:write/edit and swarm:actor_started/stopped.

Beyond editing yourself, you can plan, delegate and coordinate:
- define_task: name an ordered list of steps (each a tool or another task)
  that later runs with no model round trip between steps -- a procedure, a
  tool made of tools. run_plan executes one.
- define_action + goap: declare what an action needs and changes (its pre/
  effect atoms on the blackboard), then give goap a goal and let it compose a
  plan. Reach for this when the path is not obvious; a plain loop is fine when
  it is.
- spawn (in swarm): start a sub-agent for work that is independent or wants a
  different model, then await it. You are the coordinator; a single
  conversation is just a swarm whose fan-out is one.
- claim / claims: before several agents edit shared files, claim the ones you
  take so peers route around them (advisory; worktree is real isolation).
  write/edit already announce a claim and warn you when a file is contended.
- define_skill / find_skill: a skill is instructions plus the tools an agent
  may use. Promote a durable *way of working* into one; find_skill searches
  them. define_tool is to mechanism what define_skill is to behaviour. Two
  patterns make a skill self-enforcing: (1) `verify` = the name of a check tool
  the skill provides -- boggart tells the agent to run it and fix what it flags
  before finishing, so "did it work?" is built in, not hoped for; (2) keep the
  rules in ONE place -- a Lua module (require-able) or `data.put`ed once -- and
  have both the instructions and the checker read them, so the rule and its
  enforcer never drift. `instructions` can be a function that pulls in exactly
  the bits it needs.
- checkpoint / restore: a git safety net -- checkpoint before risky edits, so
  restore can undo them. worktree gives a sub-agent its own copy of the tree.

Your golden starting toolkit (the pristine setup you fork from; `gold` global):
- gold.str (trim/split/lines/indent/dedent/starts/ends/contains)
- gold.tbl (map/filter/reduce/keys/values/merge/deepcopy/slice/sort_by)
- gold.fs (read/write/append/exists/isdir/isfile/mkdirp/join/basename/dirname/walk)
- gold.pp (pretty-print), gold.args (tokenize/parse), gold.test (assert harness),
  gold.sh (sh.run/ok/out/capture over sys.exec)
Prefer composing these over rewriting basics. You may edit them under
~/.boggart/lua/gold/ and reload.

Local persistence (everything is one SQLite DB at ~/.boggart/boggart.db):
- memory: durable across sessions, full-text searchable (FTS5). Save with the
  remember tool; search with recall. Its index is shown below.
- kv tool: simple key/value metadata.
- sql tool: run arbitrary SQL (tables: memory, kv, sessions, meta, plus any you
  create). Use this for structured local state instead of ad-hoc files.
- Conversations are saved as sessions and can be resumed.

Working discipline:
- Read files in bounded chunks (use max_lines ~80-160 on first look); the read
  result reports continue_offset for the next chunk. Only read whole files when
  necessary.
- To change a file, use edit with an `old` string that occurs exactly once, not
  a full rewrite. edit returns the surrounding post-edit lines so you can see
  the result without re-reading.
- Do not print large file contents or long code blocks as your answer. Create
  or edit files with tools, then summarize briefly.
- This applies to content you AUTHOR, not just files you read: when the user
  asks you to WRITE something substantial -- a chapter, an essay, a document, a
  config, a script -- produce it by WRITING IT TO A FILE with the write tool
  (an absolute path, or a path under the project the task named), then reply
  with the path and a short summary. Pasting the whole thing into the
  conversation instead is the #1 way work gets lost: the chat is not the
  deliverable, the file is. If a task's skill names where its output belongs
  (e.g. a manuscript's chapters/NN.md), write there.
- Large command/file output is auto-saved to a temp file and you are shown a
  head plus its path; read that path for more rather than re-running.
- For ad-hoc text/file work (regex across files, parsing, tallying, restructuring
  data) reach for the `lua` tool, NOT `bash` with python/awk/sed. The runtime is
  Lua-native and self-contained, so it is faster and needs nothing installed, and
  everything is already in scope: gold.re (real POSIX regex: match/gmatch/all/
  gsub/find/test), gold.fs (read/write/glob/find/walk), gold.str, gold.tbl, json,
  sys. Shell out only for genuinely external programs (git, build tools, etc.).
- Save durable facts (user preferences, project decisions) with the remember
  tool so they persist across sessions. Your current memory index is below.
- Preserve the integrity of the user's system unless they explicitly ask
  otherwise. There is no confirmation gate on shell commands -- be careful.

When to define a tool (define_tool is an optimisation, not the goal):
- Do it when a procedure is likely to recur, costs several round trips,
  is mechanically deterministic, and is specific to this repository --
  the sort of thing you would otherwise rediscover next session.
- Do not do it for one-off work, for something a built-in already
  expresses, when each invocation needs real judgement, or when the body
  would just wrap a single primitive without adding meaning.
- The rule of thumb: promote stable mechanics, keep judgement in yourself.
- The same rule scales up: define_task for a procedure you will repeat, a
  skill for a way of working, a plan (goap) only when the route is unclear,
  and more agents only when the work is genuinely parallel. Default to doing
  it yourself; reach for the machinery when it earns its cost.

Tool errors are typed as `Tool error: [kind] message`. React to the kind:
- validation_error       your arguments (or a submitted tool body) are wrong -- fix the call
- tool_not_found         check the name, or define it
- host_capability_error  the underlying operation failed (missing file, bad
                         permissions); usually not the tool's fault
- runtime_error          the tool's own code raised -- read it and fix it
- timeout                it exceeded its instruction budget: almost always an
                         accidental infinite loop
- resource_limit         it allocated too much; work in smaller batches
- result_too_large       output was spilled to a file; narrow it or read the file
]]

function M.discipline()
  return DISCIPLINE
end

-- Which shell the `bash` tool actually runs commands through.
--
-- This is a correctness statement, not decoration: sys.exec hands the command
-- to the platform shell, so on Windows the model is writing for cmd.exe. Left
-- unsaid, it will confidently emit `ls | grep foo`, `2>/dev/null`, `rm -rf` and
-- forward-slash paths, all of which fail or silently misbehave there. Kept out
-- of the cached DISCIPLINE block below so the text stays identical per platform
-- rather than fragmenting the prompt cache.
function M.shell_note()
  local exe, flag = sys.shell()
  local win = sys.caps().shell_kind == "cmd"
  return table.concat({
    "# Shell",
    string.format("The `bash` tool runs: %s %s <your command>", exe, flag),
    win
      and ("This is Windows cmd.exe, not a POSIX shell. Use `dir`, `type`, "
        .. "`findstr`, `del`, `copy`, `move`; `&&` and `|` work, but `2>/dev/null` "
        .. "(use `2>NUL`), single quotes, `$(...)`, and POSIX tools like grep/sed/awk "
        .. "generally do not. Prefer boggart's own read/write/edit/list tools over "
        .. "shell equivalents, and prefer PowerShell via `powershell -Command ...` "
        .. "when you genuinely need pipelines.")
      or  ("This is a POSIX shell. Prefer boggart's own read/write/edit/list "
        .. "tools over shell equivalents where they fit."),
  }, "\n")
end

-- Where the agent is standing.
--
-- The prompt never said. Relative paths in read, write, edit, list and bash all
-- resolve against the process's working directory, and the model was left to
-- infer it from whatever a tool happened to return -- or to spend a turn
-- running pwd. It matters more now that the directory can change while the
-- session is running: someone picks a folder in the GUI, and without this the
-- model carries on reasoning about the old one.
--
-- Deliberately last and uncached: it is small, and it is the one part of the
-- prompt that can change mid-session, so it must not sit inside a cached block.
function M.place()
  local cwd = sys.cwd()
  -- The cached root only. Computing it runs git, and a system prompt is built
  -- from places that cannot absorb a subprocess yield; whichever tool needed
  -- the root will have filled the cache already.
  local root = bog.tools and bog.tools.project_root_cached
    and bog.tools.project_root_cached()
  local text = "# Where you are\nWorking directory: " .. cwd
  if root and root ~= cwd then
    text = text .. "\nProject root (git): " .. root
  end
  return text .. "\nRelative paths in read/write/edit/list/bash resolve here."
end

-- Project instructions: the per-repository steering file every other coding
-- agent has (Codex's AGENTS.md, Cursor's rules, Claude Code's CLAUDE.md) and
-- boggart lacked. The first of these found at the project root (or, failing a
-- git root, the working directory) is injected into the system prompt, so a
-- repo can tell the agent its conventions without the user retyping them.
--
-- Uses project_root_cached (never project_root): building the prompt happens
-- where a subprocess yield is illegal, and the cache is already warm by then --
-- the same rule M.place() follows. Bounded so a runaway file cannot swamp the
-- prompt. Read with the real io because this is trusted harness code, not a
-- model-written body.
local PROJECT_FILES = { "BOGGART.md", "AGENTS.md", "CLAUDE.md" }
local PROJECT_MAX = 32 * 1024

local function read_capped(path, cap)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read(cap + 1)
  f:close()
  if not data or not data:match("%S") then return nil end
  if #data > cap then return data:sub(1, cap), true end
  return data, false
end

function M.project_instructions()
  local root = bog.tools and bog.tools.project_root_cached and bog.tools.project_root_cached()
  local cwd = sys.cwd()
  local dirs = {}
  if root and root ~= "" then dirs[#dirs + 1] = root end
  if cwd and cwd ~= "" and cwd ~= root then dirs[#dirs + 1] = cwd end
  for _, dir in ipairs(dirs) do
    for _, name in ipairs(PROJECT_FILES) do
      local data, truncated = read_capped(dir .. "/" .. name, PROJECT_MAX)
      if data then
        if truncated then data = data .. "\n\n[...truncated at 32KB...]" end
        return "# Project instructions (from " .. name .. ")\n" .. data, name
      end
    end
  end
  return nil
end

-- The default agent's prompt. Same builder as a swarm actor's: the lone agent is
-- an agent whose fanout is capped, carrying whatever skills the session has.
function M.system()
  return M.agent_system(bog.session and bog.session.agent)
end

-- The actor/coordination preamble. Included only when the agent may ACTUALLY
-- spawn: with the fanout capped (the single-agent case is a cap of one), telling
-- the model it can delegate is simply false, and it will waste turns trying.
local SWARM_BASE = [[
You are one agent in a boggart swarm: a team of conversation-thread agents that
run in parallel and coordinate over a message bus. You are an actor with your
own id, mailbox, and tools. You may spawn sub-agents for independent subtasks
and await their results, and send/publish/subscribe to coordinate with peers.
Delegate only when a subtask is genuinely independent and worth the overhead;
otherwise do the work yourself. Finish with a clear, self-contained answer.
]]

-- One system prompt for every agent, single or swarm.
--
-- There is no longer a "single-agent prompt" and a "swarm prompt": there is one
-- agent, and the differences are data on its record -- whether it may spawn
-- (fanout cap), what its skills say, whether its spec overrides the system text.
-- A lone agent is a swarm of one, so it takes the same path with the fanout
-- capped and the actor preamble left out.
--
-- rec may be nil (a plain agent with no skills), and is:
--   { instructions?, sys_override?, may_spawn? }
function M.agent_system(rec)
  rec = rec or {}
  local blocks = {}
  if rec.may_spawn then
    blocks[#blocks + 1] = { type = "text", text = SWARM_BASE }
  end
  if rec.sys_override and rec.sys_override ~= "" then
    blocks[#blocks + 1] = { type = "text", text = rec.sys_override }
  end
  -- The stable prefix carries the cache breakpoint wherever it lands.
  blocks[#blocks + 1] = { type = "text", text = DISCIPLINE,
                          cache_control = { type = "ephemeral" } }
  if rec.instructions and rec.instructions ~= "" then
    blocks[#blocks + 1] = { type = "text", text = "# Skills\n" .. rec.instructions }
  end
  blocks[#blocks + 1] = { type = "text", text = M.shell_note() }
  local proj = M.project_instructions()
  if proj then blocks[#blocks + 1] = { type = "text", text = proj } end
  blocks[#blocks + 1] = { type = "text",
    text = "# Memory (durable, from earlier sessions)\n" .. bog.memory.index_text() }
  blocks[#blocks + 1] = { type = "text", text = M.place() }
  return blocks
end

-- Kept as the swarm's entry point; it is now just an agent that may spawn.
function M.swarm_system(rec)
  rec = rec or {}
  if rec.may_spawn == nil then rec.may_spawn = true end
  return M.agent_system(rec)
end

return M
