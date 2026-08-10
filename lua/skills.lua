-- skills.lua -- a skill is a named bundle of { description, instructions, tools }.
-- Skills live under lua/skills/<name>.lua (embedded defaults, overlay-able under
-- ~/.boggart/lua/skills/). An agent's spec lists skills; resolving them yields
-- the agent's instruction text and its permitted tool allowlist.
local M = {}

function M.load(name)
  local ok, mod = pcall(require, "skills." .. name)
  if ok and type(mod) == "table" then return mod end
  return nil
end

-- resolve(names) -> instructions_text, allow_set
function M.resolve(names)
  local instr, allow = {}, {}
  for _, n in ipairs(names or {}) do
    local s = M.load(n)
    if s then
      if s.instructions and s.instructions ~= "" then
        instr[#instr + 1] = "## Skill: " .. n .. "\n" .. s.instructions
      end
      for _, t in ipairs(s.tools or {}) do allow[t] = true end
    end
  end
  return table.concat(instr, "\n\n"), allow
end

return M
