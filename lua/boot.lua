-- boot.lua -- entry point run by the C core. Installs the overlay module
-- system, builds the `bog` app context, wires the harness, and dispatches on
-- boggart.mode. Everything here is itself overlay-able: edit ~/.boggart/lua/
-- boot.lua and restart, or edit the other modules and call reload.

-- Install the embedded-module fallback searcher FIRST, so require() can find
-- our baked-in modules (strict, json, ...) before anything else runs. The
-- userdir overlay is prepended to package.path a bit later, once bog exists.
table.insert(package.searchers, function(name)
  local src = boggart.embedded((name:gsub("%.", "/")))
  if not src then return "\n\tno embedded module '" .. name .. "'" end
  local chunk, err = load(src, "@embedded:" .. name)
  if not chunk then error(err) end
  return chunk
end)

local strict = require("strict")

-- ---- app context ----------------------------------------------------------
-- Declared as a real global (strict-friendly) so every module can reach it.
declare{ bog = {} }
bog.version = boggart.version
-- Where everything lives is decided in C (src/lsys.c, and see src/bogpaths.h
-- for why): $BOGGART_HOME, else an existing ~/.boggart, else the platform
-- location. Lua asks and does not infer. The one failure is having no home
-- directory at all, and it gets a sentence rather than a stack.
do
  local p, err = require("lifecycle").paths()
  if not p then
    io.stderr:write("boggart: ", err, "\n")
    return 1
  end
  bog.userdir = p.data
end
bog.mode = boggart.mode
bog.session = {
  model = boggart.model or "claude-opus-5",
  messages = {},
  max_tokens = 16000,
  compact_at = 400000,
}

