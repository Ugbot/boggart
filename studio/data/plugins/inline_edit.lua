-- inline_edit.lua -- Cmd-K: edit a selection (or the current line) by an
-- instruction, in place. Select text, press Cmd-K, type "make this async" / "add
-- error handling", and the model rewrites just that span. The result lands as a
-- normal buffer edit AND a change-mark, so it is reviewed/reverted through the
-- same alt+n / alt+r surface as an agent's file edits.
--
-- It makes ONE model call over the raw transport (bog.api.stream_async) rather
-- than a full agent turn: no tools, no telemetry/observation, so it never shows
-- up as a phantom agent in the FLEET roster. Runs as a scheduler coroutine (the
-- studio pumps bog.sched every frame). It never writes to disk -- the edit is in
-- the buffer until you save.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local marks = require "core.marks"

local function doc_text(doc) return table.concat(doc.lines) end

-- Strip a surrounding markdown code fence if the model added one -- fences ONLY,
-- never surrounding whitespace: trimming would delete the first line's indent and
-- could eat a needed trailing newline.
local function unfence(s)
  local body = s:match("^%s*```[%w+%-]*\n(.-)\n?```%s*$")
  return body or s
end

-- Assemble the streamed text from stream_async's assistant message (it also
-- streams to `sink`, but reading the returned blocks is the reliable source).
local function msg_text(msg)
  if type(msg) ~= "table" then return "" end
  if type(msg.content) == "string" then return msg.content end
  local parts = {}
  for _, b in ipairs(msg.content or {}) do
    if type(b) == "table" and b.type == "text" then parts[#parts + 1] = b.text or "" end
  end
  return table.concat(parts)
end

local seq = 0

local function apply_inline_edit(doc, l1, c1, l2, c2, selection, instruction)
  if not (bog and bog.api and bog.api.stream_async and bog.sched) then
    core.error("Cmd-K: agent runtime not available"); return
  end
  local prompt =
    "You are a precise inline editor. Rewrite ONLY the text between <<<START>>> and "
    .. "<<<END>>> per the instruction. Preserve surrounding style and indentation. "
    .. "Output ONLY the rewritten text -- no explanation, no commentary, no code "
    .. "fences.\n\nInstruction: " .. instruction .. "\n\n<<<START>>>\n" .. selection .. "\n<<<END>>>"
  local body = {
    model = bog.session and bog.session.model,
    max_tokens = 4096, system = "",
    messages = { { role = "user", content = prompt } },
    stream = true,
  }
  core.log("Cmd-K: editing selection…")
  seq = seq + 1
  local id = -900000 - seq -- negative: never a thread row, so no FLEET roster entry
  local co = coroutine.create(function()
    local ok, msg = pcall(bog.api.stream_async, body, function() end)
    if not ok then core.error("Cmd-K failed: " .. tostring(msg)); return end
    local out = unfence(msg_text(msg))
    if out == "" then core.error("Cmd-K: no edit produced"); return end

    -- REFUSE-DON'T-GUESS: the model call was async, so the buffer may have moved
    -- (the user typed above the span, or an agent wrote the file). Only apply if
    -- the target span STILL holds exactly the text we sent -- otherwise abort
    -- rather than destroy whatever is there now. Same discipline as marks.revert.
    local now = doc:get_text(l1, c1, l2, c2)
    if now ~= selection then
      core.error("Cmd-K: buffer changed since the edit started — aborted (nothing applied)")
      return
    end
    local before = doc_text(doc)
    doc:remove(l1, c1, l2, c2)
    doc:insert(l1, c1, out)
    local after = doc_text(doc)
    pcall(marks.from_edit, doc, before, after, {})
    core.log("Cmd-K: applied — alt+n to review, alt+r to revert")
  end)
  bog.sched.add(id, co)
end

command.add("core.docview", {
  ["agent:inline-edit"] = function()
    local dv = core.active_view
    local doc = dv and dv.doc
    if not doc then return end
    local l1, c1, l2, c2 = doc:get_selection(true)
    if l1 == l2 and c1 == c2 then       -- no selection: take the whole current line
      c1, c2 = 1, #doc.lines[l1]
      if doc.lines[l1]:sub(-1) == "\n" then c2 = c2 end -- get_text excludes the \n at #line
    end
    local selection = doc:get_text(l1, c1, l2, c2)
    if not selection:match("%S") then return end
    core.command_view:enter("Cmd-K edit", function(instruction)
      if instruction and instruction:match("%S") then
        apply_inline_edit(doc, l1, c1, l2, c2, selection, instruction)
      end
    end)
  end,
})

keymap.add({ ["cmd+k"] = "agent:inline-edit", ["ctrl+k"] = "agent:inline-edit" })
