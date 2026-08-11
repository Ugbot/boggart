-- uitools.lua -- tools that let the agent write the interface.
--
-- These are ordinary boggart tools, registered only when running inside the
-- studio: `draw_panel` means nothing to `boggart --headless`, and a tool that
-- cannot work in the context it is offered in is worse than an absent one.
--
-- This is the same self-extension boggart already has for tools, memory and
-- skills, applied to the last part of the system the agent was locked out of.
-- It is also the reason the studio embeds boggart in one process and one
-- lua_State rather than talking to it over a socket: the agent edits the
-- application it is running inside, and sees the result on the next frame.
local core = require "core"
local uisandbox = require "core.uisandbox"

local uitools = {}

function uitools.dir()
  return bog.userdir .. "/ui"
end

function uitools.path(name)
  return uitools.dir() .. "/" .. name .. ".lua"
end

local function valid_name(name)
  return type(name) == "string" and name ~= "" and not name:find("[^%w_%-]")
end

function uitools.list()
  local out = {}
  for _, f in ipairs(sys.listdir(uitools.dir()) or {}) do
    local n = f:match("^(.+)%.lua$")
    if n then out[#out + 1] = n end
  end
  table.sort(out)
  return out
end

-- Provenance in a header comment rather than a sidecar file: a panel is a
-- source file a person will open and edit, and the answer to "where did this
-- come from" should be in front of them when they do.
--
-- The git revision is captured once, at registration, rather than per save.
-- sys.exec yields ("proc", handle) when it is called from inside a coroutine,
-- because boggart runs subprocesses on the libuv loop so one shell command
-- cannot freeze the other actors. That is exactly right under boggart's own
-- scheduler and wrong everywhere else: the editor's thread runner expects a
-- yield to be a number of seconds to sleep, so a stray ("proc") reaches it as
-- a string and the frame loop dies with "attempt to add a number with a
-- string". Anything called from both worlds has to avoid yielding, and the
-- cheapest way to avoid it is not to be in a coroutine at all.
local git_rev = ""

local function header(name)
  local rev = git_rev
  return string.format(
    "-- %s -- a boggart-studio panel, written by the agent.\n" ..
    "-- session %s, %s%s\n" ..
    "-- Runs in a restricted environment: drawing, the theme and arithmetic.\n" ..
    "-- No io, no os beyond the clock, no require, no network, no credentials.\n" ..
    "-- Define draw(ctx). See ctx.rect/text/button/text_width/state.\n\n",
    name, tostring(bog.session and bog.session.id or "?"),
    os.date("%Y-%m-%d %H:%M"), rev ~= "" and (", git " .. rev) or "")
end

function uitools.save(name, source)
  sys.mkdir_p(uitools.dir())
  local body = source
  if not body:match("^%s*%-%-") then body = header(name) .. body end
  local ok, err = bog.util.write_file(uitools.path(name), body)
  if not ok then return nil, tostring(err) end
  return uitools.path(name)
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

function uitools.register(studio)
  if not (bog and bog.tools and bog.tools.register) then return false end

  -- Startup, on the main thread: safe to shell out here, and nowhere else.
  local ok, out = pcall(sys.exec, "git rev-parse --short HEAD", 5)
  if ok and type(out) == "string" then git_rev = out:gsub("%s+", "") end

  bog.tools.register("draw_panel", {
    description =
      "Create or replace a panel in the boggart-studio window and show it. " ..
      "`source` is Lua defining `draw(ctx)`, called every frame. " ..
      "ctx.rect(x,y,w,h,colour), ctx.text(s,x,y,colour,align,w), " ..
      "ctx.button(label,x,y[,w]) -> true on the frame it is clicked, " ..
      "ctx.text_width(s), ctx.line_height, ctx.button_height(), " ..
      "ctx.x/y/w/h (the panel's rectangle), ctx.mouse ({x,y} or nil), " ..
      "ctx.state (a table that persists between frames). " ..
      "Colours come from the read-only `style` table: style.text, style.dim, " ..
      "style.accent, style.good, style.error, style.warn, style.background2, " ..
      "style.selection, style.divider. " ..
      "For diagrams there are hand-drawn vector shapes (rough.js style): " ..
      "ctx.line(x1,y1,x2,y2,colour,thickness) exact, and sketchy " ..
      "ctx.sketch_rect(x,y,w,h,colour,thickness,opts), ctx.sketch_ellipse, " ..
      "ctx.sketch_circle(cx,cy,d,...), ctx.sketch_polygon(points,...), " ..
      "ctx.sketch_path(points,...), ctx.sketch_curve(points,...), " ..
      "ctx.arrow(x1,y1,x2,y2,colour,thickness), and " ..
      "ctx.box(text,x,y,w,h,colour) for a labelled box. `points` is a list of " ..
      "{x,y} pairs in screen coordinates. opts may set roughness, bowing, " ..
      "fill (a colour), fillStyle ('hachure'|'solid'|'zigzag'|'cross-hatch'|" ..
      "'dots'), hachureAngle. Sketch shapes do NOT clip to the panel, so keep " ..
      "them inside ctx.x..ctx.x+ctx.w. " ..
      "The environment has math, string, table and os.time/clock/date only: " ..
      "no io, no require, no network.",
    input_schema = {
      type = "object",
      properties = {
        name = { type = "string", description = "panel name, [A-Za-z0-9_-]" },
        source = { type = "string", description = "Lua defining draw(ctx)" },
      },
      required = { "name", "source" },
    },
    run = function(a)
      a = a or {}
      if not valid_name(a.name) then
        return "Tool error: [bad_request] panel name must be [A-Za-z0-9_-]"
      end
      if type(a.source) ~= "string" or a.source == "" then
        return "Tool error: [bad_request] source is required"
      end
      -- Compiled before it is stored. Writing a panel that cannot load, then
      -- opening it to discover that, wastes a turn for no reason.
      local fn, err = uisandbox.compile(a.name, a.source)
      if not fn then
        return "Tool error: [bad_request] the panel does not compile: " .. tostring(err)
      end
      local path, werr = uitools.save(a.name, a.source)
      if not path then return "Tool error: " .. tostring(werr) end
      local view = studio.open_panel(a.name)
      return string.format("panel '%s' is on screen (%s). It redraws when you "
        .. "change the file, so you can adjust it without restarting.",
        a.name, path)
    end,
  })

  bog.tools.register("list_panels", {
    description = "List the studio panels the agent has written.",
    input_schema = { type = "object", properties = {} },
    run = function()
      local names = uitools.list()
      if #names == 0 then return "no panels yet" end
      return table.concat(names, "\n")
    end,
  })

  bog.tools.register("read_panel", {
    description = "Read back the source of a studio panel, to modify it.",
    input_schema = {
      type = "object",
      properties = { name = { type = "string" } },
      required = { "name" },
    },
    run = function(a)
      if not valid_name(a and a.name) then
        return "Tool error: [bad_request] bad panel name"
      end
      local src = bog.util.read_file(uitools.path(a.name))
      if not src then return "Tool error: [not_found] no panel '" .. a.name .. "'" end
      return src
    end,
  })

  bog.tools.register("delete_panel", {
    description = "Remove a studio panel.",
    input_schema = {
      type = "object",
      properties = { name = { type = "string" } },
      required = { "name" },
    },
    run = function(a)
      if not valid_name(a and a.name) then
        return "Tool error: [bad_request] bad panel name"
      end
      local path = uitools.path(a.name)
      if not bog.util.read_file(path) then
        return "Tool error: [not_found] no panel '" .. a.name .. "'"
      end
      os.remove(path)
      studio.close_panel(a.name)
      return "removed " .. a.name
    end,
  })

  return true
end

return uitools
