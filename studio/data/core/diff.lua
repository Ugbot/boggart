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

-- One-line summary, for the approval prompt.
function diff.summary(d, path)
  if d.unchanged then return string.format("%s (no change)", path) end
  return string.format("%s  +%d -%d  at line %d", path, d.added, d.removed, d.start_line)
end

return diff
