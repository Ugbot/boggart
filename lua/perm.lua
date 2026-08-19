-- perm.lua -- permission modes and approval records for every front end.
--
-- Four useful points, the same ones the studio settled on: never ask, always
-- ask, ask about writes/edits/commands, and do not use tools at all. The TUI
-- and the studio both call policy_for so a mode means the same thing on both
-- surfaces. Shift-Tab cycles; y/n/always resolve a parked ask.
local M = {}

-- Tools that change the world. Read, list and the model's own helpers are not
-- worth interrupting for under "smart".
M.GATED = { write = true, edit = true, bash = true }

M.MODES = {
  { id = "auto",   label = "Autonomous",      help = "tools run without asking" },
  { id = "smart",  label = "Smart approval",  help = "ask before writes, edits and commands" },
  { id = "manual", label = "Manual approval", help = "ask before every tool" },
  { id = "chat",   label = "Chat only",       help = "no tools at all" },
}

local BY_ID = {}
for i, m in ipairs(M.MODES) do BY_ID[m.id] = i end

function M.mode_at(id)
  local i = BY_ID[id or ""]
  return i and M.MODES[i] or M.MODES[2] -- smart
end

function M.cycle(id)
  local i = BY_ID[id or ""] or 2
  local n = M.MODES[(i % #M.MODES) + 1]
  return n.id, n
end

-- What should happen when the model calls `name`: "allow", "ask" or "deny".
-- st may carry approve_all and tool_policy[name] = "allow"|"ask"|"deny".
function M.policy_for(name, st)
  st = st or {}
  local explicit = st.tool_policy and st.tool_policy[name]
  if explicit then return explicit end
  local mode = st.mode or "smart"
  if mode == "chat" then return "deny" end
  if mode == "auto" or st.approve_all then return "allow" end
  if mode == "manual" then return "ask" end
  return M.GATED[name] and "ask" or "allow"
end

-- One-line summary of a tool call, for the approval bar.
function M.summarise(name, input)
  input = input or {}
  if name == "bash" then return tostring(input.command or "") end
  if name == "write" or name == "edit" then return tostring(input.path or "(no path)") end
  local h = input.command or input.path or input.query or input.name or input.title
  return h and tostring(h) or ""
end

local function vis_w(s)
  if sys and sys.width then return sys.width(s) end
  return #(s or "")
end

-- Prefer the studio's patience differ when that module is on the path; the
-- small lua/diff.lua hunk is the TUI fallback. Same record shape either way.
local function load_differ()
  local ok, d = pcall(require, "core.diff")
  if ok and d and d.compute then return d end
  ok, d = pcall(require, "diff")
  if ok and d and d.compute then return d end
  return nil
end

-- Build the record the UI shows and the coroutine waits on. For write/edit
-- this includes a diff of what would happen, so the user can read it first.
function M.request(name, input)
  local rec = { name = name, input = input or {}, decision = nil,
                summary = M.summarise(name, input) }
  if name == "write" or name == "edit" then
    local path = input and input.path
    rec.path = path
    local diff = load_differ()
    if diff then
      local old = (path and bog and bog.util and bog.util.read_file and bog.util.read_file(path)) or ""
      local new
      if name == "write" then
        new = (input and input.content) or ""
      else
        local needle = (input and input.old) or ""
        local first = old:find(needle, 1, true)
        local second = first and old:find(needle, first + 1, true)
        if not first or second then return rec end
        new = old:sub(1, first - 1) .. ((input and input.new) or "")
            .. old:sub(first + #needle)
      end
      rec.diff = diff.compute(old, new)
      rec.summary = diff.summary and diff.summary(rec.diff, path or "(no path)") or rec.summary
    end
  end
  return rec
end

-- Styled run-lines for the approval bar (Contract B).
function M.runs(rec, width)
  width = math.max(8, math.floor(tonumber(width) or 80))
  local ACCENT, TEXT, DIM, GOOD, ERR = "e1e1e6", "97979c", "525257", "7fb77e", "f77483"
  local lines = {}
  local function add(runs) lines[#lines + 1] = runs end
  add({ { text = "approve  ", fg = ACCENT, attr = { bold = true } },
        { text = tostring(rec.name or "tool"), fg = ACCENT },
        { text = rec.path and ("  " .. rec.path) or "", fg = TEXT } })
  local sum = tostring(rec.summary or ""):gsub("\n", " ")
  if #sum > width - 2 then sum = sum:sub(1, width - 5) .. "..." end
  if sum ~= "" then add({ { text = "  " .. sum, fg = TEXT } }) end
  add({ { text = "  y/enter yes   n/esc no   a always   shift-tab mode", fg = DIM } })
  if rec.diff and rec.diff.hunk and not rec.diff.unchanged then
    local n = 0
    for _, row in ipairs(rec.diff.hunk) do
      if n >= 8 then
        add({ { text = "  …", fg = DIM } })
        break
      end
      local kind, text = row[1], row[2] or ""
      local fg = (kind == "+" and GOOD) or (kind == "-" and ERR) or DIM
      local mark = (kind == " " and "  ") or (kind .. " ")
      if vis_w(mark .. text) > width then
        text = (text or ""):sub(1, math.max(0, width - 4))
      end
      add({ { text = mark .. text, fg = fg } })
      n = n + 1
    end
  end
  return lines
end

return M
