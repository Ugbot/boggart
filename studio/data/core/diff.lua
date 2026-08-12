-- diff.lua -- a small line differ, for reviewing what the agent proposes.
--
-- Deliberately not a full Myers implementation. Agent edits are overwhelmingly
-- a contiguous change in a mostly-unchanged file, so trimming the common
-- prefix and suffix identifies the changed span exactly, and costs two linear
-- scans instead of an O(nm) table. Where that assumption fails -- scattered
-- edits across a file -- the result is still correct, just wider than a minimal
-- diff would be: it reports one hunk covering everything between the first and
-- last change. For a review pane that is the honest thing to show anyway.
local diff = {}

function diff.lines(s)
  local out = {}
  for line in (tostring(s or "") .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  if out[#out] == "" then out[#out] = nil end
  return out
end

-- Returns { added, removed, hunk = { {kind, text}, ... } } where kind is
-- " ", "-" or "+". `context` lines are kept either side of the change.
function diff.compute(old_text, new_text, context)
  context = context or 3
  local a, b = diff.lines(old_text), diff.lines(new_text)

  local pre = 0
  while pre < #a and pre < #b and a[pre + 1] == b[pre + 1] do pre = pre + 1 end

  local suf = 0
  while suf < (#a - pre) and suf < (#b - pre)
    and a[#a - suf] == b[#b - suf] do suf = suf + 1 end

  local removed, added = #a - pre - suf, #b - pre - suf
  local hunk = {}

  local from = math.max(1, pre - context + 1)
  for i = from, pre do hunk[#hunk + 1] = { " ", a[i] } end
  for i = pre + 1, pre + removed do hunk[#hunk + 1] = { "-", a[i] } end
  for i = pre + 1, pre + added   do hunk[#hunk + 1] = { "+", b[i] } end
  local tail_from = #a - suf + 1
  for i = tail_from, math.min(#a, tail_from + context - 1) do
    hunk[#hunk + 1] = { " ", a[i] }
  end

  return {
    added = added, removed = removed, hunk = hunk,
    start_line = pre + 1,
    unchanged = (removed == 0 and added == 0),
  }
end

-- ---------------------------------------------------------------------------
-- Where each change is
-- ---------------------------------------------------------------------------

-- Every change region between two versions, in order:
--   { { old = line, old_n = count, new = line, new_n = count }, ... }
-- Line numbers are 1-based and point at the first changed line; a count of
-- zero means the region is a pure insertion (old_n) or deletion (new_n) at
-- that position.
--
-- diff.compute above stays one hunk on purpose -- it feeds a review pane, and
-- a span that is wider than minimal is honest to read. marks.lua is the caller
-- that cannot live with it, because a decoration is anchored to a line number:
-- "everything between the first and last change" meant a file with two
-- one-line edits three hundred lines apart came back as three hundred changed
-- lines, and every mark from an earlier write that sat between them was left
-- where it was instead of moving with the text.
--
-- Patience diff, which is what `git diff --patience` does. A line that occurs
-- exactly once in each version is an unambiguous anchor; the longest
-- increasing run of those anchors splits the problem into independent pieces,
-- and the pieces recurse. That is O(n log n) rather than the O(nm) table a
-- full Myers needs, which matters because the agent rewrites whole files and
-- this runs on the frame's thread.
--
-- Where a region has no unique line in common -- a run of identical
-- boilerplate, a minified file -- there is nothing to anchor on and it comes
-- back as a single hunk. That is exactly the answer diff.compute gives, still
-- correct, just wider.

-- Position of each line that appears exactly once in t[from..to]; a repeated
-- line maps to false.
local function once(t, from, to)
  local at = {}
  for i = from, to do
    local line = t[i]
    if at[line] == nil then at[line] = i else at[line] = false end
  end
  return at
end

-- Longest strictly increasing subsequence of pts by its second component.
-- pts is already ascending in the first, so this is the largest set of anchors
-- that can all be used without crossing.
local function longest_run(pts)
  local tail_val, tail_at, prev = {}, {}, {}
  for k = 1, #pts do
    local want = pts[k][2]
    local lo, hi = 1, #tail_val + 1
    while lo < hi do
      local mid = (lo + hi) // 2
      if tail_val[mid] < want then lo = mid + 1 else hi = mid end
    end
    tail_val[lo], tail_at[lo] = want, k
    prev[k] = lo > 1 and tail_at[lo - 1] or nil
  end
  local out, k = {}, tail_at[#tail_val]
  while k do out[#out + 1] = pts[k]; k = prev[k] end
  for i = 1, #out // 2 do out[i], out[#out - i + 1] = out[#out - i + 1], out[i] end
  return out
end

-- Depth is capped rather than trusted. Each level works on a strictly smaller
-- region, but a pathological file can nest one anchor deep at a time, and a
-- stack overflow inside a draw is not a trade worth making for a tighter diff.
local MAX_DEPTH = 24

local function split_region(a, b, alo, ahi, blo, bhi, out, depth)
  while alo <= ahi and blo <= bhi and a[alo] == b[blo] do alo, blo = alo + 1, blo + 1 end
  while alo <= ahi and blo <= bhi and a[ahi] == b[bhi] do ahi, bhi = ahi - 1, bhi - 1 end
  if alo > ahi and blo > bhi then return end

  local function whole()
    out[#out + 1] = { old = alo, old_n = ahi - alo + 1,
                      new = blo, new_n = bhi - blo + 1 }
  end
  -- One side is empty: a pure insertion or a pure deletion, nothing to anchor.
  if alo > ahi or blo > bhi or depth >= MAX_DEPTH then return whole() end

  local ua, ub = once(a, alo, ahi), once(b, blo, bhi)
  local pts = {}
  for i = alo, ahi do
    local line = a[i]
    if ua[line] == i and ub[line] then pts[#pts + 1] = { i, ub[line] } end
  end
  if #pts == 0 then return whole() end

  local anchors = longest_run(pts)
  local ai, bi = alo, blo
  for _, an in ipairs(anchors) do
    split_region(a, b, ai, an[1] - 1, bi, an[2] - 1, out, depth + 1)
    ai, bi = an[1] + 1, an[2] + 1
  end
  split_region(a, b, ai, ahi, bi, bhi, out, depth + 1)
end

-- Accepts either two strings or two line tables, because the one caller that
-- needs hunks has usually split the text already and splitting it twice is a
-- second pass over the whole file.
function diff.hunks(old_text, new_text)
  local a = type(old_text) == "table" and old_text or diff.lines(old_text)
  local b = type(new_text) == "table" and new_text or diff.lines(new_text)
  local out = {}
  split_region(a, b, 1, #a, 1, #b, out, 0)
  return out
end

-- One-line summary, for the approval prompt.
function diff.summary(d, path)
  if d.unchanged then return string.format("%s (no change)", path) end
  return string.format("%s  +%d -%d  at line %d", path, d.added, d.removed, d.start_line)
end

return diff
