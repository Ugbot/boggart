-- tui/agents.lua -- the agents-pane renderer for the full-screen chat cTUI.
--
-- A PURE (input -> value) sibling of termrender: it turns a live-agent snapshot
-- into STYLED RUNS -- the same shape termrender.runs returns -- which tui.lua
-- blits into the terminal cell grid. There is no `tc`, no globals, no side
-- effects and no terminal control here, so every branch is unit-testable with no
-- tty (see tests/tui_agents.lua). The one job is layout: fit a header and one
-- row per agent into `width` x `height` cells, colouring each field.
--
--   runs(list, opts) -> lines,  lines = { line, ... },  line = { run, ... }
--   run  = { text=<string>, fg=<"rrggbb"|nil>, bg=<"rrggbb"|nil>,
--            attr={bold?,dim?,italic?,underline?,reverse?}|nil }
-- Concatenating a line's run texts yields that line's plain text, and every
-- visible cell lives in exactly one run -- exactly termrender's Contract B.
local M = {}

-- ---------------------------------------------------------------------------
-- Palette -- the hexes are lifted straight from style.lua so this pane agrees
-- with termrender and the status bar. status colours are the good/amber/dim
-- triad; BAND is style.background2, the same subtle bar the status row uses.
-- ---------------------------------------------------------------------------
local PAL = {
  text   = "97979c",   -- labels, the body text colour
  accent = "e1e1e6",   -- the header
  dim    = "525257",   -- elapsed, notes, the "+n more" line, done/idle
  good   = "7fb77e",   -- status: running
  amber  = "ffa94d",   -- status: waiting
  file   = "93ddfa",   -- a note that looks like a path
}
local BAND = "252529"   -- header background band (= style.background2)

-- status token -> its colour. Anything unknown falls through to dim.
local STATUS_FG = {
  run = PAL.good, wait = PAL.amber, done = PAL.dim, idle = PAL.dim,
}

