-- core/engine.lua -- the swarm ENGINE half of the studio, lifted out of the
-- studio.lua composition (S3) so the shell and the legacy window share exactly
-- one lifecycle rather than the god-module carrying both the engine and the
-- chrome. This is the actor layer, the bus/journal, the dash attribution
-- wrappers, and the always-on scheduler pump.
--
-- install(studio) defines the methods on the studio table and leaves their state
-- (studio.swarm_ok / studio.engine / studio.pump_started / ...) exactly where it
-- was, so every existing caller -- agentview's swarm_ok check, tick(), attach --
-- is unchanged. `swarm` and `bog` are process globals, as in studio.lua.
local core = require "core"

local M = {}

function M.install(studio)
  -- Which tools are swarm orchestration tools -- the ones whose first use has to
  -- stand the engine up. Asked of the registry so it tracks tools_swarm.defs
  -- rather than a copy that drifts.
  function studio.is_swarm_tool(name)
    return bog and bog.tools_swarm and bog.tools_swarm.defs
       and bog.tools_swarm.defs[name] ~= nil
  end

  function studio.setup_swarm()
    if studio.swarm_setup then return studio.swarm_ok end
    studio.swarm_setup = true
    local ok = core.try(function()
      assert(bog and bog.db, "no store open; the swarm needs a database")
      -- Same modules and the same lazy loading lua/boot.lua's `swarm` branch
      -- uses: the studio boots as "embedded", so the actor layer is not required
      -- until something asks for it. If this list grows there, it grows here.
      bog.sched       = bog.sched       or require("sched")
      bog.skills      = bog.skills      or require("skills")
      bog.agents      = bog.agents      or require("agents")
      bog.thread      = bog.thread      or require("thread")
      bog.tools_swarm = bog.tools_swarm or require("tools_swarm")
      -- Offer the tools always. Safe now in a way it was not before: the chat
      -- turn is itself a scheduled actor, so an agent it spawns is one the studio
      -- is actively resuming -- not an actor nobody is scheduling, which was the
      -- bug the old per-run register/unregister guarded against.
      bog.tools_swarm.register()
    end)
    studio.swarm_ok = ok and true or false
    if studio.swarm_ok then studio.start_pump() end
    return studio.swarm_ok
  end

  -- The heavy half, stood up the first time a swarm tool actually runs. Attaches
  -- the bus/journal (idempotent; starts the writer thread in src/jwriter.c) and
  -- installs the dash observation wrappers so the Swarm view sees every agent --
  -- the chat coordinator included -- through the one attribution mechanism
  -- lua/dash.lua already has, rather than a second one that would drift from it.
  function studio.ensure_engine()
    if studio.engine then return true end
    if not studio.swarm_ok then return false end
    local ok = core.try(function()
      swarm.attach(bog.db)
      studio.observe_on()
      -- Give the coordinator a roster row now: its own run_on was already in
      -- flight when this ran (the spawn that triggered us is mid-turn), so the
      -- streaming wrapper below will not attribute this turn's text to it.
      local id = bog.sched.current()
      if id then
        local rec = require("dash").touch(id)
        rec.kind, rec.kind_locked = "coordinator", true
      end
    end)
    studio.engine = ok and true or false
    return studio.engine
  end

  -- Attribution, exactly as lua/dash.lua (and the old swarmview) did it: wrap the
  -- three places output comes from and ask the scheduler whose coroutine is
  -- running. bog.sched.current() is nil outside a resume, so a stray call from
  -- outside a turn attributes to nobody rather than to the wrong agent. Installed
  -- once, for the app's life -- once you are spawning, you are in swarm territory.
  function studio.observe_on()
    if studio._orig_run_on then return end
    local dash = require "dash"

    studio._orig_run_on = bog.api.run_on
    bog.api.run_on = function(sess, text, on_text, opts)
      return studio._orig_run_on(sess, text, function(s)
        local id = bog.sched.current()
        if id then dash.feed(id, s); core.redraw = true end
        if on_text then on_text(s) end
      end, opts)
    end

    studio._orig_log = bog.log
    bog.log = function(msg)
      local id = bog.sched.current()
      if id then dash.emit(id, "* " .. tostring(msg)) end
      core.log_quiet("swarm: %s", tostring(msg))
      core.redraw = true
    end

    studio._orig_log_tool = bog.log_tool
    bog.log_tool = function(name, input)
      local id = bog.sched.current()
      if not id then return studio._orig_log_tool(name, input) end
      local hint = ""
      if type(input) == "table" then
        local h = input.command or input.path or input.query or input.name or input.task
        if h then hint = ": " .. tostring(h):gsub("%s+", " "):sub(1, 90) end
      end
      local rec = dash.touch(id)
      rec.tools = (rec.tools or 0) + 1
      dash.emit(id, "> " .. tostring(name) .. hint)
      core.redraw = true
    end
  end

  -- A turn is persisted into a session row, and that row's id is also the
  -- coordinator's actor id on the bus (sessions and threads are one table). The
  -- studio creates no session until a turn actually needs one, so make one here,
  -- without disturbing an in-progress transcript -- bog.new_session would wipe
  -- the messages, which is not what "the first turn just started" means.
  function studio.ensure_session()
    if bog.session and bog.session.id then return bog.session.id end
    if not (bog and bog.store and bog.session) then return nil end
    local ok, id = pcall(bog.store.sess_create, nil, bog.session.model)
    if ok and id then
      bog.session.id = id
      if bog.events then pcall(bog.events.emit, "session:created", { id = id }) end
    end
    return bog.session.id
  end

  -- The always-on scheduler pump. Every actor -- the chat coordinator turn and
  -- every sub-agent it spawns -- advances one non-blocking slice per frame via
  -- bog.sched.step(false). Guarded so it is a genuine no-op when there are no
  -- actors: the whole app before its first turn, and every gap between turns,
  -- pays one integer compare and nothing else.
  --
  -- Driven from a core thread rather than a view's update() because a sub-agent
  -- can outlive the panel it was spawned from, and the swarm must keep running
  -- whichever tab -- chat, a file, or Swarm -- is the one on screen.
  function studio.start_pump()
    if studio.pump_started then return end
    studio.pump_started = true
    core.add_thread(function()
      while true do
        local sched = bog.sched
        if sched and #sched.actors > 0 then
          -- The approval gate parks itself now: an actor awaiting a decision yields
          -- "block" and the scheduler holds it on rec.decision (lua/sched.lua), so
          -- this pump no longer peeks at UI state or hand-parks the coordinator --
          -- it just steps. Sub-agents are separate actors and keep going.
          local ok, err = pcall(sched.step, false)
          if not ok then core.log_quiet("swarm scheduler: %s", tostring(err)) end
          core.redraw = true
          coroutine.yield(0)          -- run every frame while there is work
        else
          -- Idle: a short poll, small enough that a turn beginning between frames
          -- starts within a frame or two, large enough that the frame loop can
          -- still sleep when nothing at all is happening.
          coroutine.yield(0.05)
        end
      end
    end)
  end
end

return M
