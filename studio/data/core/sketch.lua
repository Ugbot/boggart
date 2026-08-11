-- sketch.lua -- hand-drawn vector geometry: shapes in, stroke ops out.
--
-- Nothing here knows how to draw. core/diagram.lua turns the op stream into
-- renderer.draw_line calls; this file is arithmetic, which is why it can be
-- exercised headlessly with `./boggart --eval` and is.
--
-- ATTRIBUTION. The algorithms are rough.js's (MIT, Copyright (c) 2019 Preet
-- Shihn), which we met through rough-lua (MIT, Copyright (c) 2022-2025
-- Omikhleia, Didier Willis). Licence text: studio/LICENSE-rough. Theirs is the
-- shape of the wobble -- the offset-and-bow line, the cardinal-spline-to-cubic
-- curve, the ellipse point walk, the idea of filling by scanline hachure, and
-- Prigarin's multiplicative PRNG. Ours is every line of code below, the
-- seeding discipline, the scanline fill, the emulated solid fill, and the
-- choice of which seven shapes to keep.
--
-- WHY A REWRITE. rough-lua is a transliteration of JavaScript for SILE. It
-- wanted Penlight in a global called `pl`, and it carried an SVG path parser
-- and four fill styles nothing here calls. Those are merely weight. The reason
-- it had to go is that it threaded its PRNG through the options table, so a
-- generator held between frames advanced its stream on every redraw: three
-- consecutive rectangle() calls on one generator gave three different
-- rectangles (measured, before touching anything). In a UI that redraws sixty
-- times a second that is not "hand drawn", it is vibrating.
--
-- So the one design decision here worth stating: geometry is a pure function
-- of (seed, shape, arguments). Every shape call seeds a fresh PRNG from the
-- generator's seed mixed with the shape's own arguments. A shape is therefore
-- stable across frames and independent of what was drawn before it -- a panel
-- that draws a box only on hover no longer re-rolls everything after it -- and
-- two identical boxes at different positions still differ, because their
-- coordinates are part of the mix.
local sketch = {}

-- ---------------------------------------------------------------------------
-- Deterministic randomness
-- ---------------------------------------------------------------------------

-- Prigarin's multiplicative generator: 2^40 modulus, 5^17 multiplier, cycle
-- 2^38. Taken from rough-lua's prng-prigarin.
--
-- math.random is not usable here even seeded, because it is process-global:
-- one panel's draw order would shift another panel's geometry, and the whole
-- point is that a shape depends on nothing but its own arguments.
local A1, A2 = 727595, 798405            -- 5^17 = 2^20 * A1 + A2
local D20, D40 = 1048576, 1099511627776  -- 2^20, 2^40

local function prng(seed)
  local x1 = seed % D20
  local x2 = 1                           -- the state pair must be odd here
  local function next_value()
    local u = x2 * A2
    local v = (x1 * A2 + x2 * A1) % D20
    v = (v * D20 + u) % D40
    x1 = v // D20
    x2 = v - x1 * D20
    return v / D40
  end
  -- Nearby seeds share their first few outputs' high bits. Diagrams seed from
  -- coordinates, so nearby seeds are the common case, not the rare one.
  next_value(); next_value(); next_value()
  return next_value
end

-- Fold a shape's arguments into its seed (FNV-1a over quantised coordinates).
-- Tenths of a pixel: two boxes half a pixel apart should look like the same
-- box, two boxes a pixel apart need not.
local function mix(seed, args)
  local h = 2166136261 ~ (seed & 0xFFFFFFFF)
  for i = 1, #args do
    local n = tonumber(args[i]) or 0
    -- NaN and absurd coordinates would blow up the float-to-integer
    -- conversion; a diagram that far off screen has no geometry worth seeding.
    if n ~= n or n < -1e6 or n > 1e6 then n = 0 end
    h = (h ~ (math.floor(n * 16) & 0xFFFFFFFF)) * 16777619 & 0xFFFFFFFF
  end
  return h % D20
end

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

