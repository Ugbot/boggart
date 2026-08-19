local common = require "core.common"

local syntax = {}
syntax.items = {}

local plain_text_syntax = { patterns = {}, symbols = {} }


function syntax.add(t)
  table.insert(syntax.items, t)
end


local function find(string, field)
  for i = #syntax.items, 1, -1 do
    local t = syntax.items[i]
    if common.match_pattern(string, t[field] or {}) then
      return t
    end
  end
end

function syntax.get(filename, header)
  -- header is optional: the agent panel asks only by filename ("code.lua").
  -- Walking headers with nil used to crash match_pattern on the first
  -- unmatched language, which took the whole window down on first paint.
  return find(filename or "", "files")
      or (header and find(header, "headers"))
      or plain_text_syntax
end


return syntax