-- ---------------------------------------------------------------------------
-- Width helpers -- cells, not bytes. A cell is approximated as one codepoint
-- via the stdlib utf8 library (exactly termrender's approximation), so a
-- multibyte char is never split by truncation. vis_len measures; take returns
-- the first n codepoints of s (and, unused here, the remainder).
-- ---------------------------------------------------------------------------
local function vis_len(s)
  if s == "" then return 0 end
  local n = utf8 and utf8.len(s)
  return n or #s
end

local function take(s, n)
  if n <= 0 then return "", s end
  if not utf8 then return s:sub(1, n), s:sub(n + 1) end
  local off = utf8.offset(s, n + 1)
  if not off then return s, "" end
  return s:sub(1, off - 1), s:sub(off)
end

-- ---------------------------------------------------------------------------
-- fit -- pack a list of styled segments ({ text, fg, attr }) into one run-line
-- no wider than `width` cells. When the segments overflow, the line is cut on a
-- codepoint boundary and a dim "..." elision is appended (itself truncated when
-- width < 3, so the line is never wider than the pane). o.bg paints every run
-- with a background; o.pad (with o.bg) fills the remaining cells so the band
-- stripes the full width. Empty segments are dropped, so the surviving runs
-- concatenate back to the visible text.
-- ---------------------------------------------------------------------------
local function fit(segs, width, o)
  o = o or {}
  local bg = o.bg
  width = width or 0
  if width <= 0 then return {} end

  local total = 0
  for _, s in ipairs(segs) do total = total + vis_len(s.text) end

  local runs = {}
  local function emit(text, fg, attr)
    if text ~= "" then runs[#runs + 1] = { text = text, fg = fg, bg = bg, attr = attr } end
  end

  if total <= width then
    for _, s in ipairs(segs) do emit(s.text, s.fg, s.attr) end
    if o.pad and bg and total < width then
      runs[#runs + 1] = { text = string.rep(" ", width - total), bg = bg }   -- fill the band
    end
    return runs
  end

  -- Overflow: keep whole segments while they fit the budget, hard-cut the one
  -- that straddles it, then append the elision.
  local ellw = math.min(3, width)
  local budget, used = width - ellw, 0
  for _, s in ipairs(segs) do
    local l = vis_len(s.text)
    if used + l <= budget then
      emit(s.text, s.fg, s.attr); used = used + l
    else
      local room = budget - used
      if room > 0 then local head = take(s.text, room); emit(head, s.fg, s.attr) end
      break
    end
  end
  runs[#runs + 1] = { text = (take("...", ellw)), fg = PAL.dim, bg = bg }
  return runs
end

-- ---------------------------------------------------------------------------
-- Field formatting.
-- ---------------------------------------------------------------------------

-- Seconds -> "m:ss" (83 -> "1:23"); nil -> "". Negatives clamp to 0:00.
local function mmss(sec)
  if not sec then return "" end
  sec = math.max(0, math.floor(sec))
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- A note reads as a path if it holds a slash or ends in a .extension; such notes
-- get the file colour, everything else stays dim -- kept subtle either way.
local function looks_path(s)
  return s:find("/", 1, true) ~= nil or s:find("%.%w+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Row builders. Each returns a run-line via fit, so each is already clamped to
-- width. Segments carry the plain text verbatim, in the documented field order.
-- ---------------------------------------------------------------------------

-- "AGENTS  <k> running", bold accent over a full-width band.
local function header_line(k, width)
  return fit({ { text = string.format("AGENTS  %d running", k),
                 fg = PAL.accent, attr = { bold = true } } },
             width, { bg = BAND, pad = true })
end

-- "#<id> <label>  <status>  <mm:ss>  <note>", each field its own coloured
-- segment. Missing elapsed/note (and their leading gap) are simply omitted.
local function agent_row(a, width)
  local status = tostring(a.status or "")
  local segs = {
    { text = "#" .. tostring(a.id) .. " ", fg = PAL.dim },
    { text = tostring(a.label or ""),      fg = PAL.text },
    { text = "  " },
    { text = status,                       fg = STATUS_FG[status] or PAL.dim },
  }
  local el = mmss(a.elapsed)
  if el ~= "" then
    segs[#segs + 1] = { text = "  " }
    segs[#segs + 1] = { text = el, fg = PAL.dim }
  end
  if a.note and a.note ~= "" then
    segs[#segs + 1] = { text = "  " }
    segs[#segs + 1] = { text = a.note, fg = looks_path(a.note) and PAL.file or PAL.dim }
  end
  return fit(segs, width)
end

-- The overflow line: "+<n> more", dim.
local function more_line(n, width)
  return fit({ { text = "+" .. tostring(n) .. " more", fg = PAL.dim } }, width)
end

-- ---------------------------------------------------------------------------
-- Public API -- runs(list, opts) -> lines.
--   list = { { id, label, status, elapsed?, note? }, ... }
--   opts = { width, height }   -- pane cell dimensions; height caps the rows.
-- Row 0 is the header; then one row per agent in list order; if the agents do
-- not fit in the remaining height, the last row becomes "+<n> more". An empty
-- list collapses to a single dim "no agents" row (the caller handles either).
-- ---------------------------------------------------------------------------
function M.runs(list, opts)
  list = list or {}
  opts = opts or {}
  local width = opts.width or 80
  local height = opts.height or (#list + 1)   -- nil height == show everything

  if #list == 0 then
    return { fit({ { text = "no agents", fg = PAL.dim } }, width) }
  end

  local k = 0
  for _, a in ipairs(list) do if a.status == "run" then k = k + 1 end end

  local lines = { header_line(k, width) }
  local body = height - 1                      -- rows left for agents after the header
  if body >= 1 then
    if #list <= body then
      for i = 1, #list do lines[#lines + 1] = agent_row(list[i], width) end
    else
      local shown = math.max(0, body - 1)      -- reserve the last row for "+n more"
      for i = 1, shown do lines[#lines + 1] = agent_row(list[i], width) end
      lines[#lines + 1] = more_line(#list - shown, width)
    end
  end
  return lines
end

return M
