-- ctxgraph/stubs.lua -- one outline line per record, by rule (assumption 9).
--
-- Never a model call: a stub must be cheap, the same whichever model is
-- running, and byte-identical for the same input, because the outline is part
-- of the cached prompt prefix. So nothing here may depend on table iteration
-- order, the clock or the locale: arguments are rendered from sorted keys,
-- and every cut is at a fixed byte count (backed off to a UTF-8 boundary).
local M = {}

-- First line of `s`, at most `n` bytes, never splitting a UTF-8 character.
function M.line(s, n)
  local l = tostring(s or ""):match("^%s*([^\n]*)") or ""
  l = l:gsub("%s+$", "")
  if #l <= n then return l end
  local cut = n - 3
  while cut > 0 and ((l:byte(cut + 1) or 0) & 0xC0) == 0x80 do cut = cut - 1 end
  return l:sub(1, cut) .. "..."
end

-- Arguments of a call we have no rule for, as k=v from sorted keys.
local function args_of(input)
  if type(input) ~= "table" then return "" end
  local keys = {}
  for k, v in pairs(input) do
    if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then keys[#keys + 1] = tostring(k) end
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. M.line(tostring(input[k]), 40) end
  return table.concat(parts, " ")
end

local ARG = {
  bash = function(i) return i.command end,
  read = function(i) return i.path end, write = function(i) return i.path end,
  edit = function(i) return i.path end, list = function(i) return i.path or "." end,
  spawn = function(i) return i.task end,
  expand = function(i) return i.id end, graph_recall = function(i) return i.query end,
  note = function(i) return i.text end,
}

-- The outcome of one call, from its result text.
function M.outcome(call, ex)
  local r = call.result or ""
  if call.name == "bash" then
    local code, to = ex.exit_code(r)
    if code == nil then return call.is_error and ("error: " .. M.line(ex.error_line(r) or r, 60)) or "ok" end
    local s = "exit " .. code .. (to and " (timed out)" or "")
    if code ~= 0 then
      local l = ex.error_line(r)
      if l then s = s .. ": " .. M.line(l, 60) end
    end
    return s
  end
  if call.is_error then return "error: " .. M.line(ex.error_line(r) or r, 60) end
  if call.name == "read" then
    local n = r:match("^%S+ lines %d+%-%d+ of (%d+)")
    return n and (n .. " lines") or "ok"
  end
  if call.name == "write" then
    local n = r:match("%(%d+ bytes, (%d+) lines%)")
    return n and (n .. " lines") or "ok"
  end
  return "ok"
end

-- step: `tool: args -> outcome`, one clause per call.
function M.step(step, ex)
  if step.kind == "prompt" then return "user: " .. M.line(step.text, 100) end
  if #step.calls == 0 then return "reply: " .. M.line(step.text, 100) end
  local parts = {}
  for _, c in ipairs(step.calls) do
    local a = ARG[c.name] and ARG[c.name](c.input or {}) or args_of(c.input)
    parts[#parts + 1] = c.name .. ": " .. M.line(a or "", 60) .. " -> " .. M.outcome(c, ex)
  end
  local s = table.concat(parts, "; ")
  return M.line(s, 240)
end

-- span: its first step's intent, the step count, the outcome and what it touched.
function M.span(span)
  local first = span.steps[1]
  local intent = first.text and first.text ~= "" and M.line(first.text, 80) or M.line(first.stub, 80)
  local last = span.steps[#span.steps]
  local outcome = last.failed and ("failed: " .. M.line(last.stub, 70)) or "ok"
  local s = string.format("%s; %d step%s; %s", intent, #span.steps, #span.steps == 1 and "" or "s", outcome)
  if span.retry then s = s .. string.format("; retried `%s` x%d", M.line(span.retry.title, 40), span.retry.count) end
  if #span.touched > 0 then
    local shown = {}
    for i = 1, math.min(4, #span.touched) do shown[i] = span.touched[i] end
    s = s .. "; touches " .. table.concat(shown, ", ")
    if #span.touched > 4 then s = s .. string.format(" (+%d)", #span.touched - 4) end
  end
  return s
end

-- Entities: from their frontmatter, so a stub is a pure function of the record.
function M.entity(r)
  local f = r.frontmatter or {}
  if r.type == "file" then
    local lines = f.lines and (f.lines .. " lines") or "size unknown"
    if (f.versions or 0) > 0 then
      return string.format("%s v%d, %s, last change: %s at step %d", f.path, f.versions, lines,
        f.last_op or "edit", f.last_change or 0)
    end
    return string.format("%s, %s, read at step %d", f.path, lines, f.last_step or 0)
  elseif r.type == "package" then
    return string.format("%s package %s%s: %s at step %d", f.manager, f.name,
      f.version and ("==" .. f.version) or "", f.state or "requested", f.last_step or 0)
  elseif r.type == "command" then
    return string.format("`%s` x%d, last exit %s", M.line(f.command, 80), f.runs or 1,
      f.last_exit ~= nil and tostring(f.last_exit) or "?")
  elseif r.type == "test" then
    return string.format("%s: %s at step %d (%d run%s)", f.runner, f.last or "run", f.last_step or 0,
      f.runs or 1, (f.runs or 1) == 1 and "" or "s")
  elseif r.type == "error" then
    return string.format("\"%s\" x%d, last at step %d", M.line(f.line, 120), f.count or 1, f.last_step or 0)
  elseif r.type == "thread" then
    return "spawned: " .. M.line(f.task, 80) .. (f.result and (" -> " .. M.line(f.result, 60)) or "")
  elseif r.type == "version" then
    return string.format("%s v%d by %s at step %d", f.path, f.v or 0, f.op or "edit", f.step or 0)
  end
  return M.line(r.title, 100)
end

function M.claim(r)
  return "[" .. (r.state or "unverified") .. "] " .. M.line(r.title, 140)
end

return M
