-- uisandbox.lua -- the capability surface for agent-written interface.
--
-- boggart can already write itself new tools, new memory and new skills. It
-- could not write itself new *interface*, which made the window the one part of
-- the system the agent was locked out of. This is the seam that opens it: a
-- panel is a chunk of Lua with a draw function, written by the agent, loaded
-- into a restricted environment, and drawn every frame.
--
-- On format: generated *tools* are persisted as pure data and loaded with an
-- empty environment, because a tool that carried its own `load()` was a real
-- sandbox escape here once. A panel cannot take that route -- the artifact
-- *is* behaviour, and there is no data encoding of "draw this" that is not
-- just a worse programming language. So the boundary moves from the format to
-- the environment: the code is real code, and the environment it runs in
-- decides what real code can reach.
--
-- What a panel can reach: arithmetic, strings, tables, the drawing primitives,
-- the theme, and the widget layer. What it cannot: io, os beyond the clock,
-- require, load, debug, package, coroutine, the filesystem, the network, the
-- credential store, and boggart's own globals. A panel that wants data should
-- be given it by the host, not go and fetch it.
--
-- The threat model is honest about its limits: this stops a generated panel
-- from reading your keys or writing your disk. It does not stop one from
-- drawing something misleading, and it cannot -- drawing is the whole point.
local style = require "core.style"
local common = require "core.common"
local widgets = require "core.widgets"
local diagram = require "core.diagram"

local uisandbox = {}

-- Consecutive errors before a panel is switched off. One bad frame is a typo
-- worth showing; sixty a second is a panel that has to stop, or the window
-- becomes unusable and the agent cannot be told about it.
uisandbox.MAX_ERRORS = 3

local SAFE_STRING = {
  "byte", "char", "find", "format", "gmatch", "gsub", "len", "lower",
  "match", "rep", "reverse", "sub", "upper",
}
local SAFE_TABLE = { "concat", "insert", "remove", "sort", "unpack" }
local SAFE_MATH = {
  "abs", "ceil", "cos", "exp", "floor", "fmod", "huge", "log", "max", "min",
  "modf", "pi", "sin", "sqrt", "tan", "random",
}

local function subset(src, names)
  local t = {}
  for _, k in ipairs(names) do t[k] = src[k] end
  return t
end

-- A read-only proxy, so a panel cannot repaint the whole application by
-- assigning to style.background.
local function readonly(t)
  return setmetatable({}, {
    __index = t,
    __newindex = function() error("this table is read-only", 2) end,
    __metatable = false,
  })
end

function uisandbox.env()
  local env = {
    -- values
    math = subset(math, SAFE_MATH),
    string = subset(string, SAFE_STRING),
    table = subset(table, SAFE_TABLE),
    ipairs = ipairs, pairs = pairs, next = next, select = select,
    tostring = tostring, tonumber = tonumber, type = type,
    pcall = pcall, error = error, assert = assert,
    rawget = rawget, rawequal = rawequal, rawlen = rawlen,
    unpack = table.unpack,
    -- the clock, because a panel that cannot tell the time cannot animate
    os = { time = os.time, clock = os.clock, date = function(f)
      -- No "*t" table form and no second argument: keep it to formatting a
      -- string, which is all a panel needs and is one less shape to reason
      -- about.
      return os.date(type(f) == "string" and f or "%H:%M:%S")
    end },
    -- theme, read-only
    style = readonly(style),
  }
  env._G = env
  return env
end

