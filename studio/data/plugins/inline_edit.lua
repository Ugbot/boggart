-- inline_edit.lua -- Cmd-K: edit a selection (or the current line) by an
-- instruction, in place. Select text, press Cmd-K, type "make this async" /
-- "add error handling", and the model rewrites just that span.
--
-- The result is PREVIEWED before it lands: the span gets a wash and a
-- floating [apply] [discard] pair (the same marks action row conflicts use)
-- labelled with the +added/-removed line counts, so nothing touches the
-- buffer until you say so. Apply is one discrete undo step
-- (doc:commit_undo), re-verifies the span still holds exactly the text that
-- was sent (refuse-don't-guess, same discipline as marks.revert), and then
-- leaves the change reviewable through the usual alt+n / alt+r surface. A
-- rewrite that changes more than 400 lines skips the preview and applies
-- directly with post-hoc review -- a four-hundred-line wash is noise, not a
-- preview (the NED guiApplyEditToOpenBuffer rule).
--
-- The model call prefers LLM Station's ai_edit over the native ZMQ transport
-- when it is up (lua/stationlink.lua) -- selection + instruction + a
-- ±40-line context window -- and falls back to ONE raw call over boggart's
-- own transport (bog.api.stream_async): no tools, no telemetry, never a
-- phantom agent in the FLEET roster. Runs as a scheduler coroutine; it never
-- writes to disk -- the edit is in the buffer until you save.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local marks = require "core.marks"

local function doc_text(doc) return table.concat(doc.lines) end

-- Strip a surrounding markdown code fence if the model added one -- fences
-- ONLY, never surrounding whitespace: trimming would delete the first line's
-- indent and could eat a needed trailing newline. Models fence even when the
-- prompt forbids it, so this also accepts a missing final newline and a
-- language tag with punctuation (c++, objective-c).
local function unfence(s)
  local body = s:match("^%s*```[%w%+%-%.#]*\r?\n(.-)\r?\n?```%s*$")
  return body or s
end

local function msg_text(msg)
  if type(msg) ~= "table" then return "" end
  if type(msg.content) == "string" then return msg.content end
  local parts = {}
  for _, b in ipairs(msg.content or {}) do
    if type(b) == "table" and b.type == "text" then parts[#parts + 1] = b.text or "" end
  end
  return table.concat(parts)
end

local function split_lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  if out[#out] == "" then out[#out] = nil end
  return out
end

-- Prefix/suffix line diff -- deliberately not Myers: an LLM edit is almost
-- always one contiguous region, so "common head + common tail + one changed
-- middle" is exact in practice and ~15 lines (the NED InlineDiff insight).
local function diff_counts(old_text, new_text)
  local a, b = split_lines(old_text), split_lines(new_text)
  local head = 0
  while head < #a and head < #b and a[head + 1] == b[head + 1] do head = head + 1 end
  local tail = 0
  while tail < #a - head and tail < #b - head
    and a[#a - tail] == b[#b - tail] do tail = tail + 1 end
  return #b - head - tail, #a - head - tail  -- added, removed
end

-- ±40 lines around the span, the context window station's ai_edit grounds on.
local function surrounding(doc, l1, l2)
  local from = math.max(1, l1 - 40)
  local to = math.min(#doc.lines, l2 + 40)
  local parts = {}
  for i = from, to do parts[#parts + 1] = doc.lines[i] end
  return table.concat(parts)
end

local function language_of(doc)
  local ext = doc.filename and doc.filename:match("%.(%w+)$") or ""
  local map = { c = "c", h = "c", cpp = "cpp", hpp = "cpp", cc = "cpp",
    lua = "lua", py = "python", js = "javascript", ts = "typescript",
    go = "go", rs = "rust", java = "java", md = "markdown" }
  return map[ext:lower()] or ext:lower()
end

-- The model call: station ai_edit over ZMQ when the transport is up, one raw
-- streamed call otherwise. Both return the rewritten span text or nil, err.
local function rewrite(doc, l1, l2, selection, instruction)
  local stn = rawget(_G, "bog") and bog.station
  if stn and stn.up and stn.up() then
    local out, err = stn.call("ai_edit", {
      selected_code = selection,
      instruction = instruction,
      context = surrounding(doc, l1, l2),
      language = language_of(doc),
      file_path = doc.filename or "",
    }, { timeout_ms = 120000 })
    if out and out ~= "" then return unfence(out) end
    core.log("Cmd-K: station ai_edit unavailable (%s); using the direct model call",
      tostring(err))
  end

  if not (bog and bog.api and bog.api.stream_async) then
    return nil, "agent runtime not available"
  end
  local prompt =
    "You are a precise inline editor. Rewrite ONLY the text between <<<START>>> and "
    .. "<<<END>>> per the instruction. Preserve surrounding style and indentation. "
    .. "Output ONLY the rewritten text -- no explanation, no commentary, no code "
    .. "fences.\n\nInstruction: " .. instruction .. "\n\n<<<START>>>\n" .. selection .. "\n<<<END>>>"
  local ok, msg = pcall(bog.api.stream_async, {
    model = bog.session and bog.session.model,
    max_tokens = 4096, system = "",
    messages = { { role = "user", content = prompt } },
    stream = true,
  }, function() end)
  if not ok then return nil, tostring(msg) end
  local out = unfence(msg_text(msg))
  if out == "" then return nil, "no edit produced" end
  return out
end

local WASH_PENDING = { style.link[1], style.link[2], style.link[3], 18 }

local cmdk_seq = 0

-- The span still says exactly what we sent -- the buffer may have moved while
-- the model ran (the user typed, an agent wrote the file). Refuse rather than
-- destroy whatever is there now.
local function span_intact(doc, l1, c1, l2, c2, selection)
  return doc:get_text(l1, c1, l2, c2) == selection
end

local function apply_now(doc, l1, c1, l2, c2, selection, out)
  if not span_intact(doc, l1, c1, l2, c2, selection) then
    core.error("Cmd-K: buffer changed since the edit started — aborted (nothing applied)")
    return false
  end
  local before = doc_text(doc)
  doc:commit_undo() -- boundary: the apply must not merge with prior typing
  doc:remove(l1, c1, l2, c2)
  doc:insert(l1, c1, out)
  doc:commit_undo() -- nor with whatever the user types next
  local after = doc_text(doc)
  pcall(marks.from_edit, doc, before, after, {})
  core.log("Cmd-K: applied — alt+n to review, alt+r to revert")
  return true
end

-- Stage the rewrite as a pending preview: washes over the span plus an
-- apply/discard action row on its first line. Nothing in the buffer changes
-- until apply.
local function stage_preview(doc, l1, c1, l2, c2, selection, out, instruction)
  cmdk_seq = cmdk_seq + 1
  local group = "cmdk:" .. cmdk_seq
  local added, removed = diff_counts(selection, out)
  local function clear() marks.clear_group(doc, group) end
  marks.set(doc, l1, {
    kind = "changed", hl = WASH_PENDING, group = group,
    text = string.format("cmd-k +%d -%d  %s", added, removed,
      #instruction > 40 and (instruction:sub(1, 39) .. "…") or instruction),
    data = { actions = {
      { label = "apply", tone = style.good, fn = function()
          clear()
          apply_now(doc, l1, c1, l2, c2, selection, out)
        end },
      { label = "discard", tone = style.warn, fn = function()
          clear()
          core.log("Cmd-K: discarded")
        end },
    } },
  })
  for line = l1 + 1, l2 do
    marks.set(doc, line, { kind = "changed", hl = WASH_PENDING, group = group })
  end
  core.log("Cmd-K: +%d -%d staged — apply or discard on the span", added, removed)
end

local seq = 0

local function run_inline_edit(doc, l1, c1, l2, c2, selection, instruction)
  core.log("Cmd-K: editing selection…")
  seq = seq + 1
  local id = -900000 - seq -- negative: never a thread row, so no FLEET roster entry
  local co = coroutine.create(function()
    local out, err = rewrite(doc, l1, l2, selection, instruction)
    if not out then core.error("Cmd-K failed: " .. tostring(err)) return end
    if not span_intact(doc, l1, c1, l2, c2, selection) then
      core.error("Cmd-K: buffer changed since the edit started — aborted (nothing applied)")
      return
    end
    local _, changed = diff_counts(selection, out)
    if select(2, out:gsub("\n", "")) > 400 or changed > 400 then
      -- A 400-line wash is noise, not a preview: apply with post-hoc review.
      apply_now(doc, l1, c1, l2, c2, selection, out)
    else
      stage_preview(doc, l1, c1, l2, c2, selection, out, instruction)
    end
    core.redraw = true
  end)
  bog.sched.add(id, co)
end

command.add("core.docview", {
  ["agent:inline-edit"] = function()
    local dv = core.active_view
    local doc = dv and dv.doc
    if not doc then return end
    if not (bog and bog.sched) then
      core.error("Cmd-K: agent runtime not available")
      return
    end
    local l1, c1, l2, c2 = doc:get_selection(true)
    if l1 == l2 and c1 == c2 then       -- no selection: take the whole current line
      c1, c2 = 1, #doc.lines[l1]
    end
    local selection = doc:get_text(l1, c1, l2, c2)
    if not selection:match("%S") then return end
    core.command_view:enter("Cmd-K edit", function(instruction)
      if instruction and instruction:match("%S") then
        run_inline_edit(doc, l1, c1, l2, c2, selection, instruction)
      end
    end)
  end,
})

keymap.add({ ["cmd+k"] = "agent:inline-edit", ["ctrl+k"] = "agent:inline-edit" })
