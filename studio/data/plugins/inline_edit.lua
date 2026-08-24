-- inline_edit.lua -- Cmd-K: edit a selection (or the current line) by an
-- instruction, in place. This is the authoring-assist half boggart's editor
-- lacked: select text, press Cmd-K, type "make this async" / "add error
-- handling", and the model rewrites just that span. The result lands as a normal
-- buffer edit AND a change-mark, so it is reviewed and reverted through the same
-- accept/revert surface (alt+n / alt+r) as an agent's file edits.
--
-- Chat-only, tool-free, on a throwaway session: it rewrites the span and nothing
-- else. It never writes to disk -- the edit is in the buffer until you save.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local marks = require "core.marks"

local function doc_text(doc) return table.concat(doc.lines) end

-- Strip a leading/trailing markdown code fence if the model wrapped its output.
local function unfence(s)
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("^```[%w+%-]*\n?", ""):gsub("\n?```$", "")
  return s
end

local function apply_inline_edit(doc, l1, c1, l2, c2, selection, instruction)
  local scratch = { model = (bog.session and bog.session.model), messages = {}, max_tokens = 4000 }
  local prompt =
    "You are an inline editor. Rewrite ONLY the text between <<<START>>> and <<<END>>> "
    .. "according to the instruction. Preserve surrounding style and indentation. Output "
    .. "ONLY the rewritten text -- no explanation, no commentary, no code fences.\n\n"
    .. "Instruction: " .. instruction .. "\n\n<<<START>>>\n" .. selection .. "\n<<<END>>>"
  local buf = {}
  local co = coroutine.create(function()
    local ok = pcall(bog.api.run_on, scratch, prompt,
      function(chunk) buf[#buf + 1] = chunk end,
      { tools = function() return {} end, run_id = 0, system = function() return "" end })
    local out = unfence(table.concat(buf))
    if not ok or out == "" then core.error("Cmd-K: no edit produced"); return end
    -- Apply the span replacement, then lay a change-mark over it (before/after
    -- full-buffer text is what marks.from_edit diffs).
    local before = doc_text(doc)
    doc:remove(l1, c1, l2, c2)
    doc:insert(l1, c1, out)
    local after = doc_text(doc)
    pcall(marks.from_edit, doc, before, after, {})
    core.log("Cmd-K: edit applied — alt+n to review, alt+r to revert")
  end)
  if bog and bog.sched and bog.sched.add then
    bog.sched.add(math.floor(9990000 + (os.clock() * 1000) % 90000), co)
  else
    coroutine.resume(co)
  end
end

command.add("core.docview", {
  ["agent:inline-edit"] = function()
    local dv = core.active_view
    local doc = dv and dv.doc
    if not doc then return end
    if not (bog and bog.api and bog.api.run_on) then
      core.error("Cmd-K: agent runtime not available"); return
    end
    local l1, c1, l2, c2 = doc:get_selection(true)
    if l1 == l2 and c1 == c2 then       -- no selection: take the whole current line
      c1, c2 = 1, #doc.lines[l1]
    end
    local selection = doc:get_text(l1, c1, l2, c2)
    if selection == "" then return end
    core.command_view:enter("Cmd-K edit", function(instruction)
      if instruction and instruction:match("%S") then
        apply_inline_edit(doc, l1, c1, l2, c2, selection, instruction)
      end
    end)
  end,
})

keymap.add({ ["cmd+k"] = "agent:inline-edit", ["ctrl+k"] = "agent:inline-edit" })
