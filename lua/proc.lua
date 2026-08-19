-- proc.lua -- subprocesses on the libuv event loop.
--
-- Replaces the blocking sys.exec for the `bash` tool. The old path polled the
-- child's pipe inside C until it exited, which meant an agent running a build
-- froze the whole cooperative scheduler: lua/sched.lua never reached its
-- http.pump call, so *every other agent's LLM stream stalled too*. Swarm mode
-- was only concurrent until somebody shelled out.
--
-- Here the child's stdout/stderr arrive via uv.read_start callbacks, so the
-- work is entirely on the loop and a caller can yield between ticks. Being Lua
-- rather than C, this is also overlay-mutable like the rest of the harness --
-- the agent can rewrite how its own shell tool behaves.
--
--   local h = proc.start(cmd, timeout_sec)
--   h:poll()    -> "running" | "done"      (never blocks)
--   h:wait()    -> result                  (blocks; drives the loop itself)
--   h:result()  -> { out=, code=, timed_out=, truncated= }
--   h:kill()
local uv = require("uv")

-- Platform facts come from the C core, never from sniffing package.config or a
-- path separator in here. sys.caps() answers the question this code actually
-- has -- "is there a process group to kill?" -- rather than "which OS is this?".
local caps = sys.caps()

local M = {}

M.MAX_OUTPUT = 16 * 1024 * 1024 -- match the old sys.exec cap

local Proc = {}
Proc.__index = Proc

-- Terminate the child and, where the platform allows it, its descendants:
-- shell commands routinely leave grandchildren behind, and killing only the
-- direct child would orphan them.
--
-- How that is achieved is sys.kill_tree's problem, not this file's. Whether it
-- is possible at all is caps.process_groups, which is false on Windows -- there
-- is no group to signal there, and doing better needs a Job Object that libuv
-- does not expose. Stated once, in C, rather than branched on here.
function Proc:kill(sig)
  if self.killed or not self.handle then return end
  self.killed = true
  local signum = (sig == "sigkill") and caps.SIGKILL or caps.SIGTERM
  -- sys.kill_tree owns the whole "how do I reach the descendants" question:
  -- negated pid on POSIX, direct process on Windows (no process groups there).
  local ok = self.pid and pcall(sys.kill_tree, self.pid, signum)
  if not ok then pcall(uv.process_kill, self.handle, sig or "sigterm") end
end

function Proc:_cleanup()
  if self.cleaned then return end
  self.cleaned = true
  for _, h in ipairs({ self.stdout, self.stderr, self.timer, self.handle }) do
    if h and not uv.is_closing(h) then pcall(uv.close, h) end
  end
end

-- Has the child finished? Never blocks. One non-blocking turn of the loop is
-- enough to deliver whatever is ready.
function Proc:poll()
  if not self.done then uv.run("nowait") end
  return self.done and "done" or "running"
end

function Proc:result()
  return {
    out = table.concat(self.chunks),
    code = self.code or -1,
    timed_out = self.timed_out or false,
    truncated = self.truncated or false,
  }
end

-- Blocking wait, for callers not running under the scheduler (the REPL,
-- one-shot, headless). Still uses the loop rather than a busy spin: "once"
-- blocks until *something* happens, so an idle child costs no CPU.
function Proc:wait()
  while not self.done do uv.run("once") end
  self:_cleanup()
  uv.run("nowait") -- let the close callbacks retire
  return self:result()
end

local function on_read(self)
  return function(err, chunk)
    if err then self.read_err = err; return end
    if not chunk then return end -- EOF
    if self.nbytes >= M.MAX_OUTPUT then
      if not self.truncated then self.truncated = true; self:kill("sigkill") end
      return
    end
    local take = chunk
    if self.nbytes + #chunk > M.MAX_OUTPUT then
      take = chunk:sub(1, M.MAX_OUTPUT - self.nbytes)
      self.truncated = true
      self:kill("sigkill")
    end
    self.chunks[#self.chunks + 1] = take
    self.nbytes = self.nbytes + #take
  end
end

-- Start `cmd` under the platform shell. The command goes to the shell as a
-- single argument, which is what lets us sidestep Win32 argv quoting entirely:
-- cmd.exe does the parsing, exactly as /bin/sh does.
function M.start(cmd, timeout_sec)
  local exe, flag = sys.shell()
  local self = setmetatable({
    chunks = {}, nbytes = 0, done = false, code = nil,
    timed_out = false, truncated = false, killed = false, cleaned = false,
  }, Proc)

  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)

  local handle, pid = uv.spawn(exe, {
    args = { flag, cmd },
    stdio = { nil, self.stdout, self.stderr },
    -- Ask for our own process group where the platform has them, so a timeout
    -- can take the whole tree down rather than orphaning grandchildren.
    detached = caps.process_groups,
  }, function(code, signal)
    -- Signal deaths reported as 128+signum, matching the old sys.exec contract.
    self.code = (signal and signal ~= 0) and (128 + signal) or code
    self.done = true
    if self.timer and not uv.is_closing(self.timer) then pcall(uv.timer_stop, self.timer) end
  end)

  if not handle then
    self.done = true
    self.code = 127
    self.chunks[1] = "failed to spawn: " .. tostring(pid)
    pcall(uv.close, self.stdout)
    pcall(uv.close, self.stderr)
    return self
  end

  self.handle, self.pid = handle, pid
  -- stderr folds into the same buffer, as sys.exec did: the model wants the
  -- diagnostics interleaved with the output, not separated.
  uv.read_start(self.stdout, on_read(self))
  uv.read_start(self.stderr, on_read(self))

  if timeout_sec and timeout_sec > 0 then
    self.timer = uv.new_timer()
    uv.timer_start(self.timer, math.floor(timeout_sec * 1000), 0, function()
      if self.done then return end
      self.timed_out = true
      self:kill("sigterm")
      -- Give it a moment to die politely, then insist.
      local hard = uv.new_timer()
      uv.timer_start(hard, 1000, 0, function()
        if not self.done then self:kill("sigkill") end
        pcall(uv.close, hard)
      end)
    end)
  end

  return self
end

-- Cooperative sleep. Under a yieldable coroutine this arms a uv timer and
-- yields "proc" until it fires, so the studio frame loop and the swarm
-- scheduler keep turning; off a coroutine it is uv.sleep.
function M.sleep(sec)
  local ms = math.max(0, math.floor((tonumber(sec) or 0) * 1000 + 0.5))
  if ms <= 0 then return end
  local uv = require("uv")
  if not coroutine.isyieldable() then uv.sleep(ms); return end
  local t = uv.new_timer()
  local done = false
  uv.timer_start(t, ms, 0, function() done = true end)
  while not done do coroutine.yield("proc", t) end
  pcall(uv.close, t)
end

-- Convenience: run to completion. Under the cooperative scheduler this yields
-- between polls so every other agent keeps running; off a coroutine it blocks
-- on the loop.
function M.run(cmd, timeout_sec)
  local h = M.start(cmd, timeout_sec)
  if coroutine.isyieldable() then
    while h:poll() == "running" do
      -- "proc" tells lua/sched.lua this actor is waiting on a child rather
      -- than on HTTP, so it keeps turning the loop instead of concluding the
      -- actor is blocked on mail that will never arrive.
      coroutine.yield("proc", h)
    end
    h:_cleanup()
    uv.run("nowait")
    return h:result()
  end
  return h:wait()
end

return M