-- The per-frame drawing context handed to a panel's draw function.
--
-- Deliberately not the raw renderer: every primitive here is clipped to the
-- panel's own rectangle. A panel that miscalculates a coordinate scribbles
-- inside its own box rather than over the conversation.
function uisandbox.context(panel, x, y, w, h, mouse, font)
  local lh = font:get_height() * 1.4
  local hits = {}

  local function clip(rx, ry, rw, rh)
    local x1, y1 = math.max(rx, x), math.max(ry, y)
    local x2, y2 = math.min(rx + rw, x + w), math.min(ry + rh, y + h)
    if x2 <= x1 or y2 <= y1 then return nil end
    return x1, y1, x2 - x1, y2 - y1
  end

  local ctx
  ctx = {
    x = x, y = y, w = w, h = h,
    line_height = lh,
    -- Persisted across frames, so a panel can keep a scroll offset or a
    -- selection without the host caring what is in it.
    state = panel.state,
    mouse = mouse and { x = mouse.x, y = mouse.y } or nil,

    text_width = function(s) return font:get_width(tostring(s or "")) end,

    rect = function(rx, ry, rw, rh, colour)
      local cx, cy, cw, ch = clip(rx or 0, ry or 0, rw or 0, rh or 0)
      if not cx then return end
      renderer.draw_rect(cx, cy, cw, ch, colour or style.text)
    end,

    text = function(s, tx, ty, colour, align, tw)
      s = tostring(s or "")
      if ty + lh < y or ty > y + h then return end   -- off the panel entirely
      common.draw_text(font, colour or style.text, s, align or "left",
        tx, ty, tw or (x + w - tx), lh)
    end,

    -- Interactivity without exposing the event plumbing: the panel asks
    -- whether a button was pressed this frame, and the host has already
    -- decided whether a click happened inside it.
    button = function(label, bx, by, bw)
      label = tostring(label or "")
      local rect = widgets.button(font, label, bx, by, {
        w = bw,
        hover = mouse and widgets.inside(
          { x = bx, y = by, w = bw or widgets.width(font, label),
            h = widgets.height(font) }, mouse.x, mouse.y),
      })
      hits[#hits + 1] = { rect = rect, label = label }
      return panel.clicked == label
    end,

    button_height = function() return widgets.height(font) end,
  }

  -- ---- diagrams ----------------------------------------------------------
  --
  -- Sketchy vector shapes, from rough-lua. A panel gets these as plain
  -- functions rather than a generator object it has to hold: one generator per
  -- panel is created here and kept in the panel, so the wobble is stable
  -- between frames instead of re-rolling sixty times a second.
  --
  -- These do NOT clip: rough emits geometry, and clipping it properly means
  -- clipping every segment. A panel that draws outside its box will draw
  -- outside its box. That is a real limitation and the reason ctx.rect and
  -- ctx.text clip and these do not is worth knowing before you place a
  -- diagram near an edge.
  panel.gen = panel.gen or diagram.generator(panel.seed or 1)
  local gen = panel.gen

  local function offset_points(points)
    local out = {}
    for i, p in ipairs(points or {}) do out[i] = { p[1] + x, p[2] + y } end
    return out
  end

  ctx.line = function(x1, y1, x2, y2, colour, thickness)
    renderer.draw_line(x1, y1, x2, y2, colour or style.text, thickness or 1)
  end
  ctx.sketch_line = function(x1, y1, x2, y2, colour, thickness, o)
    diagram.line(gen, colour or style.text, thickness or 1, x1, y1, x2, y2, o)
  end
  ctx.sketch_rect = function(rx, ry, rw, rh, colour, thickness, o)
    diagram.rect(gen, colour or style.text, thickness or 1, rx, ry, rw, rh, o)
  end
  ctx.sketch_ellipse = function(cx, cy, ew, eh, colour, thickness, o)
    diagram.ellipse(gen, colour or style.text, thickness or 1, cx, cy, ew, eh, o)
  end
  ctx.sketch_circle = function(cx, cy, d, colour, thickness, o)
    diagram.circle(gen, colour or style.text, thickness or 1, cx, cy, d, o)
  end
  ctx.sketch_polygon = function(points, colour, thickness, o)
    diagram.polygon(gen, colour or style.text, thickness or 1, points, o)
  end
  ctx.sketch_path = function(points, colour, thickness, o)
    diagram.path(gen, colour or style.text, thickness or 1, points, o)
  end
  ctx.sketch_curve = function(points, colour, thickness, o)
    diagram.curve(gen, colour or style.text, thickness or 1, points, o)
  end
  ctx.arrow = function(x1, y1, x2, y2, colour, thickness, o)
    diagram.arrow(gen, colour or style.text, thickness or 1, x1, y1, x2, y2, o)
  end
  ctx.box = function(text, bx, by, bw, bh, colour, o)
    diagram.box(gen, font, colour or style.text, text, bx, by, bw, bh, o)
  end
  ctx.offset_points = offset_points

  return ctx, hits
end

-- Compile a panel's source. Returns a draw function, or nil plus the error.
--
-- The source declares a function called `draw(ctx)`; anything else it defines
-- lives in its own environment and persists for as long as the panel does,
-- which is how a panel keeps helpers without a module system.
function uisandbox.compile(name, src)
  local env = uisandbox.env()
  local chunk, err = load(src, "@ui:" .. name, "t", env)
  if not chunk then return nil, tostring(err) end
  local ok, ret = pcall(chunk)
  if not ok then return nil, tostring(ret) end
  local draw = env.draw or (type(ret) == "function" and ret) or nil
  if type(draw) ~= "function" then
    return nil, "the panel defines no draw(ctx) function"
  end
  return draw, nil, env
end

return uisandbox
