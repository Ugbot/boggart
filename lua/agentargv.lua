-- Literal argv from a human command line: quotes/escapes, no shell expansion.
local M = {}
function M.parse(text)
  assert(type(text) == "string" and #text <= 16384 and not text:find("\0", 1, true), "invalid agent command")
  local args, word, quote, started = {}, {}, nil, false
  local function finish()
    if not started then return end
    assert(#args < 128, "too many arguments")
    args[#args + 1] = table.concat(word); word, started = {}, false
  end
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if quote == "'" then
      if c == quote then quote = nil else word[#word + 1] = c end
    elseif c == "\\" then
      assert(i < #text, "trailing escape")
      local nextc = text:sub(i + 1, i + 1)
      if quote == '"' and nextc ~= '"' and nextc ~= "\\" then word[#word + 1] = c end
      word[#word + 1] = nextc; i = i + 1; started = true
    elseif quote then
      if c == quote then quote = nil else word[#word + 1] = c end
    elseif c == "'" or c == '"' then quote, started = c, true
    elseif c:match("%s") then finish()
    else word[#word + 1] = c; started = true end
    i = i + 1
  end
  assert(not quote, "unclosed quote"); finish()
  assert(#args > 0 and args[1] ~= "", "an executable is required")
  return args
end
return M
