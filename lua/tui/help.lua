-- tui/help.lua -- `?` overlay, too-small terminal, and the shortcut list the
-- footer and overlay share. Studio has shell/shortcuts.lua; this is the TUI
-- sibling, same agent keys.
local M = {}

M.MIN_W, M.MIN_H = 20, 8

M.KEYS = {
  { "Enter",        "send" },
  { "Shift-Enter",  "newline" },
  { "Tab",          "complete / @ / commands" },
  { "Shift-Tab",    "cycle approval mode" },
  { "Esc",          "interrupt a turn / clear draft" },
  { "Ctrl-C",       "interrupt a turn" },
  { "Ctrl-D twice", "quit (empty prompt)" },
  { "Ctrl-Q",       "quit" },
  { "Ctrl-R",       "history search" },
  { "Ctrl-S",       "stash the draft" },
  { "Ctrl-G",       "edit prompt in $VISUAL" },
  { "!",            "run a shell command" },
  { "?",            "this overlay" },
  { "{  }",         "previous / next user prompt" },
  { "Ctrl-O",       "expand / collapse tool strip" },
  { "/clear",       "new conversation" },
  { "/compact",     "summarise context" },
  { "/cost",        "token spend" },
  { "/copy",        "copy last reply" },
  { "/mode",        "approval mode" },
}

function M.too_small(w, h)
  return (tonumber(w) or 0) < M.MIN_W or (tonumber(h) or 0) < M.MIN_H
end

function M.too_small_runs()
  return {
    { { text = "terminal too small", fg = "e1e1e6", attr = { bold = true } } },
    { { text = "resize to at least " .. M.MIN_W .. "x" .. M.MIN_H, fg = "97979c" } },
  }
end

function M.runs(width)
  width = math.max(8, math.floor(tonumber(width) or 80))
  local ACCENT, TEXT, DIM = "e1e1e6", "97979c", "525257"
  local lines = {
    { { text = "shortcuts", fg = ACCENT, attr = { bold = true } },
      { text = "   any key dismisses", fg = DIM } },
  }
  for _, row in ipairs(M.KEYS) do
    local keys, desc = row[1], row[2]
    if #keys + 2 + #desc > width then
      desc = desc:sub(1, math.max(0, width - #keys - 5)) .. "..."
    end
    lines[#lines + 1] = {
      { text = string.format("  %-14s", keys), fg = ACCENT },
      { text = desc, fg = TEXT },
    }
  end
  return lines
end

return M