-- Names a panel author can set are rough.js's, because that is what the tool
-- description in uitools.lua promises and what anyone who has used rough.js
-- will reach for: roughness, bowing, fill, fillStyle, hachureAngle,
-- hachureGap, strokeWidth, fillWeight, seed.
sketch.defaults = {
  roughness = 1,        -- multiplies every offset; 0 draws exactly
  bowing = 1,           -- how far a line bellies away from straight
  maxOffset = 2,        -- pixels a stroke may miss its endpoint by
  strokeWidth = 1,
  curveTightness = 0,   -- 0 is a plain cardinal spline, 1 is straight lines
  curveFitting = 0.95,  -- how closely an ellipse keeps its nominal radii
  curveSteps = 9,       -- minimum segments around an ellipse
  fill = nil,           -- a colour: presence is what turns filling on
  fillStyle = "hachure",
  fillWeight = -1,      -- negative means "derive from strokeWidth"
  hachureAngle = -41,
  hachureGap = -1,      -- negative means "derive from strokeWidth"
  singleStroke = false, -- true draws outlines once instead of twice
  singleStrokeFill = false,
}

local function resolve(base, o)
  if not o then return base end
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(o) do out[k] = v end
  return out
end

-- ---------------------------------------------------------------------------
-- Stroke primitives
-- ---------------------------------------------------------------------------

local function jitter(rng, o, amount, gain)
  return o.roughness * (gain or 1) * ((rng() * 2 - 1) * amount)
end

-- One stroke of a line: a cubic that bellies away from the straight path and
-- lands near, not on, the endpoints.
--
-- `overlay` is the second pass of a double stroke -- half the wobble, so the
-- pair reads as one line drawn twice rather than two lines. `move` emits the
-- pen-up; a caller that has already positioned the pen passes false.
local function stroke_line(ops, rng, o, x1, y1, x2, y2, move, overlay)
  local len_sq = (x1 - x2) ^ 2 + (y1 - y2) ^ 2
  local len = math.sqrt(len_sq)

  -- A hand steadies over distance: long lines wobble proportionally less.
  local gain
  if len < 200 then gain = 1
  elseif len > 500 then gain = 0.4
  else gain = 1.233334 - 0.0016668 * len end

  local off = o.maxOffset
  if off * off * 100 > len_sq then off = len / 10 end
  local amount = overlay and off / 2 or off

  local diverge = 0.2 + rng() * 0.2
  local mid_x = jitter(rng, o, o.bowing * o.maxOffset * (y2 - y1) / 200, gain)
  local mid_y = jitter(rng, o, o.bowing * o.maxOffset * (x1 - x2) / 200, gain)

  -- Drawn into a table first, and always eight of them whether or not `move`
  -- uses two: the order a Lua implementation evaluates a table constructor's
  -- fields in is not specified, and identical geometry across runs is the
  -- whole contract of this file.
  local w = {}
  for i = 1, 8 do w[i] = jitter(rng, o, amount, gain) end

  if move then
    ops[#ops + 1] = { op = "move", data = { x1 + w[1], y1 + w[2] } }
  end
  ops[#ops + 1] = { op = "bcurveTo", data = {
    mid_x + x1 + (x2 - x1) * diverge + w[3],
    mid_y + y1 + (y2 - y1) * diverge + w[4],
    mid_x + x1 + (x2 - x1) * diverge * 2 + w[5],
    mid_y + y1 + (y2 - y1) * diverge * 2 + w[6],
    x2 + w[7],
    y2 + w[8],
  } }
end

-- The default stroke: twice over, which is what makes it look drawn.
local function double_line(ops, rng, o, x1, y1, x2, y2, filling)
  local once = filling and o.singleStrokeFill or o.singleStroke
  stroke_line(ops, rng, o, x1, y1, x2, y2, true, false)
  if not once then
    stroke_line(ops, rng, o, x1, y1, x2, y2, true, true)
  end
end