-- How model-authored skill code (a skill's `provides` body) runs: "sandboxed"
-- (default -- the define_tool capability sandbox + instruction/memory budget) or
-- "full" (real Lua, full io/os/network, no budget). Built-in in-repo skills carry
-- trusted `run` functions regardless. Env sets the default; `/trust` flips it.
bog.skill_trust = (os.getenv("BOGGART_SKILL_TRUST") == "full") and "full" or "sandboxed"

-- ---- logging (kept tiny; ds4/lite both keep this modest) ------------------
local COL = { dim = "\27[2m", tool = "\27[36m", err = "\27[31m", reset = "\27[0m" }
local function isatty() return true end -- best-effort; ANSI is harmless if piped
function bog.log(msg)
  io.stderr:write(COL.dim, "· ", tostring(msg), COL.reset, "\n")
end
function bog.log_tool(name, input)
  -- one-line semantic preview of the call (ds4's two-layer idea, minimal form)
  local preview = ""
  if type(input) == "table" then
    local hint = input.command or input.path or input.query or input.name or input.title
    if hint then preview = ": " .. tostring(hint):gsub("\n", " "):sub(1, 80) end
  end
  io.write("\n", COL.tool, "» ", name, preview, COL.reset, "\n")
  io.flush()
end

-- ---- overlay module system -----------------------------------------------
-- Highest priority: ~/.boggart/lua/?.lua (the model's / user's edits). The
-- embedded fallback searcher was installed at the top of this file.
package.path = bog.userdir .. "/lua/?.lua;" .. bog.userdir .. "/lua/?/init.lua;" .. package.path

-- sys.exec used to be a fork/execl/poll/waitpid implementation in C. It is now
-- lua/proc.lua on the libuv loop: portable to Windows, and able to yield to the
-- cooperative scheduler instead of freezing it. Installed here under the old
-- name so every existing caller (api.lua's auth probe, gold.sh, the tests) is
-- unchanged, and lazily so a run that never shells out does not pay for
-- creating the loop.
--
-- Same contract as before: { out = <stdout+stderr>, code, timed_out, truncated }.
function sys.exec(cmd, timeout_sec)
  return require("proc").run(cmd, timeout_sec)
end

-- Universal error funnel (from lite's core.try): returns (ok, result_or_err)
-- and never lets a failure unwind past the caller.
function bog.try(fn, ...)
  local err
  local ok, res = xpcall(fn, function(msg)
    -- A diagnosed condition (no credentials, unreachable endpoint) is not a
    -- bug, and a traceback into embedded:api:74 tells the user nothing they
    -- can act on. Pass those through untouched so the caller can print the
    -- explanation on its own; keep the traceback for everything else, where
    -- it is the whole point.
    if type(msg) == "table" and msg.boggart_error then err = msg; return msg end
    err = tostring(msg) .. "\n" .. debug.traceback(nil, 2)
    return err
  end, ...)
  if ok then return true, res end
  return false, err
end

-- ---- wiring & hot reload ---------------------------------------------------
-- events is first: tools.lua and api.lua emit at load-independent points, and
-- putting it in the reload set means an edited ~/.boggart/lua/events.lua takes
-- effect like any other module. Registrations themselves survive the reload --
-- they live on bog.__events, not in the module (see lua/events.lua).
local CORE = { "events", "json", "util", "lifecycle", "store", "memory", "mcphost", "prompt", "tools", "api", "workers", "complete", "perm", "diff", "goal", "termrender", "telemetry", "sessionlog" }

local function wire()
  for _, m in ipairs(CORE) do package.loaded[m] = nil end
  bog.events = require("events")
  bog.json = require("json")
  bog.util = require("util")
  bog.lifecycle = require("lifecycle")
  bog.store = require("store")
  bog.memory = require("memory")
  bog.mcphost = require("mcphost")
  bog.prompt = require("prompt")
  bog.tools = require("tools")
  bog.api = require("api")
  bog.worker = require("workers")
  -- Coordination surfaces, so a front end can draw them and the scheduler can
  -- release an agent's claims when it exits. Reachable as tools already; on
  -- bog so Lua that is not the model can read them too.
  bog.claims = require("claims")
  bog.blackboard = require("blackboard")
  -- The completion engine. bog.complete is the *function* src/lterm.c calls on
  -- Tab (with the input up to the cursor); the module also owns /help's text and
  -- the command registry, so the three cannot drift.
  bog.complete = require("complete").complete
  -- repl_style is the highlighter policy src/lterm.c calls per keystroke; it and
  -- complete come from the same registry, so a command is completed and coloured
  -- from one source.
  bog.repl_style = require("complete").style
  -- Shared permission modes (auto/smart/manual/chat). The studio and the cTUI
  -- both call perm.policy_for so a mode means the same thing on every surface.
  bog.perm = require("perm")
  -- Run-until-a-goal: the supervisor that runs turns toward an objective until a
  -- done-check passes or the turn budget is spent.
  bog.goal = require("goal")
  -- Terminal transcript rendering (markdown, code, diffs) for the REPL's output.
  bog.termrender = require("termrender")
  -- Agent telemetry: the append-only span log + KPI scoreboard over the record
  -- envelope. A no-op until the store is open; instrumented from api.run_on.
  bog.telemetry = require("telemetry")
  -- Liveness watchdog: nudges an agent that burns tokens without acting. Armed
  -- by bog.activate_agents (the runtime the REPL/cTUI/swarm all go through).
  bog.watchdog = require("watchdog")
  -- Event-sourced session log (Phase 2 foundation): append/replay/fork over the
  -- record envelope, with a corruption-rejecting reducer.
  bog.sessionlog = require("sessionlog")
end

-- Session lifecycle (persisted in the SQLite store; bog.db survives reloads).
-- The session a turn actually runs on. In the cTUI/swarm the chat is a
-- coordinator agent with its OWN session (bog.swarm_root.session); in the studio
-- and the plain REPL it is bog.session. `/model`, `/auth model` and preset
-- switches must mutate THAT session -- otherwise the status bar (which reads the
-- persisted auth.model()) shows the new model while the request body keeps the
-- coordinator's stale one, and the API rejects the mismatch (HTTP 400).
function bog.active_session()
  local root = bog.swarm_root
  return (root and root.session) or bog.session
end
function bog.set_model(m)
  if not m or m == "" then return end
  local s = bog.active_session()
  if s then s.model = m end
  if bog.session then bog.session.model = m end   -- keep the default seed in sync
  if auth and auth.set then pcall(auth.set, "model", m) end  -- persist for restart / new agents
end

-- Starting a new conversation does NOT create a row.
--
-- It used to, and the result was a store full of empty sessions: every launch
-- of the REPL, every `/new`, every `boggart serve`, every studio "new session"
-- left a titleless, messageless row behind whether or not anyone typed
-- anything. The recents list filled up with nothing.
--
-- A session row now appears the moment there is something to put in it -- see
-- bog.ensure_session, which the first turn calls. studio/data/core/engine.lua
-- already worked this way and said so ("the studio creates no session until a
-- turn actually needs one"); this is the same rule everywhere else.
function bog.new_session()
  local S = bog.active_session()
  S.messages = {}
  S.title = nil
  S.id = nil
  if bog.session and bog.session ~= S then
    bog.session.id, bog.session.messages, bog.session.title = nil, S.messages, S.title
  end
  bog.events.emit("session:new", {})
end

-- The row, created on demand. Idempotent: a session that already has an id --
-- resumed, or already saved once -- is returned untouched, so callers can ask
-- for this freely at the start of any turn.
function bog.ensure_session(S)
  S = S or bog.active_session()
  if S.id then return S.id end
  if not (bog.store and bog.store.sess_create) then return nil end
  local okp, proj = pcall(require, "project")
  local ok, id = pcall(bog.store.sess_create, S.title, S.model,
                       okp and proj.current() or nil)
  if not ok or not id then return nil end
  S.id = id
  if bog.session and bog.session ~= S then bog.session.id = id end
  bog.events.emit("session:created", { id = id })
  return id
end

function bog.save_session()
  local S = bog.active_session()
  -- Nothing said, nothing stored. This is the other half of the lazy row: a
  -- session that was created (because a turn started) but then produced no
  -- messages must not be written back into existence either.
  if not S.messages or #S.messages == 0 then return end
  if not bog.ensure_session(S) then return end
  bog.store.sess_save(S.id, S.title, S.model, S.messages)
  bog.events.emit("session:saved", { id = S.id, count = #S.messages })
end
function bog.resume_session(id)
  local s = bog.store.sess_load(id)
  if not s then return false end
  local function apply(S)
    if not S then return end
    S.id = s.id
    S.title = s.title
    S.model = s.model or S.model
    S.messages = s.messages or {}
  end
  apply(bog.session)
  local active = bog.active_session()
  if active ~= bog.session then apply(active) end
  bog.events.emit("session:resumed", { id = s.id, count = #s.messages })
  return true
end

-- `--resume [id]`: continue where you left off. With an id, that session; bare,
-- the most recently updated one (sess_list is ORDER BY updated DESC). Loads it
-- into bog.session in place of a fresh one. Returns the resumed session, or nil
-- (flag not set, no sessions yet, or a bad id) so the caller can fall back to
-- bog.new_session().
function bog.resume_startup()
  if not boggart.resume then return nil end
  local id = boggart.resume_id and tonumber(boggart.resume_id)
  if not id then
    local recent = bog.store.sess_list(1)
    id = recent and recent[1] and recent[1].id
  end
  if id and bog.resume_session(id) then return bog.session end
  return nil
end

function bog.reload()
  local snap, snap_loaded = {}, {}
  for _, m in ipairs(CORE) do snap[m] = bog[m]; snap_loaded[m] = package.loaded[m] end
  local ok, err = bog.try(wire)
  if not ok then
    -- restore BOTH bog.* and package.loaded so "old code kept" is fully true
    for _, m in ipairs(CORE) do bog[m] = snap[m]; package.loaded[m] = snap_loaded[m] end
    return false, err
  end
  return true
end

-- ---- modes that don't need the API/harness --------------------------------
local function do_init()
  -- `init` is often the first command a new user runs, so it is also the first
  -- thing that can discover an unwritable or occupied data directory. Same
  -- diagnosis as a normal start rather than a silent mkdir failure followed by
  -- a confusing write error per file.
  local dok, derr = bog.try(require("lifecycle").ensure_dir, bog.userdir)
  if not dok then
    io.stderr:write("boggart: ", tostring(derr), "\n")
    return 1
  end
  local dir = bog.userdir .. "/lua"
  sys.mkdir_p(dir)
  local n = 0
  for _, name in ipairs(boggart.embedded_names()) do
    local src = boggart.embedded(name)
    local target = dir .. "/" .. name .. ".lua"
    local sub = target:match("^(.*)/[^/]+$")
    if sub then sys.mkdir_p(sub) end
    if sys.stat(target) == "file" then
      io.write("kept existing ", target, "\n")
    else
      bog.util = bog.util or require("util")
      bog.util.write_file(target, src)
      io.write("wrote ", target, "\n")
      n = n + 1
    end
  end
  io.write(string.format("boggart init: %d files materialized under %s\n", n, dir))
  return 0
end

local function do_reset()
  local target = boggart.reset_target or ""
  local dir = bog.userdir .. "/lua"
  if target == "" then
    -- sys.rmtree, not a `rm -rf` shell-out: there is no rm on native Windows,
    -- and interpolating a path into a shell command was never a good idea even
    -- where there is. The C side also refuses "/", "", "." and "..", and uses
    -- lstat so a symlink in the overlay dir is unlinked rather than followed.
    local ok, err = sys.rmtree(dir)
    if ok then io.write("removed overlay dir ", dir, "\n")
    else io.write("could not remove ", dir, ": ", tostring(err), "\n") end
  else
    local p = dir .. "/" .. target .. ".lua"
    os.remove(p)
    io.write("removed ", p, "\n")
  end
  return 0
end

-- ---- REPL ------------------------------------------------------------------
local function print_help()
  -- Generated from the command registry (lua/complete.lua) so /help, Tab
  -- completion and the dispatch below all describe the same set of commands.
  io.write(require("complete").help_text())
end

-- Compact, /until and anything else that yields the IO protocol cannot run on
-- the main thread. Already inside a coroutine we just call through.
local function drive(fn)
  bog.activate_agents()
  return bog.sched.drive(fn)
end

local function handle_command(line)
  local cmd, rest = line:match("^/(%S+)%s*(.*)$")
  if cmd == "help" then print_help()
  elseif cmd == "quit" or cmd == "exit" or cmd == "wq" or cmd == "sq" then return true
  elseif cmd == "tools" then
    io.write(bog.tools.report(rest ~= "" and { name = rest } or {}), "\n")
  elseif cmd == "doctor" then
    io.write((bog.lifecycle.doctor()))
  elseif cmd == "memory" then
    io.write(bog.memory.index_text(), "\n")
  elseif cmd == "sessions" then
    for _, s in ipairs(bog.store.sess_list(20)) do
      io.write(string.format("  %d  %s  %s\n", s.id,
        os.date("%Y-%m-%d %H:%M", s.updated), s.title or "(untitled)"))
    end
  elseif cmd == "resume" then
    local id = tonumber(rest)
    if id and bog.resume_session(id) then
      io.write("resumed session ", id, " (", tostring(#bog.active_session().messages), " messages)\n")
    else
      io.write("no such session: ", tostring(rest), "\n")
    end
  elseif cmd == "reload" then
    local ok, err = bog.reload()
    io.write(ok and "reloaded.\n" or ("reload failed:\n" .. err .. "\n"))
  elseif cmd == "trust" then
    -- /trust [sandboxed|full] -- how model-authored skill code runs.
    if rest == "full" or rest == "sandboxed" then
      bog.skill_trust = rest
      pcall(function() require("tools").materialize_skills() end) -- recompile at the new trust
      if rest == "full" then
        io.write(COL.err, "skill trust = FULL", COL.reset,
          ": model-authored skill code now runs with full io/os/network, no budget.\n")
      else
        io.write("skill trust = sandboxed (model skill code is capability-limited + budgeted).\n")
      end
    else
      io.write("skill trust = ", bog.skill_trust,
        "   (/trust full  |  /trust sandboxed)\n")
    end
  elseif cmd == "reset" then
    boggart.reset_target = rest ~= "" and rest or ""
    do_reset()
    bog.reload()
  elseif cmd == "auth" then
    local what, val = rest:match("^(%S*)%s*(.*)$")
    local MAP = { key = "api_key", url = "base_url", model = "model", wire = "wire" }
    if what == "" or what == "show" then
      -- Credentials live in C (src/lauth.c); the key is write-only from here,
      -- so this shows a mask the C side produces rather than the value.
      local masked, src = auth.masked()
      io.write("credentials (", auth.path(), ", chmod 0600):\n")
      io.write(string.format("  key    %s%s\n", masked,
        src == "environment" and "  (from ANTHROPIC_API_KEY)" or ""))
      io.write(string.format("  url    %s\n", auth.base_url() or "(unset)"))
      io.write(string.format("  model  %s\n", auth.model() or "(unset)"))
      io.write(string.format("  wire   %s\n", auth.wire() or "anthropic (default)"))
      io.write("environment overrides anything stored here.\n")
      io.write("  /auth key <k> | /auth url <u> | /auth model <m> | /auth wire <openai|anthropic|responses> | /auth clear [what]\n")
    elseif what == "clear" then
      if val ~= "" and MAP[val] then auth.clear(MAP[val]); io.write("cleared ", val, "\n")
      else auth.clear(); io.write("cleared all stored credentials\n") end
      bog.api.forget_auth()
    elseif what == "wire" and val ~= "" and val ~= "openai" and val ~= "anthropic" and val ~= "responses" then
      io.write("usage: /auth wire <openai|anthropic|responses>\n")
    elseif MAP[what] then
      if val == "" then io.write("usage: /auth ", what, " <value>\n")
      else
        auth.set(MAP[what], val)
        -- Headers are cached after the first request, so a credential set
        -- mid-session would otherwise not take effect until restart.
        bog.api.forget_auth()
        io.write("stored ", what, " = ", what == "key" and select(1, auth.masked()) or val, "\n")
        if what == "model" then bog.set_model(val) end
      end
    else
      io.write("usage: /auth [show] | /auth key <k> | /auth url <u> | /auth model <m> | /auth clear\n")
    end
  elseif cmd == "model" or cmd == "models" then
    -- The offered list: provider-table models + the running one + preset models,
    -- deduped and sorted, so you can pick by NUMBER.
    local function model_list()
      local seen, out = {}, {}
      local function add(m) if type(m) == "string" and m ~= "" and not seen[m] then seen[m] = true; out[#out + 1] = m end end
      -- The catalog first: it is where models live now, and a REPL that offered
      -- a different set from `boggart models` and the studio picker was the
      -- kind of inconsistency that makes an app feel unfinished.
      local okc, cat = pcall(require, "catalog")
      if okc then for _, m in ipairs(cat.models{}) do add(m.id) end end
      local ok, provs = pcall(bog.api.providers)
      if ok then for _, p in pairs(provs or {}) do for _, m in ipairs(p.models or {}) do add(m) end end end
      add(bog.api.status().model)
      local okp, ps = pcall(function() return require("presets").load() end)
      if okp then for _, p in pairs(ps or {}) do add(p.model) end end
      table.sort(out); return out
    end
    local list = model_list()
    -- `/models` (plural) is the CATALOG: providers, which of them you can
    -- actually use, and what each role points at -- the same three questions
    -- `boggart models` answers, because asking them from inside the REPL should
    -- not need a second program.
    if cmd == "models" then
      local okc, cat = pcall(require, "catalog")
      if okc then
        local roles = cat.roles()
        local rnames = {}
        for n in pairs(roles) do rnames[#rnames + 1] = n end
        table.sort(rnames)
        if #rnames > 0 then
          io.write("roles\n")
          for _, n in ipairs(rnames) do
            io.write(string.format("  %-12s %s\n", n, table.concat(roles[n], " -> ")))
          end
        end
        io.write("providers  (key = a credential is stored)\n")
        for _, p in ipairs(cat.providers()) do
          local keyed = auth.has_key and auth.has_key(p.key_slot or p.name)
          io.write(string.format("  %-14s %-9s %-4s %s\n",
            p.name, p.wire or "?", keyed and "key" or "-", p.url or ""))
        end
        io.write(string.format("\n%d models catalogued -- /model to switch, "
          .. "`boggart models refresh` to update\n", #cat.models{}))
      end
    elseif rest == "" then
      local cur = bog.api.status().model
      io.write("models (", #list, ") -- /model <n> to jump, or /model <name|preset>:\n")
      for i, m in ipairs(list) do
        io.write(string.format("  %2d. %s%s\n", i, m, (m == cur) and "   <- current" or ""))
      end
    else
      -- A NUMBER jumps to that entry; else a saved preset; else a raw model id.
      local n = tonumber(rest)
      if n and list[n] then bog.set_model(list[n])
      elseif require("presets").load()[rest] then
        require("presets").apply(rest); io.write("switched to preset '", rest, "'\n")
      else bog.set_model(rest) end
      local s = bog.api.status()
      local where = s.is_local and ("local  " .. s.host) or (s.provider .. "  (remote)")
      io.write(string.format("model     %s\nrunning   %s\nendpoint  %s\n", s.model, where, s.endpoint))
    end
  elseif cmd == "project" or cmd == "projects" then
    -- The unit of context: what boggart knows and where it works.
    -- docs/projects.md has the model; this is the door to it in the REPL and
    -- the cTUI (both take slash commands through the same registry).
    local proj = require "project"
    local sub, arg = rest:match("^(%S*)%s*(.*)$")

    if sub == "" or sub == "list" then
      local cur = proj.current()
      for _, p in ipairs(proj.list()) do
        local mark = (p.name == cur) and " <- current" or ""
        local where = (#p.roots > 0) and ("  " .. table.concat(p.roots, ", ")) or ""
        io.write(string.format("  %-16s %s%s\n", p.name, p.label or "", where .. mark))
      end
      if cur == proj.GLOBAL then
        io.write("\nin `global` -- loose chat, readable from every project.\n"
          .. "`/project new <name> [dir]` starts one; `/project <name>` switches.\n")
      end

    elseif sub == "new" then
      local name, dirs = arg:match("^(%S+)%s*(.*)$")
      if not name then io.write("usage: /project new <name> [dir ...]\n")
      else
        local roots = {}
        for d in (dirs or ""):gmatch("%S+") do roots[#roots + 1] = d end
        if #roots == 0 and dirs == "" then roots = { "." } end
        local p, err = proj.create(name, roots)
        if not p then io.write("cannot: ", tostring(err), "\n")
        else
          proj.switch(p.name)
          io.write("created and switched to '", p.name, "'",
            #p.roots > 0 and ("  roots: " .. table.concat(p.roots, ", ")) or "", "\n")
        end
      end

    elseif sub == "root" then
      local roots, err = proj.add_root(nil, arg ~= "" and arg or ".")
      if not roots then io.write("cannot: ", tostring(err), "\n")
      else io.write("roots: ", table.concat(roots, ", "), "\n") end

    elseif sub == "assign" then
      -- Move a chat into this project, retroactively.
      local id = tonumber(arg) or (bog.active_session() or {}).id
      if not id then io.write("usage: /project assign [session-id]\n")
      elseif bog.store.sess_assign(id, proj.current()) then
        io.write("session ", tostring(id), " -> ", proj.current(), "\n")
      else io.write("no session ", tostring(id), "\n") end

    elseif sub == "forget" then
      if arg == "" then io.write("usage: /project forget <memory title>\n")
      elseif bog.memory.forget(arg) then
        io.write("forgotten in ", proj.current(), ": ", arg, "\n")
      else io.write("no memory called '", arg, "' in ", proj.current(), "\n") end

    elseif sub == "promote" then
      if arg == "" then io.write("usage: /project promote <memory title>\n")
      elseif bog.memory.promote(arg) then
        io.write("promoted to global: ", arg, "\n")
      else io.write("no memory called '", arg, "' in this project\n") end

    elseif sub == "manifest" then
      if arg == "read" or arg == "check" then
        local rep, err = proj.reconcile_report()
        io.write(rep or ("no manifest: " .. tostring(err)), "\n")
      else
        local path, err = proj.write_manifest()
        if not path then io.write("cannot: ", tostring(err), "\n")
        else io.write("wrote ", path, "\n") end
      end

    elseif sub == "skill" then
      -- Key a skill to this project, so it travels in the manifest.
      if arg == "" then
        local sk = require("skills")
        for name, owners in pairs(sk.project_keys()) do
          io.write(string.format("  %-20s %s\n", name, table.concat(owners, ", ")))
        end
      else
        local list = require("skills").key_to_project(arg, proj.current())
        io.write(arg, " -> ", table.concat(list or {}, ", "), "\n")
      end

    elseif sub == "delete" or sub == "rm" then
      local moved, err = proj.delete(arg)
      if not moved then io.write("cannot: ", tostring(err), "\n")
      else io.write("deleted '", arg, "'; ", tostring(moved),
        " chat(s)/memory(ies) moved to global\n") end

    else
      local p, err = proj.switch(sub)
      if not p then io.write(tostring(err), "\n")
      else
        io.write("project: ", p.name,
          #(p.roots or {}) > 0 and ("  " .. table.concat(p.roots, ", ")) or "", "\n")
      end
    end

  elseif cmd == "endpoint" or cmd == "preset" then
    local sub, arg = rest:match("^(%S*)%s*(.*)$")
    local presets = require("presets")
    if sub == "" or sub == "list" then
      local names, t = presets.list()
      local cur = auth.base_url()
      io.write("endpoint presets (", #names, "):\n")
      for _, n in ipairs(names) do
        local p = t[n]
        io.write(string.format("  %-14s %-26s wire=%-9s model=%s%s\n", n,
          p.url or "(anthropic cloud)", p.wire or "anthropic", p.model or "?",
          (p.url == cur) and "  *" or ""))
      end
      if #names == 0 then io.write("  (none yet)\n") end
      io.write("  /endpoint save <name>   store the current url+wire+model\n")
      io.write("  /endpoint <name>        switch to it   |   /endpoint rm <name>\n")
    elseif sub == "save" then
      if arg == "" then io.write("usage: /endpoint save <name>\n")
      else
        local p = presets.put(arg)
        io.write(string.format("saved '%s' = %s  wire=%s  model=%s\n", arg,
          p.url or "(anthropic cloud)", p.wire, p.model or "?"))
      end
    elseif sub == "rm" or sub == "remove" or sub == "delete" then
      io.write(presets.remove(arg) and ("removed '" .. arg .. "'\n")
        or ("no such preset: " .. arg .. "\n"))
    else
      local p = presets.apply(sub)
      if p then
        bog.api.forget_auth()
        io.write(string.format("switched to '%s': %s  wire=%s  model=%s\n", sub,
          p.url or "(anthropic cloud)", p.wire or "anthropic", p.model or "?"))
      else
        io.write("no such preset: ", sub, "  (/endpoint list)\n")
      end
    end
  elseif cmd == "effort" then
    -- Reasoning effort for models that support it (deepseek, gpt-oss, o-series).
    -- Session-scoped; a preset can carry one so it restores on switch.
    -- minimal|low|medium|high everywhere; xhigh|max are Anthropic-only (Sonnet 5
    -- et al.) and clamp to high on the OpenAI/Responses wires.
    local LEVELS = { minimal = true, low = true, medium = true, high = true, xhigh = true, max = true }
    local v = rest:lower()
    if rest == "" then
      io.write("reasoning effort: ", tostring(bog.session.effort or "(server default)"),
        "\n  /effort <minimal|low|medium|high|xhigh|max>   (or 'none' to clear)\n")
    elseif v == "none" or v == "off" or v == "default" or v == "clear" then
      bog.session.effort = nil; io.write("effort cleared (server default)\n")
    elseif LEVELS[v] then
      bog.session.effort = v; io.write("effort -> ", v, "\n")
    else
      io.write("usage: /effort <minimal|low|medium|high|xhigh|max|none>\n")
    end
  elseif cmd == "agents" or cmd == "fleet" or cmd == "swarm" then
    -- Live fleet status. The scheduler's actors ARE the agents (the coordinator
    -- plus any spawned sub-agents); the store carries their title + model. When
    -- nothing is mid-turn there are no actors, which is the honest answer.
    local actors = (bog.sched and bog.sched.actors) or {}
    if #actors == 0 then
      io.write("no agents running.\n")
    else
      local meta = {}
      pcall(function()
        for _, r in ipairs(bog.store.thread_list(true) or {}) do meta[r.id] = r end
      end)
      -- io/proc/runnable = doing work (a request in flight or ready to run);
      -- recv = idle, waiting on a bus message. paused / approve? are user-gated.
      local WORKING = { io = true, proc = true, runnable = true }
      local nwork, nwait, npause, napprove = 0, 0, 0, 0
      local out = {}
      for _, a in ipairs(actors) do
        local ap = bog.approvals and bog.approvals.get and bog.approvals.get(a.id)
        local state
        if a.paused then state, npause = "paused", npause + 1
        elseif ap and ap.decision == nil then state, napprove = "approve?", napprove + 1
        elseif WORKING[a.status] then state, nwork = "working", nwork + 1
        else state, nwait = "waiting", nwait + 1 end
        local m = meta[a.id] or {}
        out[#out + 1] = string.format("  %-10s %-9s %-16s %s%s",
          tostring(a.id):sub(1, 10), state, tostring(m.model or "-"),
          m.title and ('"' .. tostring(m.title):gsub("%s+", " "):sub(1, 40) .. '"') or "",
          m.parent_id and ("  \u{2514} child of " .. tostring(m.parent_id):sub(1, 8)) or "")
      end
      io.write(string.format("agents: %d total  --  %d working, %d waiting, %d paused%s\n",
        #actors, nwork, nwait, npause,
        napprove > 0 and string.format(", %d awaiting approval", napprove) or ""))
      for _, line in ipairs(out) do io.write(line, "\n") end
    end
  elseif cmd == "kpis" then
    -- The reliability scoreboard for the active run: computed from the telemetry
    -- records, so "how good was that" is a number, not a vibe.
    local sess = (bog.active_session and bog.active_session()) or bog.session
    local k = bog.telemetry and sess and bog.telemetry.kpis(sess.id)
    if not k or ((k.turns or 0) == 0 and (k.agents or 0) == 0) then
      io.write("no telemetry recorded yet for this run.\n")
    else
      io.write(string.format("run %s: %d turns, %d tool-calls, %d output tokens%s\n",
        tostring(sess.id), k.turns or 0, k.tool_calls or 0, k.out_tokens or 0,
        k.think_output_ratio and string.format("  (think:output %.1f)", k.think_output_ratio) or ""))
      if k.cache_hit_rate then
        io.write(string.format("prompt cache: %.0f%% of prompt tokens from cache  (%d read, %d written, %d fresh)\n",
          100 * k.cache_hit_rate, k.cache_read or 0, k.cache_write or 0, k.in_tokens or 0))
      end
      if (k.agents or 0) > 0 then
        io.write(string.format("fleet: %d agents  --  %d delivered (%.0f%%), %d false-success, %s tokens/artifact\n",
          k.agents, k.delivered or 0, 100 * (k.deliverable_rate or 0), k.false_success or 0,
          k.tokens_per_artifact and string.format("%.0f", k.tokens_per_artifact) or "-"))
      end
      local d = k.decisions or {}
      if (d.allow or 0) + (d.deny or 0) > 0 then
        io.write(string.format("gated decisions: %d allowed, %d denied\n", d.allow or 0, d.deny or 0))
      end
    end
  elseif cmd == "trace" then
    -- Watch the fabric bus live: /trace [pattern]  (default "*"),  /trace off.
    local tr = require("trace")
    if rest == "off" or rest == "stop" then
      io.write(string.format("trace off -- %d event%s seen\n", tr.count(),
        tr.count() == 1 and "" or "s"))
      tr.stop()
    else
      local pat = (rest ~= "" and rest) or "*"
      local h, err = tr.start(pat)
      if h then io.write("tracing " .. pat .. " -- /trace off to stop\n")
      else io.write("trace: " .. tostring(err) .. "\n") end
    end
  elseif cmd == "fork" then
    -- Branch the active session: a new session seeded with a copy of this one's
    -- transcript, so you can explore a divergent path without disturbing the
    -- original. Recorded as an event-sourced lane (bog.sessionlog).
    local sess = (bog.active_session and bog.active_session()) or bog.session
    if not (sess and sess.messages) then
      io.write("nothing to fork.\n")
    else
      local title = "fork of " .. tostring(sess.title or sess.id or "session")
      local new_id = bog.store.sess_create(title, sess.model)
      pcall(bog.store.sess_save, new_id, title, sess.model, sess.messages)
      if bog.sessionlog then pcall(bog.sessionlog.append_all, new_id, new_id, sess.messages) end
      io.write(string.format("forked to session %s (%d message%s) -- resume it with /resume %s\n",
        tostring(new_id), #sess.messages, #sess.messages == 1 and "" or "s", tostring(new_id)))
    end
  elseif cmd == "until" or cmd == "react" then
    -- /until <task>                    -- run until the model judges it done
    -- /until <shell-check> :: <task>   -- run until the shell command exits 0
    -- /react is the same supervisor with ReAct-shaped prompts (Thought → Act →
    -- Observe). The inner turn is already that loop via tools; this is the
    -- outer one, with a budget.
    if rest == "" then
      io.write("usage: /" .. cmd .. " <task>   |   /" .. cmd .. " <shell-check> :: <task>\n")
    else
      local shell, task = rest:match("^(.-)%s*::%s*(.+)$")
      local spec = { task = task or rest, react = (cmd == "react"),
                     on_text = function(t) io.write(t); io.flush() end }
      if shell and shell ~= "" then spec.done = { shell = shell } end
      local r = drive(function() return bog.goal.run(spec) end)
      io.write(string.format("\n[goal %s after %d/%d turn(s)]\n",
        r.met and "met" or "not met -- budget spent", r.turns, r.budget))
      if not r.met and r.detail then io.write(tostring(r.detail):sub(1, 300), "\n") end
      bog.save_session()
    end
  elseif cmd == "status" or cmd == "diff" or cmd == "commit"
      or cmd == "push" or cmd == "sync" then
    -- Common git tasks as slash commands: run git directly, and only fall back
    -- to the model when it fails (see lua/gitcmd.lua). A { run = prompt } return
    -- asks the REPL/cTUI turn driver to hand the failure to the agent.
    local r = drive(function() return require("gitcmd").run(cmd, rest) end)
    if r and r.run then return { run = r.run } end
    if r and r.text and r.text ~= "" then io.write(r.text, "\n") end
  elseif cmd == "dispatch" then
    -- /dispatch [on|off] -- optional auto-routing: hand a request that is
    -- "different enough" to a specialist sub-agent (lua/dispatch.lua).
    if rest == "on" or rest == "off" then bog.dispatch.set(rest == "on") end
    io.write("auto-dispatch = ", bog.dispatch.enabled() and "on" or "off",
      "   (/dispatch on | /dispatch off)\n")
  elseif cmd == "new" then
    bog.new_session()
    if bog.clear_ui then pcall(bog.clear_ui) end
    io.write("started a new session.\n")
  elseif cmd == "clear" then
    local S = bog.active_session()
    if S then S.messages = {} end
    if bog.clear_ui then pcall(bog.clear_ui) end
    io.write("conversation cleared.\n")
  elseif cmd == "compact" then
    local S = bog.active_session()
    if not S or #(S.messages or {}) == 0 then
      io.write("nothing to compact.\n")
    else
      local okc, err = pcall(drive, function() return bog.api.compact(S, {}) end)
      if not okc then io.write("compaction failed: ", tostring(err), "\n")
      else
        local frac, used = bog.api.context_fraction(S)
        io.write(string.format("compacted -- now %d tokens (%.0f%%)\n",
          used or 0, (frac or 0) * 100))
      end
    end
  elseif cmd == "cost" then
    local S = bog.active_session()
    local frac, used = 0, 0
    pcall(function() frac, used = bog.api.context_fraction(S) end)
    local limit = bog.api.context_limit and bog.api.context_limit(S)
    local dollars
    if bog.api.cost then
      local okd, d = pcall(bog.api.cost, S)
      if okd then dollars = d end
    end
    local money = (dollars == nil) and "local (no per-token cost)"
      or string.format("$%.4f", dollars)
    io.write(string.format("context %s / %s tokens (%d%%) -- %s\n",
      tostring(used or "?"), tostring(limit or "?"),
      math.floor((frac or 0) * 100 + 0.5), money))
  elseif cmd == "copy" then
    local text = require("take").last_assistant()
    if text == "" then io.write("nothing to copy.\n")
    else
      if bog.copy_text then pcall(bog.copy_text, text) end
      io.write("copied last assistant reply (", #text, " bytes)\n")
    end
  elseif cmd == "mode" then
    local id = rest:match("^(%S*)") or ""
    if id == "" then
      local m = bog.perm.mode_at(bog.perm.state().mode)
      io.write("mode: ", m.id, " (", m.label, ") -- ", m.help, "\n")
      io.write("  /mode auto | smart | manual | chat\n")
    else
      local m, okm = bog.perm.set_mode(id)
      if not okm then io.write("unknown mode: ", id, "  (auto|smart|manual|chat)\n")
      else io.write("mode: ", m.label, " -- ", m.help, "\n") end
    end
  else
    -- A skill name as a slash command: hand its instructions to the agent as
    -- the next turn. Commands always win the name; see lua/complete.lua.
    local skill = bog.skills and bog.skills.load and bog.skills.load(cmd)
    if skill then
      local instr = skill.instructions
      if type(instr) == "function" then
        local ok, r = pcall(instr)
        instr = ok and r or skill.description
      end
      local prompt = "Follow the `" .. cmd .. "` skill.\n\n"
        .. tostring(instr or skill.description or "")
      if rest ~= "" then prompt = prompt .. "\n\n" .. rest end
      return { run = prompt }
    end
    io.write("unknown command: /", tostring(cmd), " (try /help)\n")
  end
  return false
end
-- Exposed so the cTUI can run the same slash commands the scrolling REPL does
-- (it captures the io.write output into the frame). Returns true for /exit|/quit.
bog.handle_command = handle_command

local function print_turn_error(ok, err)
  if ok then return end
  -- A boggart_error is already a complete, actionable explanation; do not prefix.
  local msg = (type(err) == "table" and err.boggart_error) and tostring(err)
    or ("error: " .. tostring(err))
  io.write(COL.err, msg, COL.reset, "\n")
end

local SPIN = { "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}",
               "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}" }

-- The status line repaints in place with a carriage return (\r) every ~120ms.
-- With the cursor visible that reads as a flicker -- it snaps to column 0 and
-- back on every tick. So we hide the cursor for the duration of a turn's
-- animation and restore it before the next prompt: the terminal's own cursor is
-- meaningless while output streams, and this is what every solid TUI does.
local CURSOR_HIDE, CURSOR_SHOW = "\27[?25l", "\27[?25h"

-- A persistent stdin TTY handle for in-turn control keys. Created once and
-- reused: closing a uv_tty bound to fd 0 can take the fd down with it, which
-- would leave isocline (the between-turns line editor) with nothing to read. So
-- it is only ever read_start/read_stop'd and mode-toggled, never closed.
local repl_input, repl_input_tried
local function control_input()
  if repl_input_tried then return repl_input end
  repl_input_tried = true
  local uv = require("uv")
  if uv.guess_handle(0) == "tty" then
    local ok, h = pcall(uv.new_tty, 0, true)
    repl_input = ok and h or nil
  end
  return repl_input
end

-- Display columns the scrolling REPL wraps printed output to. term.size() is
-- the live tty (or COLUMNS). On a real terminal a line that fills every column
-- plus a newline autowraps then advances -- a blank row between wrapped lines
-- -- so we keep one column spare. Pipes and logs wrap at the full width.
local function repl_wrap_width()
  local width = 80
  if term and term.size then
    local ok, w = pcall(term.size)
    if ok and w and w > 0 then width = w end
  end
  local tty = term and term.istty and term.istty()
  if tty and width > 1 then width = width - 1 end
  return width
end

-- Run a turn on the libuv loop rather than blocking in a read().
--
-- The old path called the blocking transport (stream_once): the whole process
-- sat in a socket read for the length of the turn, so a model that paused
-- mid-generation froze the REPL outright -- no activity, no clean Ctrl-C. Here
-- the turn is the (async) transport driven as a scheduler coroutine, so the uv
-- loop keeps running: tokens stream in as they arrive, a uv timer
-- animates a "thinking" indicator through the initial latency and any pause, and
-- the loop is alive to catch a signal. Tokens are streamed live (a scrolling
-- terminal cannot re-flow printed text, so live beats post-hoc rendering);
-- termrender stays wired into the cTUI, which repaints each frame.
-- text == nil resumes an interrupted turn (finish its tool round, then run on)
-- rather than starting a new one.
local function run_one_turn(text)
  local S = bog.active_session()
  if text and (not S.title or S.title == "") then S.title = text:gsub("%s+", " "):sub(1, 60) end
  -- The runtime, stood up once: the turn runs as a scheduler coroutine that can
  -- spawn a fleet of more, and the whole tree drains on the same uv loop.
  bog.activate_agents()
  local uv = require("uv")
  local tty = term and term.istty and term.istty()
  local myid = S.id or 1

  -- A single rewritable activity line at the cursor: "thinking" until the first
  -- token, then -- if the turn spawned a fleet -- the live roster of sub-agents,
  -- which shrinks as each finishes. Every token clears it first, so streamed
  -- text is never clobbered. This is the scrolling REPL's window onto the one
  -- swarm; the cTUI draws the same fleet as a pane. Sub-agents are just the
  -- scheduler's other actors -- there is no second bookkeeping.
  local started, si, turn_err, shown = false, 0, nil, false
  local abort, paused = false, false
  local function clear_status() if shown then io.write("\r\27[K"); shown = false end end

  -- Column width, read FRESH each turn (not cached at start-up) so a terminal
  -- resized between prompts -- or a COLUMNS override -- is honoured. term.size()
  -- asks the tty via TIOCGWINSZ and falls back to COLUMNS/80 (src/lterm.c).
  local width = repl_wrap_width()

  -- Assistant text is rendered through termrender at the real terminal width
  -- instead of echoed raw -- raw streaming dumped the model's markdown verbatim,
  -- so tables never aligned and code ran past the margin. But rendering does NOT
  -- mean buffering the whole turn: prose reflows fine line by line, so we stream
  -- BLOCK by block. A markdown block (paragraph, list, table, fenced code) ends
  -- at a blank line that is not inside a code fence; each completed block is
  -- rendered and printed as it arrives, so output appears live. Only multi-line
  -- constructs that need the whole block to lay out -- a table's columns, a
  -- fence's gutter -- are held back until their closing blank line, which is
  -- exactly what keeps them aligned. A partial line and any open block are
  -- flushed at a tool marker (rounds complete before their tools run, see
  -- api.run_on) and at turn end.
  local line_buf = ""    -- bytes of the current, not-yet-terminated source line
  local block = {}       -- completed source lines of the block being accumulated
  local in_fence = false
  local function render_block()
    if #block == 0 then return end
    local md = table.concat(block, "\n"); block = {}
    if tty then clear_status() end
    local ok, out = pcall(bog.termrender.assistant,
      { role = "assistant", text = md }, { width = width, color = tty })
    io.write(ok and out or md, "\n"); io.flush()
  end
  local function feed_line(line)
    if line:match("^%s*```") then in_fence = not in_fence; block[#block + 1] = line
    elseif not in_fence and line:match("^%s*$") then render_block()  -- blank => block end
    else block[#block + 1] = line end
  end
  local function on_delta(t)
    line_buf = line_buf .. t
    local nl = line_buf:find("\n", 1, true)
    while nl do
      feed_line(line_buf:sub(1, nl - 1))
      line_buf = line_buf:sub(nl + 1)
      nl = line_buf:find("\n", 1, true)
    end
  end
  local function flush_render()   -- emit any trailing partial line + open block
    if line_buf ~= "" then feed_line(line_buf); line_buf = "" end
    render_block()
  end

  local function status()
    local ids = {}
    if bog.sched and bog.sched.actors then
      for _, a in ipairs(bog.sched.actors) do
        if a.id ~= myid then ids[#ids + 1] = "#" .. a.id end
      end
    end
    local frame = SPIN[(si % #SPIN) + 1]
    if #ids > 0 then
      return string.format("%s  %d agent%s %s: %s   [^C cancel  p %s  k kill]",
        frame, #ids, #ids == 1 and "" or "s", paused and "paused" or "working",
        table.concat(ids, " "), paused and "resume" or "pause")
    elseif not started then
      return frame .. "  thinking\u{2026}"
    elseif line_buf ~= "" or #block > 0 then
      return frame .. "  responding\u{2026}"
    end
  end

  local perm = require("perm")
  local st = perm.state()
  local opts = perm.turn_opts({}, {
    on_ask = function(rec)
      -- Blocking readline, same contract as bog.choose_ask: this runs from the
      -- turn coroutine, sets rec.decision, and wrap_run therefore never parks
      -- on "approve". Chat mode never reaches here (schemas are empty).
      io.write("\napprove ", tostring(rec.name),
        (rec.summary and rec.summary ~= "") and (": " .. rec.summary) or "", "\n")
      io.write("[y]es  [n]o  [a]lways: ")
      io.flush()
      local ans = (sys.readline("approve") or "n"):gsub("^%s+", ""):gsub("%s+$", ""):lower()
      if ans == "a" or ans == "always" then
        st.approve_all = true
        rec.decision = "approve"
      elseif ans:sub(1, 1) == "n" then
        rec.decision = "reject"
      else
        rec.decision = "approve"
      end
    end,
  })
  opts.on_tool = function(name, input)
    flush_render()           -- emit the round's prose before its tool marker
    bog.log_tool(name, input)
  end
  if bog.thread and bog.thread.session_agent then
    local okrec, rec = pcall(bog.thread.session_agent, S)
    if okrec and rec and rec.opts then
      if opts.system == nil then opts.system = rec.opts.system end
      if opts.checkpoint == nil then opts.checkpoint = rec.opts.checkpoint end
      if st.mode ~= "chat" and rec.opts.tools then opts.tools = rec.opts.tools end
    end
  end

  local co = coroutine.create(function()
    local ok, e = pcall(bog.api.run_on, S, text, function(t)
      started = true
      on_delta(t)                -- stream block by block, rendered at each boundary
    end, opts)
    if not ok then turn_err = e end
  end)
  bog.sched.add(myid, co)

  -- Foreground control: read single keys off stdin on the SAME uv loop the fleet
  -- runs on, so you can steer it while it works. Raw mode turns Ctrl-C into a
  -- byte we interpret (a graceful cancel) rather than a signal that kills
  -- boggart. Sub-agents are the scheduler's other actors, acted on through its
  -- own pause/kill -- no separate control plane.
  local input = tty and control_input() or nil
  if input then
    pcall(function() input:set_mode(1) end) -- 1 = raw
    input:read_start(function(err, data)
      if err or not data then return end
      for i = 1, #data do
        local b = data:byte(i)
        if b == 3 or b == 27 then -- Ctrl-C / Esc: cancel the whole turn
          abort = true
        elseif b == 32 or b == 112 then -- space / p: pause or resume the fleet
          paused = not paused
          if bog.supervisor then pcall(bog.supervisor.pause_fleet, myid, paused)
          else for _, a in ipairs(bog.sched.actors) do
            if a.id ~= myid then pcall(bog.sched.pause, a.id, paused) end
          end end
        elseif b == 107 then -- k: kill the newest sub-agent (await unblocks)
          local newest
          for _, a in ipairs(bog.sched.actors) do
            if a.id ~= myid and (not newest or a.id > newest) then newest = a.id end
          end
          if newest then pcall(bog.thread.kill, newest) end
        end
      end
    end)
  end

  -- The timer fires on the loop the scheduler is already running, so it only
  -- ticks while the turn is in flight, repainting the activity line in place.
  local timer
  if tty then
    io.write(CURSOR_HIDE); io.flush() -- steady cursor while the status line repaints
    timer = uv.new_timer()
    timer:start(120, 120, function()
      si = si + 1
      clear_status()
      local line = status()
      if line then io.write(COL.dim, "  ", line, COL.reset); io.flush(); shown = true end
    end)
  end

  -- should_stop pumps the uv loop itself so control keys land promptly even in
  -- the one state the scheduler does not pump it: a fully paused fleet (nothing
  -- runnable, nothing in flight). uv.run("once") there blocks on the roster
  -- timer/keypress instead of busy-spinning; "nowait" otherwise keeps input snappy.
  local ok = pcall(bog.sched.run, {
    should_stop = function()
      uv.run("nowait")
      if paused and not abort then uv.run("once") end
      return abort
    end,
  })

  if input then
    pcall(function() input:read_stop() end)
    pcall(function() input:set_mode(0) end) -- restore cooked mode for isocline
  end
  if timer then timer:stop(); timer:close() end
  if tty then clear_status() end
  flush_render() -- emit the final round's prose (or a partial turn on abort)
  if abort then
    if bog.supervisor then pcall(bog.supervisor.kill_all)
    else for _, a in ipairs(bog.sched.actors) do pcall(bog.sched.kill, a.id) end end
    -- Heal a dangling tool_use / bare user turn the kill may have left, so the
    -- next turn and any --resume start from a sendable transcript rather than a
    -- permanent HTTP 400.
    pcall(bog.api.repair_history, S)
    io.write(COL.dim, "  (cancelled)", COL.reset, "\n")
  else
    io.write("\n")
  end
  if tty then io.write(CURSOR_SHOW); io.flush() end -- restore the cursor for the prompt
  print_turn_error(ok and turn_err == nil, turn_err or (not ok and "scheduler error") or nil)
  bog.save_session() -- persist transcript for /resume and crash recovery
  if not abort then
    return require("choose").capture_after_turn(S)
  end
end

-- The dim status row printed above each prompt: which model, local or remote
-- (remote flagged amber -- it is the one that spends money), how full the
-- context is, and how many worker agents are live. The terminal equivalent of
-- the studio's status bar, from the same bog.api.status().
local function status_line()
  local ok, s = pcall(bog.api.status)
  if not ok or not s then return nil end
  local frac = 0
  pcall(function() frac = bog.api.context_fraction(bog.session) or 0 end)
  local running = 0
  pcall(function() running = bog.worker.count() or 0 end)
  local amber, sep = "\27[33m", COL.dim .. " \u{00B7} " .. COL.reset
  local prov = (s.is_local and COL.dim or amber) .. s.provider .. COL.reset
  local line = prov .. sep .. COL.dim .. s.model .. COL.reset
  if s.is_local then line = line .. sep .. COL.dim .. s.host .. COL.reset end
  line = line .. sep .. COL.dim .. string.format("ctx %d%%", math.floor(frac * 100 + 0.5)) .. COL.reset
  line = line .. sep .. COL.dim .. string.format("%d agent%s", running, running == 1 and "" or "s") .. COL.reset
  return line
end

local function do_repl()
  local tty = term and term.istty and term.istty()
  io.write(require("logo").render(tty), "\n")
  io.write("boggart ", bog.version, "  model=", bog.session.model,
    "  (/help for commands)\n")
  -- Persist REPL history across sessions. isocline handles the file; linenoise
  -- never had this wired up.
  if sys.history_file then sys.history_file(bog.userdir .. "/history", 500) end
  -- Stand the agent runtime up now, so the spawn/await tools are live and a turn
  -- can fan out a fleet from the very first message -- the scrolling REPL is a
  -- coordinator like every other mode, not a lesser one.
  bog.activate_agents()
  -- The REPL's synchronous resolver for the `choose` tool: print the menu, read
  -- one line (a letter picks; anything else is a typed answer). See lua/choose.lua.
  bog.choose_ask = function(rec)
    local choose = require("choose")
    local tty = term and term.istty and term.istty()
    io.write("\n", choose.render(rec, repl_wrap_width(), tty), "\n")
    local line = sys.readline("choose> ")
    return choose.parse_line(rec, line or "")
  end
  -- Tab completion, hints and (later) highlighting. `term` is a CLI-only C
  -- module (src/lterm.c); it is absent in the studio, so the call is guarded.
  if term and term.enable then pcall(term.enable) end
  local tty = term and term.istty and term.istty()
  while true do
    -- A fresh status row above each prompt keeps "which model am I about to
    -- spend on, and how full is the context" always in view. Interactive only,
    -- so piped output stays clean.
    if tty then local sl = status_line(); if sl then io.write(sl, "\n") end end
    local line = sys.readline("boggart")
    if line == nil then io.write("\n"); break end
    if line ~= "" then sys.add_history(line) end
    local p = require("take").parse(line)
    if p.kind == "slash" then
      local r = handle_command(p.line)
      if r == true then break
      elseif type(r) == "table" and r.run then
        local captured = run_one_turn(r.run)
        while captured do captured = run_one_turn(captured) end
      end
    elseif p.kind == "bash" then
      local okb, out = require("take").run_bash(p.command)
      io.write(tostring(out or ""), "\n")
      if not okb then io.write("(command failed)\n") end
    elseif p.kind == "prompt" then
      for _, n in ipairs(p.notes or {}) do
        if n.ok then
          io.write(string.format("attached %s (%d bytes)\n", n.path, n.bytes))
        else
          io.write("no such file: ", n.path, "\n")
        end
      end
      local captured = run_one_turn(p.text)
      while captured do captured = run_one_turn(captured) end
    end
  end
  return 0
end

-- ---- dispatch --------------------------------------------------------------
if bog.mode == "init" then return do_init() end
if bog.mode == "reset" then return do_reset() end

-- everything below needs the harness wired
-- Expose json and the gold stdlib as real globals *before* wire(): wire
-- requires tools.lua, which loads user tool files, and those bodies capture
-- `gold` from the global at load time. Declaring it after wire() meant every
-- file-backed tool ran with gold == nil. The declare at the end of this file
-- (before strict.enable) is the worker/embedded-equivalent point; here it must
-- come first so tool loading sees it.
declare{ json = require("json"), gold = require("gold") }
local ok, err = bog.try(wire)
if not ok then
  io.stderr:write("boggart: failed to load harness:\n", err, "\n")
  return 1
end

-- A worker thread's interpreter (src/lworker.c): the full harness is wired --
-- same modules, same vocabulary -- but the store is NOT opened. Opening it
-- here would have every worker racing the same migration path at spawn, and
-- more importantly a worker must never share the main thread's SQLite
-- connection; a worker that wants the store calls bog.store.open() itself,
-- which opens its own connection (legal: WAL + SQLITE_THREADSAFE=2, one
-- connection per thread -- the same discipline as src/jwriter.c). No MCP
-- servers either: those subprocesses belong to the main loop.
if bog.mode == "worker" then
  declare{ json = bog.json, gold = require("gold") }
  strict.enable()
  return 0
end

-- `doctor` runs before the store is opened, and opens nothing itself. It is
-- what you run *because* boggart will not start, so it must not need a healthy
-- install -- and a diagnosis that repairs what it is diagnosing is not one.
if bog.mode == "doctor" then return bog.lifecycle.main() end

-- Open the local SQLite store (memory, sessions, kv, metadata), creating the
-- directory, the database and the schema if this is a new machine. A damaged
-- store is moved aside and recreated here, loudly; anything genuinely
-- unfixable arrives as a diagnosed error carrying its own explanation.
local sok, serr = bog.try(bog.store.open)
if not sok then
  if type(serr) == "table" and serr.boggart_error then
    io.stderr:write("boggart: ", tostring(serr), "\n",
      "Run `boggart doctor` for the full picture.\n")
  else
    io.stderr:write("boggart: failed to open local store:\n", tostring(serr), "\n")
  end
  return 1
end

-- One name for "this start created the database", so the CLI's welcome and the
-- studio's welcome screen agree about what a first run is. Without it the
-- studio has to guess -- "no credentials and no marker" -- which is a different
-- question with a different answer: someone who cleared their key is not a new
-- install, and someone who set one before ever launching the GUI is.
bog.first_run = (bog.store.state and bog.store.state.first_run) or false

-- The welcome, on a genuinely new install only: store.state.first_run is true
-- exactly when this start created the database. Not in eval (tests) or
-- embedded (the studio draws its own), and on stderr so a piped one-shot run
-- still emits only the model's answer on stdout.
if bog.store.state and bog.store.state.first_run
   and bog.mode ~= "eval" and bog.mode ~= "embedded" then
  io.stderr:write(bog.lifecycle.welcome(), "\n")
end

-- Expose json and the gold stdlib as real globals so define_tool bodies can use
-- them (the system prompt tells the model they may) without tripping strict.
declare{ json = bog.json, gold = require("gold") }

-- Lock globals now that libs + bog are in place -- except when embedded in the
-- editor, where lite sets its own globals (SCALE, PATHSEP, EXEDIR, VERSION...)
-- after we return, and has its own strict guard for them. Enabling ours here
-- would reject lite's assignments and take the editor down at startup.
if bog.mode ~= "embedded" then strict.enable() end

-- Connect any declared MCP servers (~/.boggart/lua/mcp_servers.lua). Skipped in
-- eval mode so tests don't spawn subprocesses.
-- A model stored via /auth applies once the store is open. Precedence matches
-- the credentials: an explicit --model beats it, so an override needs no undo.
-- A model stored via /auth applies unless --model overrode it, so a one-off
-- override needs no undo. Same precedence as the credentials themselves.
if not boggart.model then
  local m = auth.model()
  if m and m ~= "" then bog.session.model = m end
end

bog.llmstation = require("llmstation")
-- Eval skips MCP so tests do not spawn subprocesses. Embedded (studio)
-- skips it here too: connect/handshake block the thread, and the window
-- stays hidden until boot returns. Studio starts the same load after the
-- first present, from a core thread that yields between servers.
if bog.mode ~= "eval" and bog.mode ~= "embedded" then
  bog.try(bog.mcphost.load)
  -- Best-effort: if a local LLM Station is installed, expose its deterministic
  -- code-intelligence tools over MCP. Dormant (a no-op) when it is not.
  bog.try(bog.llmstation.autostart)
end

-- The agent layer, in every mode: everything is a swarm, and a lone agent is a
-- swarm whose fanout is capped at one. Skills, agent specs and the agent record
-- are therefore not swarm-only any more -- they are how *any* agent is built, so
-- skills work in the default REPL exactly as they do for a spawned child.
--
-- These three are pure Lua with no load-time cost. The scheduler is not: it
-- requires uv, which allocates a loop, so it stays lazy and swarm-only -- and it
-- is only needed once the cap allows more than one agent.
bog.skills = require("skills")
bog.agents = require("agents")
bog.thread = require("thread")
bog.supervisor = require("supervisor") -- the bus control plane (installed in activate_agents)
bog.skillrouter = require("skillrouter") -- FTS5 skill search (also feeds dispatch)
bog.dispatch = require("dispatch")       -- optional auto-routing heuristic
bog.thread.max_agents = tonumber(os.getenv("BOGGART_MAX_AGENTS"))
  or (bog.mode == "swarm" and 16 or 1)

-- Activate the agent runtime: the scheduler (which allocates the uv loop), the
-- coordination tools, the bus, and a raised fanout cap. Idempotent, and the SAME
-- setup for every mode that runs turns -- the scrolling REPL, the cTUI and swarm
-- mode all run a turn as a libuv-driven scheduler coroutine that may spawn a
-- fleet of more coroutines. There is one way to stand the runtime up, not three.
function bog.activate_agents()
  bog.sched = bog.sched or require("sched")
  -- The fabric's cross-thread drain: once the main loop exists, a worker thread
  -- can bus.publish and it dispatches here on the main state. Idempotent.
  if rawget(_G, "bus") and bus.attach_main then pcall(bus.attach_main) end
  -- The control plane over the bus: pause/kill/steer route through here so every
  -- surface drives one observable path instead of poking sched directly.
  bog.supervisor = bog.supervisor or require("supervisor")
  pcall(bog.supervisor.install)
  bog.tools_swarm = bog.tools_swarm or require("tools_swarm")
  if swarm and swarm.attach then pcall(swarm.attach, bog.db) end
  pcall(bog.tools_swarm.register)
  bog.thread.max_agents = tonumber(os.getenv("BOGGART_MAX_AGENTS")) or 16
  -- Arm the liveness watchdog for the whole runtime (idempotent).
  if bog.watchdog and bog.watchdog.start then pcall(bog.watchdog.start) end
  -- BOGGART_TRACE=<pattern> (or =1 for everything) tails the fabric bus to
  -- stderr for the whole run -- the always-on form of the /trace command.
  local tr = os.getenv("BOGGART_TRACE")
  if tr and tr ~= "" and tr ~= "0" then
    pcall(function() require("trace").start(tr == "1" and "*" or tr) end)
  end
end

if bog.mode == "embedded" then
  -- Embedded in boggart-studio: the harness is wired and the store is open;
  -- the editor drives it from here. No REPL, no dispatch, no reading stdin.
  -- lua/studio.lua is the UI side and is loaded by the editor, not by us.
  return 0

elseif bog.mode == "swarm" then
  -- Same activation as every other mode; swarm mode differs only in its front
  -- end (a coordinator + the optional --tui dashboard), not its runtime.
  bog.activate_agents()
  return require("swarmmode").run() -- "swarm" is the C bus global; the mode lives in swarmmode.lua

elseif bog.mode == "serve" then
  -- `boggart serve` -- the same runtime as every other mode, with the inbound
  -- control plane up and the process staying alive instead of running to
  -- quiescence. This is the "always-on daemon" every comparison study in
  -- docs/comparisons.md kept naming as the missing piece: with a listener, a
  -- webhook can start work, a second client can watch a running fleet, and a
  -- schedule can fire without anybody sitting at a terminal.
  --
  -- The split, once more, because it is the point: the socket, the framing and
  -- the bind/token rules are C (src/lserve.c) because Lua cannot open a port
  -- and because those rules must not be rewritable; the routes, the queue and
  -- everything below are Lua (lua/control.lua) because they should be.
  bog.activate_agents()
  bog.new_session()
  local control = require "control"
  local srv, url = control.start{
    host = boggart.host, port = boggart.port, token = boggart.token,
  }
  if not srv then
    io.stderr:write("boggart serve: " .. tostring(url) .. "\n")
    return 1
  end
  io.write("boggart " .. boggart.version .. " serving on " .. url .. "\n")
  if control.token then io.write("token: " .. control.token .. "\n") end
  io.write("routes: " .. url .. "/routes   events: " .. url .. "/events\n")

  -- Triggers: schedules restored from the store, plus the one uv timer that
  -- drives them. This is what makes the daemon act on its own rather than only
  -- answer -- 9am, every five minutes, or "whenever hook:push arrives".
  local triggers = require "triggers"
  local restored = triggers.load()
  triggers.start()
  if restored > 0 then io.write("triggers: " .. restored .. " restored\n") end
  io.flush()

  -- Inbound prompts run one at a time, in arrival order. A queue rather than a
  -- coroutine per request because a turn spawns a fleet, and two fleets racing
  -- for one terminal-less process is not throughput, it is a mess. The fan-out
  -- INSIDE a turn is untouched -- this only serialises the door.
  local queue = {}
  bog.events.on("serve:prompt", function(_, ev)
    queue[#queue + 1] = ev
  end, { desc = "serve: queue inbound prompts", source = "boot.lua" })

  local stop = false
  bog.events.on("serve:shutdown", function() stop = true end,
    { desc = "serve: stop the service", source = "boot.lua" })

  -- The daemon is a scheduler ACTOR, not a uv callback. That distinction is
  -- the whole reason this works: a turn yields (on HTTP, on a subprocess), and
  -- yielding is only legal inside a coroutine the scheduler drives -- calling
  -- run_one_turn from a timer callback would re-enter uv.run and take the
  -- process down on its first job. As an actor it yields like every other
  -- agent, and because it never returns, sched.run keeps the loop turning, so
  -- the C listener keeps accepting while a turn is in flight.
  local proc = require "proc"
  local co = coroutine.create(function()
    while not stop do
      local job = table.remove(queue, 1)
      if job then
        bog.events.emit("serve:running", { id = job.id, text = job.text,
                                           source = job.source })
        -- api.run_on, not run_one_turn: the REPL's driver stands up and drains
        -- the scheduler itself, and doing that from inside an actor re-enters
        -- the very coroutine being resumed. Here the scheduler is already
        -- running and this IS an actor, so the turn is just a call that yields
        -- -- the same thing swarmmode's coordinator does.
        --
        -- No approver is attached (there is no terminal to ask), so gated tools
        -- resolve through perm.headless_decision: one governed, auditable point
        -- rather than an unattended bypass. Set BOGGART_HEADLESS_POLICY=deny to
        -- withhold them from inbound work entirely.
        local out = {}
        local okr, res = bog.try(function()
          return bog.api.run_on(bog.active_session(), job.text,
            function(chunk) out[#out + 1] = chunk end,
            require("perm").turn_opts({}, {}))
        end)
        bog.events.emit("serve:done", { id = job.id, ok = okr,
                                        text = table.concat(out),
                                        result = okr and res or tostring(res) })
      else
        proc.sleep(0.1)   -- yields a uv timer: the loop turns, the port answers
      end
    end
  end)
  bog.sched.add("serve", co)
  bog.sched.run()

  triggers.stop()
  control.stop()
  return 0

elseif bog.mode == "models" then
  -- `boggart models ...` -- the catalog, from the command line. The store is
  -- already open (and seeded) by this point, so every subcommand is a query or
  -- an import against real rows.
  local C = require "catalog"
  local args = boggart.args or {}
  local cmd = args[1] or "list"

  if cmd == "list" or cmd == "ls" then
    local roles = C.roles()
    local rnames = {}
    for name in pairs(roles) do rnames[#rnames + 1] = name end
    table.sort(rnames)
    if #rnames > 0 then
      io.write("roles\n")
      for _, name in ipairs(rnames) do
        io.write(string.format("  %-12s %s\n", name, table.concat(roles[name], " -> ")))
      end
      io.write("\n")
    end
    io.write("providers\n")
    for _, p in ipairs(C.providers()) do
      -- whether a key exists is the thing you actually want to know here
      local keyed = auth.has_key and auth.has_key(p.key_slot or p.name)
      io.write(string.format("  %-14s %-9s %-9s %-3s %s\n",
        p.name, p.wire or "?", p.auth or "?", keyed and "key" or "-", p.url or ""))
    end
    io.write("\nmodels\n")
    for _, m in ipairs(C.models{}) do
      local caps = {}
      if m.tools then caps[#caps + 1] = "tools" end
      if m.vision then caps[#caps + 1] = "vision" end
      if m.effort then caps[#caps + 1] = "effort" end
      io.write(string.format("  %-38s %-12s %10s  %s\n",
        m.id, m.provider or "?",
        m.context and tostring(math.floor(m.context / 1000)) .. "k" or "",
        table.concat(caps, ",")))
    end
    return 0

  elseif cmd == "export" then
    local text = C.export_json()
    local path = args[2]
    if path then
      local f = io.open(path, "w")
      if not f then io.stderr:write("cannot write " .. path .. "\n"); return 1 end
      f:write(text); f:close()
      io.write("wrote " .. path .. "\n")
    else
      io.write(text, "\n")
    end
    return 0

  elseif cmd == "import" then
    local path = args[2]
    if not path then io.stderr:write("usage: boggart models import <file>\n"); return 1 end
    local n, err = C.import_file(path)
    if not n then io.stderr:write("import failed: " .. tostring(err) .. "\n"); return 1 end
    io.write(string.format("imported %d providers, %d models, %d roles\n",
      n.providers, n.models, n.roles))
    return 0

  elseif cmd == "refresh" then
    local who = args[2]
    local targets = {}
    if who then targets = { who }
    else
      for _, p in ipairs(C.providers()) do
        if p.catalog_url and p.catalog_url ~= "" then targets[#targets + 1] = p.name end
      end
    end
    if #targets == 0 then io.write("no provider publishes a catalog\n"); return 0 end
    local rc = 0
    for _, name in ipairs(targets) do
      local n, err = C.refresh(name)
      if n then io.write(string.format("%s: %d models\n", name, n.models))
      else io.stderr:write(string.format("%s: %s\n", name, tostring(err))); rc = 1 end
    end
    return rc

  elseif cmd == "role" then
    local name, spec = args[2], args[3]
    if not name then
      for rname, chain in pairs(C.roles()) do
        io.write(string.format("%-12s %s\n", rname, table.concat(chain, " -> ")))
      end
      return 0
    end
    if not spec then
      local chain = C.role(name)
      io.write(chain and table.concat(chain, " -> ") .. "\n" or "unbound\n")
      return 0
    end
    -- a comma-separated list is a fallback chain
    local list = {}
    for one in spec:gmatch("[^,]+") do list[#list + 1] = (one:gsub("^%s+", ""):gsub("%s+$", "")) end
    local bound, err = C.bind_role(name, list)
    if not bound then io.stderr:write(tostring(err) .. "\n"); return 1 end
    io.write(string.format("%s -> %s\n", name, table.concat(bound, " -> ")))
    return 0
  end

  io.stderr:write("usage: boggart models [list|import <file>|export [file]|refresh [provider]|role [name] [spec]]\n")
  return 1

elseif bog.mode == "eval" then
  local chunk = assert(loadfile(boggart.eval_file))
  local rc = chunk()
  return type(rc) == "number" and rc or 0

elseif bog.mode == "headless" then
  bog.new_session()
  local input = io.read("*a") or ""
  input = input:gsub("%s+$", "")
  if input ~= "" then run_one_turn(input) end
  return 0

elseif bog.mode == "oneshot" then
  bog.new_session()
  run_one_turn(boggart.prompt or "")
  return 0

else
  -- `boggart --tui` (no subcommand) opens the full-screen chat cTUI. It manages
  -- its own session and bows out (returns false) when there is no real terminal,
  -- so a pipe or a dumb term falls straight through to the scrolling REPL. The
  -- ltui swarm dashboard (`boggart swarm --tui`) is a separate mode, untouched.
  if boggart.tui and tc then
    local ok, tui = pcall(require, "tui")
    if ok and tui and tui.run() then return 0 end
  end
  local resumed = bog.resume_startup()
  if resumed then
    io.write(string.format("resumed session %d (%d message%s)%s\n",
      resumed.id, #resumed.messages, #resumed.messages == 1 and "" or "s",
      (resumed.title and resumed.title ~= "") and (": " .. resumed.title) or ""))
    -- If the session was interrupted mid-tool (a crash or Ctrl-C during a tool
    -- call), finish that tool round and continue the turn before prompting --
    -- durable checkpointing means the work already done is on disk to build on.
    if bog.api.incomplete_turn and bog.api.incomplete_turn(resumed) then
      io.write(COL.dim, "continuing an interrupted turn...", COL.reset, "\n")
      pcall(run_one_turn, nil)
    end
  else
    bog.new_session()
  end
  return do_repl()
end
