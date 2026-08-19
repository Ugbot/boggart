-- diff.lua -- a small line differ for reviewing what the agent proposes.
--
-- Trims the common prefix and suffix (two linear scans). Scattered edits
-- become one hunk covering the span -- honest for a review pane. Shape matches
-- termrender's diff entry: { added, removed, hunk = {{kind, text},...}, start_line }.
local M = {}

function M.lines(s)
  local out = {}
  for line in (tostring(s or "") .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  if out[#out] == "" then out[#out] = nil end
  return out
end

function M.compute(old_text, new_text, context)
  context = context or 3
  local a, b = M.lines(old_text), M.lines(new_text)
  local pre = 0
  while pre < #a and pre < #b and a[pre + 1] == b[pre + 1] do pre = pre + 1 end
  local suf = 0
  while suf < (#a - pre) and suf < (#b - pre) and a[#a - suf] == b[#b - suf] do
    suf = suf + 1
  end
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

function M.summary(d, path)
  if d.unchanged then return string.format("%s (no change)", path) end
  return string.format("%s  +%d -%d  at line %d", path, d.added, d.removed, d.start_line)
end

return M