-- A cardinal spline through `pts`, emitted as cubics. Under four points there
-- is no spline to fit, so three degenerate to one cubic and two to a line.
local function stroke_curve(ops, rng, o, pts, close_to)
  local n = #pts
  if n > 3 then
    local s = 1 - o.curveTightness
    ops[#ops + 1] = { op = "move", data = { pts[1][1], pts[1][2] } }
    for i = 2, n - 2 do
      local p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
      ops[#ops + 1] = { op = "bcurveTo", data = {
        p1[1] + s * (p2[1] - p0[1]) / 6, p1[2] + s * (p2[2] - p0[2]) / 6,
        p2[1] + s * (p1[1] - p3[1]) / 6, p2[2] + s * (p1[2] - p3[2]) / 6,
        p2[1], p2[2],
      } }
    end
    if close_to then
      local dx = jitter(rng, o, o.maxOffset)
      local dy = jitter(rng, o, o.maxOffset)
      ops[#ops + 1] = { op = "lineTo", data = { close_to[1] + dx, close_to[2] + dy } }
    end
  elseif n == 3 then
    ops[#ops + 1] = { op = "move", data = { pts[1][1], pts[1][2] } }
    ops[#ops + 1] = { op = "bcurveTo", data = {
      pts[1][1], pts[1][2], pts[2][1], pts[2][2], pts[3][1], pts[3][2],
    } }
  elseif n == 2 then
    stroke_line(ops, rng, o, pts[1][1], pts[1][2], pts[2][1], pts[2][2], true, true)
  end
end

-- Jitter every point, and duplicate the first and last: a cardinal spline
-- starts one point in from each end, and a curve that ignores the points you
-- gave it is not the curve you asked for.
local function loosen(rng, o, pts, amount)
  local out = {}
  local function push(p)
    local dx = jitter(rng, o, amount)
    local dy = jitter(rng, o, amount)
    out[#out + 1] = { p[1] + dx, p[2] + dy }
  end
  if #pts == 0 then return out end
  push(pts[1])
  push(pts[1])
  for i = 2, #pts do push(pts[i]) end
  push(pts[#pts])
  return out
end

-- ---------------------------------------------------------------------------
-- Ellipses
-- ---------------------------------------------------------------------------

-- Segment count scales with the perimeter, so a small circle is not
-- over-tessellated and a large one does not go faceted.
local function ellipse_params(rng, o, w, h)
  local psq = math.sqrt(math.pi * 2 * math.sqrt(((w / 2) ^ 2 + (h / 2) ^ 2) / 2))
  local steps = math.ceil(math.max(o.curveSteps, o.curveSteps / math.sqrt(200) * psq))
  local rx = math.abs(w / 2)
  local ry = math.abs(h / 2)
  local slack = 1 - o.curveFitting
  rx = rx + jitter(rng, o, rx * slack)
  ry = ry + jitter(rng, o, ry * slack)
  return math.pi * 2 / steps, rx, ry
end

-- Walks the ellipse once and returns two lists: every point the spline needs
-- (including the lead-in and the overshoot past the start, which is what makes
-- the ends cross like a pen not quite closing a circle) and just the points on
-- the true outline, which is what a fill wants.
local function ellipse_points(rng, o, inc, cx, cy, rx, ry, amount, overlap)
  local all, outline = {}, {}
  local start = jitter(rng, o, 0.5) - math.pi / 2

  local function at(scale, angle)
    local dx = jitter(rng, o, amount)
    local dy = jitter(rng, o, amount)
    return {
      dx + cx + scale * rx * math.cos(angle),
      dy + cy + scale * ry * math.sin(angle),
    }
  end

  all[1] = at(0.9, start - inc)
  -- Stop a hair short of a full turn so a step landing exactly on the start
  -- does not emit a duplicate point.
  for angle = start, math.pi * 2 + start - 0.01, inc do
    local p = at(1, angle)
    outline[#outline + 1] = p
    all[#all + 1] = p
  end
  all[#all + 1] = at(1, start + math.pi * 2 + overlap * 0.5)
  all[#all + 1] = at(0.98, start + overlap)
  all[#all + 1] = at(0.9, start + overlap * 0.5)
  return all, outline
end

-- ---------------------------------------------------------------------------
-- Fills
-- ---------------------------------------------------------------------------

-- A shape big enough to need more scanlines than this is a shape whose fill
-- nobody can see; the cap keeps a typo in hachureGap from hanging a frame.
local MAX_SCANLINES = 4000

-- Parallel lines at `angle_deg` covering the polygons, `gap` apart.
--
-- Rotate so the hachure direction is horizontal, walk scanlines across, pair
-- up the crossings, rotate the spans back. Rewritten from rough-lua's
-- active-edge-table version, which rotated the caller's own point tables in
-- place and rotated them back afterwards (with the drift that implies) and
-- appended a closing vertex to the array it had been handed.
local function hachure_lines(polygons, gap, angle_deg)
  local a = math.rad(angle_deg)
  local cos, sin = math.cos(a), math.sin(a)
  gap = math.max(gap, 0.1)

  local edges = {}
  local top, bottom = math.huge, -math.huge
  for _, poly in ipairs(polygons) do
    local n = #poly
    if n > 2 then
      local rot = {}
      for i = 1, n do
        local p = poly[i]
        rot[i] = { p[1] * cos + p[2] * sin, -p[1] * sin + p[2] * cos }
      end
      for i = 1, n do
        local p1, p2 = rot[i], rot[i % n + 1]
        if p1[2] ~= p2[2] then
          local ymin = math.min(p1[2], p2[2])
          local ymax = math.max(p1[2], p2[2])
          edges[#edges + 1] = {
            ymin = ymin,
            ymax = ymax,
            x = (ymin == p1[2]) and p1[1] or p2[1],
            slope = (p2[1] - p1[1]) / (p2[2] - p1[2]),
          }
          if ymin < top then top = ymin end
          if ymax > bottom then bottom = ymax end
        end
      end
    end
  end
  if #edges == 0 then return {} end

  local lines = {}
  local y = top + gap * 0.5   -- half a gap in: a scanline through the topmost
  local scanned = 0           -- vertex crosses one edge and fills nothing
  while y < bottom and scanned < MAX_SCANLINES do
    scanned = scanned + 1
    local xs = {}
    for _, e in ipairs(edges) do
      -- Half-open in y so a vertex shared by two edges is counted once and the
      -- crossings stay even.
      if e.ymin <= y and y < e.ymax then
        xs[#xs + 1] = e.x + (y - e.ymin) * e.slope
      end
    end
    table.sort(xs)
    for i = 1, #xs - 1, 2 do
      local x1, x2 = xs[i], xs[i + 1]
      if x2 - x1 > 0.01 then
        lines[#lines + 1] = {
          { x1 * cos - y * sin, x1 * sin + y * cos },
          { x2 * cos - y * sin, x2 * sin + y * cos },
        }
      end
    end
    y = y + gap
  end
  return lines
end

local function hachure_gap(o)
  local gap = o.hachureGap
  if gap < 0 then gap = o.strokeWidth * 4 end
  return math.max(gap, 0.1)
end

local function fill_weight(o)
  local weight = o.fillWeight
  if weight < 0 then weight = o.strokeWidth / 2 end
  return weight
end

local function fill_hachure(rng, o, polygons, angle)
  local ops = {}
  for _, ln in ipairs(hachure_lines(polygons, hachure_gap(o), angle)) do
    double_line(ops, rng, o, ln[1][1], ln[1][2], ln[2][1], ln[2][2], true)
  end
  return ops
end

-- Each hachure line becomes two strokes meeting at its far end, so successive
-- lines read as a scribble rather than a comb. rough.js's zigzag, kept because
-- the alternative -- a continuous boustrophedon -- draws outside any shape
-- whose scanline crosses it more than twice.
local function fill_zigzag(rng, o, polygons)
  -- Half again the hachure gap unless asked otherwise: each line here becomes
  -- two strokes, so at the hachure spacing the V's close up and the fill is
  -- indistinguishable from solid. Checked by rendering it.
  local gap = o.hachureGap < 0 and o.strokeWidth * 6 or o.hachureGap
  gap = math.max(gap, 0.1)
  local a = math.rad(o.hachureAngle)
  local dx = gap * 0.5 * math.cos(a)
  local dy = gap * 0.5 * math.sin(a)
  local ops = {}
  for _, ln in ipairs(hachure_lines(polygons, gap, o.hachureAngle)) do
    local p1, p2 = ln[1], ln[2]
    double_line(ops, rng, o, p1[1] - dx, p1[2] + dy, p2[1], p2[2], true)
    double_line(ops, rng, o, p1[1] + dx, p1[2] - dy, p2[1], p2[2], true)
  end
  return ops
end

-- A dot drawn out of nothing but horizontal strokes. At the two-or-three pixel
-- radius a fill uses, a proper circle would cost a nine-segment bezier and
-- look no different.
local function dot(ops, cx, cy, r)
  local rows = math.max(1, math.floor(r * 2))   -- one stroke per pixel of height
  for i = 1, rows do
    local dy = -r + (i - 0.5) * (2 * r / rows)  -- row centres, so no zero-length
    local half = math.sqrt(math.max(0, r * r - dy * dy))
    ops[#ops + 1] = { op = "move", data = { cx - half, cy + dy } }
    ops[#ops + 1] = { op = "lineTo", data = { cx + half, cy + dy } }
  end
end

-- rough-lua placed its dots with math.random, which is process-global and
-- undid the whole seeding discipline: a dotted fill re-rolled every frame.
-- This uses the shape's own stream, so it holds still.
local function fill_dots(rng, o, polygons)
  -- Twice the hachure gap unless asked otherwise: at the four pixels a hachure
  -- wants, dots of any visible size touch, and the fill reads as a smear. It
  -- also quarters the dot count, which matters -- a dot is several strokes.
  local gap = o.hachureGap < 0 and o.strokeWidth * 8 or o.hachureGap
  gap = math.max(gap, 0.1)
  -- Horizontal rows regardless of hachureAngle: an angled dot grid reads as
  -- stripes rather than as dots.
  local lines = hachure_lines(polygons, gap, 0)
  -- Below about a pixel and a half a dot is a faint smudge, so this is a floor
  -- and not the requested weight. Set fillWeight if you want bigger.
  local r = math.max(fill_weight(o), 1.5)
  local wander = gap / 4
  local ops = {}
  for _, ln in ipairs(lines) do
    local x1 = math.min(ln[1][1], ln[2][1])
    local len = math.abs(ln[2][1] - ln[1][1])
    local count = math.max(1, math.floor(len / gap))
    local lead = (len - (count - 1) * gap) / 2
    for i = 0, count - 1 do
      local jx = (rng() * 2 - 1) * wander
      local jy = (rng() * 2 - 1) * wander
      dot(ops, x1 + lead + i * gap + jx, ln[1][2] + jy, r)
    end
  end
  return ops
end

-- 'solid' is emulated. The renderer's only vector primitive is a line, so a
-- solid fill is horizontal scanlines a pixel apart with no wobble at all --
-- genuinely opaque, but one op pair per pixel of height. Use ctx.rect for
-- large flat areas and keep this for small emphasis.
local function fill_solid(o, polygons)
  local step = o.fillWeight > 0 and o.fillWeight or 1
  local ops = {}
  for _, ln in ipairs(hachure_lines(polygons, math.max(step, 1), 0)) do
    ops[#ops + 1] = { op = "move", data = { ln[1][1], ln[1][2] } }
    ops[#ops + 1] = { op = "lineTo", data = { ln[2][1], ln[2][2] } }
  end
  return ops
end

local function fill_ops(rng, o, polygons)
  local style = o.fillStyle or "hachure"
  if style == "solid" then
    return fill_solid(o, polygons)
  elseif style == "zigzag" then
    return fill_zigzag(rng, o, polygons)
  elseif style == "dots" then
    return fill_dots(rng, o, polygons)
  elseif style == "cross-hatch" then
    local ops = fill_hachure(rng, o, polygons, o.hachureAngle)
    for _, op in ipairs(fill_hachure(rng, o, polygons, o.hachureAngle + 90)) do
      ops[#ops + 1] = op
    end
    return ops
  end
  return fill_hachure(rng, o, polygons, o.hachureAngle)
end

-- ---------------------------------------------------------------------------
-- The generator
-- ---------------------------------------------------------------------------
--
-- A drawable is { shape, options, sets }, and a set is { kind, ops } where
-- kind is "fill" or "stroke" and ops are { op = "move" | "lineTo" |
-- "bcurveTo", data = { ... } }. Fill sets come first so the outline lands on
-- top of its own hatching.

local Generator = {}
Generator.__index = Generator

-- `options` here are the generator's defaults; every shape may override them.
function sketch.generator(options)
  return setmetatable({
    options = resolve(sketch.defaults, options),
  }, Generator)
end

function Generator:_opts(options)
  return options and resolve(self.options, options) or self.options
end

-- `tag` distinguishes shapes that would otherwise hash the same numbers.
function Generator:_rng(o, tag, args)
  args[#args + 1] = tag
  return prng(mix(math.floor(o.seed or 0), args))
end

local function drawable(shape, o, sets)
  return { shape = shape, options = o, sets = sets }
end

-- Builds the sets for a closed shape: fill first if asked for, then the
-- outline unless the caller has explicitly turned it off.
local function closed_sets(rng, o, fill_polygon, outline_ops)
  local sets = {}
  if o.fill then
    sets[#sets + 1] = { kind = "fill", ops = fill_ops(rng, o, { fill_polygon }) }
  end
  if o.stroke ~= "none" then
    sets[#sets + 1] = { kind = "stroke", ops = outline_ops }
  end
  return sets
end

function Generator:line(x1, y1, x2, y2, options)
  local o = self:_opts(options)
  local rng = self:_rng(o, 1, { x1, y1, x2, y2 })
  local ops = {}
  double_line(ops, rng, o, x1, y1, x2, y2)
  return drawable("line", o, { { kind = "stroke", ops = ops } })
end

local function flatten(points)
  local args = {}
  for _, p in ipairs(points) do
    args[#args + 1] = p[1]
    args[#args + 1] = p[2]
  end
  return args
end

local function path_ops(rng, o, points, close)
  local ops = {}
  local n = #points
  for i = 1, n - 1 do
    double_line(ops, rng, o, points[i][1], points[i][2],
      points[i + 1][1], points[i + 1][2])
  end
  if close and n > 2 then
    double_line(ops, rng, o, points[n][1], points[n][2],
      points[1][1], points[1][2])
  end
  return ops
end

-- An open polyline.
function Generator:linearPath(points, options)
  local o = self:_opts(options)
  if #points < 2 then return drawable("linearPath", o, {}) end
  local rng = self:_rng(o, 2, flatten(points))
  return drawable("linearPath", o,
    { { kind = "stroke", ops = path_ops(rng, o, points, false) } })
end

function Generator:polygon(points, options)
  local o = self:_opts(options)
  if #points < 2 then return drawable("polygon", o, {}) end
  local rng = self:_rng(o, 3, flatten(points))
  local outline = path_ops(rng, o, points, true)
  return drawable("polygon", o, closed_sets(rng, o, points, outline))
end

function Generator:rectangle(x, y, w, h, options)
  local o = self:_opts(options)
  local rng = self:_rng(o, 4, { x, y, w, h })
  local points = { { x, y }, { x + w, y }, { x + w, y + h }, { x, y + h } }
  local outline = path_ops(rng, o, points, true)
  return drawable("rectangle", o, closed_sets(rng, o, points, outline))
end

-- x, y is the centre, w and h the full width and height.
function Generator:ellipse(x, y, w, h, options)
  local o = self:_opts(options)
  local rng = self:_rng(o, 5, { x, y, w, h })
  local inc, rx, ry = ellipse_params(rng, o, w, h)
  -- The second pass overshoots the start by a random arc; the first does not,
  -- so the two strokes cross rather than tracing each other.
  local overlap = inc * (0.1 + rng() * 0.3)
  local all, outline = ellipse_points(rng, o, inc, x, y, rx, ry, 1, overlap)
  local ops = {}
  stroke_curve(ops, rng, o, all)
  if not o.singleStroke and o.roughness ~= 0 then
    local again = ellipse_points(rng, o, inc, x, y, rx, ry, 1.5, 0)
    stroke_curve(ops, rng, o, again)
  end
  return drawable("ellipse", o, closed_sets(rng, o, outline, ops))
end

function Generator:circle(x, y, diameter, options)
  local d = self:ellipse(x, y, diameter, diameter, options)
  d.shape = "circle"
  return d
end

-- A smooth curve through the points. A filled curve is filled through the
-- control points rather than the drawn curve, so the fill sits slightly inside
-- a bulge and slightly outside a dip; good enough for a shaded region, not for
-- anything that has to line up.
function Generator:curve(points, options)
  local o = self:_opts(options)
  if #points < 2 then return drawable("curve", o, {}) end
  local rng = self:_rng(o, 6, flatten(points))
  local ops = {}
  stroke_curve(ops, rng, o, loosen(rng, o, points, 1 + o.roughness * 0.2))
  if not o.singleStroke then
    stroke_curve(ops, rng, o, loosen(rng, o, points, 1.5 + o.roughness * 0.33))
  end
  local sets = {}
  if o.fill and #points > 2 then
    sets[#sets + 1] = { kind = "fill", ops = fill_ops(rng, o, { points }) }
  end
  sets[#sets + 1] = { kind = "stroke", ops = ops }
  return drawable("curve", o, sets)
end

return sketch
