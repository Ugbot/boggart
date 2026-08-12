-- workers.lua -- the friendly face of the C worker registry.
--
-- Tracking lives in C (src/lworker.c): worker.list()/count() walk the same
-- g_workers list the atexit handler uses, so they see every worker regardless
-- of who spawned it -- a worker started from another module, or from C, shows
-- up too. A Lua-side registry could only ever have seen what was spawned
-- through it, which is why the owner was right that this belongs in C.
--
-- This module adds only what the C layer has no reason to carry: a spawn that
-- defaults a label, and list()/count() re-exposed so callers use one table
-- (bog.worker) and never reach past it to the raw module.
local raw = require("worker")  -- the C module

local M = { raw = raw }

-- spawn(source, opts). opts.label and opts.kind are for display and are read by
-- C; on_message strings become the worker's `last` line automatically, so a
-- worker that reports its progress ("reading src/", "3 of 12") is legible in
-- the list with no extra wiring.
function M.spawn(source, opts)
  return raw.spawn(source, opts or {})
end

-- Every live (and recently finished) worker, newest first: the roster a UI or
-- `boggart doctor` draws. The C list is registry order; a stable sort by id
-- keeps rows from jumping as workers come and go.
function M.list()
  local out = raw.list()
  table.sort(out, function(a, b) return a.id > b.id end)
  return out
end

-- running, total -- the status-bar summary.
function M.count() return raw.count() end

-- Pass-throughs, so bog.worker is the whole surface.
function M.post(h, msg) return raw.post(h, msg) end
function M.recv(h, timeout) return raw.recv(h, timeout) end
function M.stop(h) return raw.stop(h) end
function M.join(h) return raw.join(h) end
function M.status(h) return raw.status(h) end

return M
