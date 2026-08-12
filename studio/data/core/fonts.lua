-- fonts.lua -- choosing the typeface, and remembering the choice.
--
-- The bundled faces are fine and they are not everyone's. This is a text
-- application people look at for hours, and which face and size that text is
-- in is the single setting most likely to matter to whoever is reading it.
--
-- Stored in SQLite rather than in a Lua file, for the same reason model names
-- are: it is configuration, it changes without the binary changing, and the
-- store is the one place both front ends and the agent can already reach. The
-- row holds paths and sizes only -- never font data -- so a missing file
-- degrades to the bundled face rather than to a blank window.
local core = require "core"
local style = require "core.style"

local fonts = {}

-- What the bundled defaults are, so "reset" has something to mean and a
-- missing custom file has somewhere to fall back to.
fonts.DEFAULTS = {
  ui   = { path = DATADIR .. "/fonts/font.ttf",       size = 14 },
  big  = { path = DATADIR .. "/fonts/font.ttf",       size = 34 },
  code = { path = DATADIR .. "/fonts/monospace.ttf",  size = 13.5 },
}

-- Where a person's own fonts actually live, per platform. Asked of the
-- capability layer rather than inferred, like every other platform question
-- here; the picker starts in the first of these that exists.
function fonts.search_paths()
  local name = sys.caps().name
  local home = sys.home()
  if name == "macos" then
    return { home .. "/Library/Fonts", "/Library/Fonts", "/System/Library/Fonts" }
  elseif name == "windows" then
    return { (os.getenv("LOCALAPPDATA") or home) .. "\\Microsoft\\Windows\\Fonts",
             "C:\\Windows\\Fonts" }
  end
  return { home .. "/.local/share/fonts", home .. "/.fonts",
           "/usr/share/fonts", "/usr/local/share/fonts" }
end

function fonts.first_search_path()
  for _, p in ipairs(fonts.search_paths()) do
    if sys.stat(p) == "dir" then return p end
  end
  return sys.home()
end

-- ---------------------------------------------------------------------------
-- The stored choice
-- ---------------------------------------------------------------------------

local function read_config()
  local raw = bog.store and bog.store.kv_get and bog.store.kv_get("config.fonts")
  if not raw then return {} end
  local ok, t = pcall(bog.json.decode, raw)
  return (ok and type(t) == "table") and t or {}
end

local function write_config(t)
  if bog.store and bog.store.kv_set then
    pcall(bog.store.kv_set, "config.fonts", bog.json.encode(t))
  end
end

function fonts.settings()
  local cfg = read_config()
  local out = {}
  for which, def in pairs(fonts.DEFAULTS) do
    local c = cfg[which] or {}
    out[which] = {
      path = c.path or def.path,
      size = tonumber(c.size) or def.size,
      custom = c.path ~= nil,
    }
  end
  return out
end

-- Load one face, falling back rather than failing.
--
-- renderer.font.load raises on a file it cannot read, and a raise here happens
-- during startup or during a settings change -- either way the window either
-- never appears or dies mid-frame. A font that will not load is a bad setting,
-- not a fatal condition, so it degrades to the bundled face and says so.
local function load_face(which, path, size)
  local scaled = size * SCALE
  local ok, face = pcall(renderer.font.load, path, scaled)
  if ok and face then return face, nil end
  local def = fonts.DEFAULTS[which]
  local ok2, fallback = pcall(renderer.font.load, def.path, def.size * SCALE)
  if ok2 then
    return fallback, string.format("%s could not be loaded; using the bundled face", path)
  end
  return nil, string.format("neither %s nor the bundled face could be loaded", path)
end

-- Apply the stored choice to style.*. Called at startup and after a change.
function fonts.apply()
  local s = fonts.settings()
  local problems = {}

  local ui, e1 = load_face("ui", s.ui.path, s.ui.size)
  local big, e2 = load_face("big", s.big.path, s.big.size)
  local code, e3 = load_face("code", s.code.path, s.code.size)
  for _, e in ipairs({ e1, e2, e3 }) do if e then problems[#problems + 1] = e end end

  if ui then style.font = ui end
  if big then style.big_font = big end
  if code then style.code_font = code end

  -- Everything that measured text with the old faces is now wrong: the chat
  -- panel caches its layout against a column count derived from the font, and
  -- ui.metrics caches line heights per face. The metrics cache is keyed on the
  -- font object so a new face simply misses it, but the layout cache is keyed
  -- on (columns, text) and columns can land on the same number for a different
  -- face -- so it is dropped explicitly rather than left to chance.
  local studio = package.loaded["core.studio"]
  local view = studio and studio.agent_view and studio.agent_view()
  if view and view.entries then
    for _, e in ipairs(view.entries) do e._layout = nil end
  end
  core.redraw = true
  return problems
end

-- Set a face, refusing rather than storing something that will not load.
--
-- Validated before it is written, because the failure is otherwise invisible:
-- apply() falls back to the bundled face, the window looks unchanged, and the
-- setting sits in the database claiming to be in force. "Nothing happened" is
-- the worst possible answer to a settings change.
--
-- The common case this catches is .ttc -- macOS ships most of its system faces
-- as TrueType *collections*, and the loader handles single-face .ttf/.otf
-- only. Supporting collections means passing an index through
-- stbtt_GetFontOffsetForIndex, which the fallback-chain code already does and
-- this path does not.
function fonts.set(which, path, size)
  if not fonts.DEFAULTS[which] then return nil, "no such font slot: " .. tostring(which) end
  if path then
    local probe = (tonumber(size) or fonts.DEFAULTS[which].size) * SCALE
    local ok = pcall(renderer.font.load, path, probe)
    if not ok then
      local why = path:lower():match("%.ttc$")
        and (path .. " is a font collection (.ttc). boggart can only load a "
             .. "single-face .ttf or .otf; most macOS system fonts are "
             .. "collections, but ~/Library/Fonts usually has .ttf files.")
        or (path .. " could not be loaded as a font.")
      return nil, why
    end
  end
  local cfg = read_config()
  local entry = cfg[which] or {}
  if path then entry.path = path end
  if size then entry.size = tonumber(size) end
  cfg[which] = entry
  write_config(cfg)
  return fonts.apply()
end

function fonts.reset(which)
  local cfg = read_config()
  if which then cfg[which] = nil else cfg = {} end
  write_config(cfg)
  return fonts.apply()
end

return fonts
