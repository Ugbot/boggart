-- diagram.lua -- sketchy vector drawing, on top of core/sketch.lua.
--
-- Why hand-drawn rather than crisp: a diagram an agent produces is a claim
-- about a system, and claims from a model deserve to look provisional. Precise
-- vector output carries an authority the content has not earned. rough.js made
-- this argument for whiteboard tools and it holds here -- a wobbly box reads as
-- "this is my understanding", which is exactly what it is.
--
-- The split: core/sketch.lua emits geometry and knows nothing about drawing;
-- everything here turns move / lineTo / bcurveTo into renderer.draw_line. That
-- means the geometry is testable without a window, and it is.
--
-- Curves are flattened rather than drawn as curves, because the renderer's
-- only vector primitive is a straight line. That is not a limitation worth
-- fixing: at the segment counts below the result is indistinguishable, and
-- every curve rasteriser reduces to the same thing eventually.
local sketch = require "core.sketch"

local diagram = {}

-- The most segments any one cubic is flattened into. Twelve is enough that a
-- curve the size of a window has no visible facets.
diagram.CURVE_STEPS = 12

-- ...but almost nothing needs twelve. Every cubic here is gentle -- a wobble a
-- few pixels off its chord -- and the error of a polyline through a shallow
-- arc falls as the square of the segment count. So: pick the count from how
-- far the curve actually bulges, keeping the error under a third of a pixel.
--
-- This is not a micro-optimisation. A hatched rectangle is a hundred-odd
-- strokes; at twelve segments each that is over a thousand draw_line calls for
-- one shape, and the renderer's command buffer holds about thirteen thousand
-- for the whole frame. Filling five shapes exhausted it -- rendered, watched
-- the shapes stop appearing half way across the panel, and fixed.
local BEZIER_TOLERANCE = 0.3

local function steps_for(x0, y0, x1, y1, x2, y2, x3, y3)
  local dx, dy = x3 - x0, y3 - y0
  local len = math.sqrt(dx * dx + dy * dy)
  local bulge
  if len < 1e-6 then
    -- A loop: no chord to measure against, so use the raw control offsets.
    bulge = math.max(math.abs(x1 - x0) + math.abs(y1 - y0),
                     math.abs(x2 - x0) + math.abs(y2 - y0))
  else
    local nx, ny = -dy / len, dx / len
    bulge = math.max(math.abs((x1 - x0) * nx + (y1 - y0) * ny),
                     math.abs((x2 - x0) * nx + (y2 - y0) * ny))
  end
  local n = math.ceil(math.sqrt(bulge / BEZIER_TOLERANCE))
  if n < 2 then return 2 end
  if n > diagram.CURVE_STEPS then return diagram.CURVE_STEPS end
  return n
end

-- A generator with a fixed seed by default.
--
-- The wobble comes from a PRNG seeded per shape from this seed plus the
-- shape's own coordinates, so a panel redrawn sixty times a second draws the
-- same sketch sixty times rather than sixty different ones. Change the seed to
-- get a different hand.
function diagram.generator(seed)
  return sketch.generator({ seed = seed or 1, roughness = 1.1, bowing = 1 })
end

local function bezier(x0, y0, d, ox, oy, colour, thickness)
  local x1, y1 = d[1] + ox, d[2] + oy
  local x2, y2 = d[3] + ox, d[4] + oy
  local x3, y3 = d[5] + ox, d[6] + oy
  local steps = steps_for(x0, y0, x1, y1, x2, y2, x3, y3)
  local px, py = x0, y0
  for i = 1, steps do
    local t = i / steps
    local u = 1 - t
    local a, b, c, e = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
    local x = a * x0 + b * x1 + c * x2 + e * x3
    local y = a * y0 + b * y1 + c * y2 + e * y3
    renderer.draw_line(px, py, x, y, colour, thickness)
    px, py = x, y
  end
  return x3, y3
end

