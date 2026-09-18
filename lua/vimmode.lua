-- vimmode.lua -- the one shared vim-mode setting, read by both the cTUI
-- (lua/tui) and the studio editor (studio/data/core/vim.lua). One row in the
-- store, one policy, so switching editors never means re-deciding whether
-- modal editing is on.
--
-- The rule this encodes: evil mode is always an OPTION, never forced by
-- default. "off" is what a fresh install gets. "on" makes modal editing
-- available without committing to it -- you still open in insert, Esc gets
-- you into normal, and you can go back to plain typing whenever. "mandatory"
-- is the one a user has to ask for: it starts in normal mode and the UI
-- cannot turn it off, because a lock you can click your way out of is not a
-- lock. cycle() enforces exactly that asymmetry.
local M = {}

M.MODES = { off = true, on = true, mandatory = true }
local KEY = "config.vimmode"
local DEFAULT = "off"

local mode_cache = nil

-- Current mode: "off", "on", or "mandatory". Cached after the first read so
-- every keystroke handler can call this cheaply.
function M.mode()
  if mode_cache then return mode_cache end
  local raw = bog.store and bog.store.kv_get and bog.store.kv_get(KEY)
  mode_cache = (raw and M.MODES[raw]) and raw or DEFAULT
  return mode_cache
end

-- Set the mode and persist it. Fires vimmode:changed so live editors (cTUI
-- and studio alike) can react without polling.
function M.set(mode)
  assert(M.MODES[mode], "vimmode: no such mode: " .. tostring(mode))
  mode_cache = mode
  if bog.store and bog.store.kv_set then
    pcall(bog.store.kv_set, KEY, mode)
  end
  bog.events.emit("vimmode:changed", { mode = mode })
  return mode
end

-- off -> on -> mandatory -> off, EXCEPT out of mandatory: that is a
-- deliberate lock a user opted into, not a step in the rotation, so cycling
-- there is a no-op and the mode stays mandatory.
function M.cycle()
  local cur = M.mode()
  if cur == "mandatory" then return cur end
  return M.set(cur == "off" and "on" or "mandatory")
end

-- Modal editing is available at all (as opposed to plain insert-only).
function M.enabled()
  return M.mode() ~= "off"
end

-- Whether a new buffer should open in normal mode rather than insert. True
-- only for "mandatory" -- "on" still starts in insert, per the rule that
-- modal is offered, not sprung on you.
function M.starts_normal()
  return M.mode() == "mandatory"
end

return M
