local config = require "core.config"

local tokenizer = {}


local function push_token(t, type, text)
  local prev_type = t[#t-1]
  local prev_text = t[#t]
  if prev_type and (prev_type == type or prev_text:find("^%s*$")) then
    t[#t-1] = type
    t[#t] = prev_text .. text
  else
    table.insert(t, type)
    table.insert(t, text)
  end
end


local function is_escaped(text, idx, esc)
  local byte = esc:byte()
  local count = 0
  for i = idx - 1, 1, -1 do
    if text:byte(i) ~= byte then break end
    count = count + 1
  end
  return count % 2 == 1
end


local function find_non_escaped(text, pattern, offset, esc)
  while true do
    local s, e = text:find(pattern, offset)
    if not s then break end
    if esc and is_escaped(text, s, esc) then
      offset = e + 1
    else
      return s, e
    end
  end
end


-- Returns tokens, state, resume.
--
-- `resume`, when returned, means this line was abandoned part way through
-- because it had already used more than its share of the frame, and carries
-- everything needed to pick it up again: the tokens produced so far, the byte to
-- restart at, and the pair state at that byte. Pass it back as the fourth
-- argument to continue.
--
-- Without this, one line is one unit of work, and a single pathological line --
-- minified JavaScript, a base64 blob, a 200KB JSON array on one line -- costs
-- however long it costs, every time it is retokenized, in the middle of a frame.
-- The editor stops responding for exactly as long as that takes and there is
-- nothing the scheduler above can do about it.
function tokenizer.tokenize(syntax, text, state, resume)
  local res = {}
  local i = 1

  if #syntax.patterns == 0 then
    return { "normal", text }
  end

  if resume then
    res = resume.res
    -- Drop the placeholder that stood in for the untokenized tail.
    for k = #res, resume.n + 1, -1 do res[k] = nil end
    i = resume.i
    state = resume.state
  end

  local start_time = system.get_time()
  local checked_at = i

  while i <= #text do
    -- Checking the clock costs more than tokenizing a character, so only look
    -- every 64 bytes. Half a frame is the budget: the caller still has to draw.
    --
    -- lite-xl checks every 200. That is too coarse here because a pattern like
    -- language_lua's "%-%-.-\n" backtracks over everything left on the line
    -- before failing, so on a very long line the cost of 200 bytes of progress
    -- is itself several frames.
    if i - checked_at > 64 then
      checked_at = i
      if system.get_time() - start_time > 0.5 / config.fps then
        local n = #res
        -- Deliberately not push_token: that merges into the previous token, and
        -- the resume path has to be able to drop this one cleanly. The tail is
        -- typed "normal" so it draws as plain text until the rest arrives,
        -- rather than needing a style nothing defines.
        res[n + 1], res[n + 2] = "normal", text:sub(i)
        return res, nil, { res = res, i = i, state = state, n = n }
      end
    end
    -- continue trying to match the end pattern of a pair if we have a state set
    if state then
      local p = syntax.patterns[state]
      local s, e = find_non_escaped(text, p.pattern[2], i, p.pattern[3])

      if s then
        push_token(res, p.type, text:sub(i, e))
        state = nil
        i = e + 1
      else
        push_token(res, p.type, text:sub(i))
        break
      end
    end

    -- find matching pattern
    local matched = false
    for n, p in ipairs(syntax.patterns) do
      local pattern = (type(p.pattern) == "table") and p.pattern[1] or p.pattern
      local s, e = text:find("^" .. pattern, i)

      if s then
        -- matched pattern; make and add token
        local t = text:sub(s, e)
        push_token(res, syntax.symbols[t] or p.type, t)

        -- update state if this was a start|end pattern pair
        if type(p.pattern) == "table" then
          state = n
        end

        -- move cursor past this token
        i = e + 1
        matched = true
        break
      end
    end

    -- consume character if we didn't match
    if not matched then
      push_token(res, "normal", text:sub(i, i))
      i = i + 1
    end
  end

  return res, state
end


local function iter(t, i)
  i = i + 2
  local type, text = t[i], t[i+1]
  if type then
    return i, type, text
  end
end

function tokenizer.each_token(t)
  return iter, t, -1
end


return tokenizer