-- Draw a drawable. `ox, oy` offset it, so a panel can lay a diagram out in its
-- own coordinates and not care where on screen it ended up.
--
-- Fill sets are drawn in the fill colour when one was given, at fillWeight if
-- it was set: hatching an ellipse in the accent colour and outlining it in the
-- text colour is the common case, and drawing both in one colour loses the
-- outline entirely.
function diagram.draw(drawable, colour, thickness, ox, oy)
  if type(drawable) ~= "table" or not drawable.sets then return end
  ox, oy = ox or 0, oy or 0
  thickness = thickness or 1
  local o = drawable.options or {}
  for _, set in ipairs(drawable.sets) do
    local tone, width = colour, thickness
    if set.kind == "fill" then
      if type(o.fill) == "table" then tone = o.fill end
      if type(o.fillWeight) == "number" and o.fillWeight > 0 then
        width = o.fillWeight
      end
    end
    local x, y = 0, 0
    for _, item in ipairs(set.ops) do
      local d = item.data
      if item.op == "move" then
        x, y = d[1] + ox, d[2] + oy
      elseif item.op == "lineTo" then
        local nx, ny = d[1] + ox, d[2] + oy
        renderer.draw_line(x, y, nx, ny, tone, width)
        x, y = nx, ny
      elseif item.op == "bcurveTo" then
        x, y = bezier(x, y, d, ox, oy, tone, width)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- The shapes, as one call each
-- ---------------------------------------------------------------------------
--
-- Each takes the same trailing (colour, thickness, options) so a caller can
-- learn one signature. `options` goes straight to sketch: roughness, bowing,
-- fill, fillStyle ('hachure' | 'solid' | 'zigzag' | 'cross-hatch' | 'dots'),
-- hachureAngle, hachureGap, fillWeight, seed.

local function shape(fn)
  return function(gen, colour, thickness, ...)
    local ok, drawable = pcall(fn, gen, ...)
    if not ok then return nil, drawable end
    diagram.draw(drawable, colour, thickness)
    return drawable
  end
end

diagram.line = shape(function(gen, x1, y1, x2, y2, o)
  return gen:line(x1, y1, x2, y2, o)
end)

diagram.rect = shape(function(gen, x, y, w, h, o)
  return gen:rectangle(x, y, w, h, o)
end)

diagram.ellipse = shape(function(gen, x, y, w, h, o)
  return gen:ellipse(x, y, w, h, o)
end)

diagram.circle = shape(function(gen, x, y, d, o)
  return gen:circle(x, y, d, o)
end)

diagram.polygon = shape(function(gen, points, o)
  return gen:polygon(points, o)
end)

diagram.path = shape(function(gen, points, o)
  return gen:linearPath(points, o)
end)

diagram.curve = shape(function(gen, points, o)
  return gen:curve(points, o)
end)

-- An arrow: a line plus two head strokes. Not in rough's vocabulary, and the
-- single most useful thing in a diagram of a system, since a box with no arrow
-- into it is just a word.
function diagram.arrow(gen, colour, thickness, x1, y1, x2, y2, o)
  diagram.line(gen, colour, thickness, x1, y1, x2, y2, o)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  local ux, uy = dx / len, dy / len
  local head = math.min(14, len / 3)
  local spread = 0.45          -- radians either side
  local cos, sin = math.cos(spread), math.sin(spread)
  for _, s in ipairs { 1, -1 } do
    local hx = -ux * cos + s * (-uy * -sin)
    local hy = -uy * cos + s * (ux * -sin)
    diagram.line(gen, colour, thickness, x2, y2, x2 + hx * head, y2 + hy * head, o)
  end
end

-- A labelled box, which is most of what a diagram of software is.
function diagram.box(gen, font, colour, text, x, y, w, h, o)
  diagram.rect(gen, colour, 1.2, x, y, w, h, o)
  if text and text ~= "" and font then
    local tw = font:get_width(text)
    local th = font:get_height()
    renderer.draw_text(font, text, x + (w - tw) / 2, y + (h - th) / 2, colour)
  end
end

return diagram
