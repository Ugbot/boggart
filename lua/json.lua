-- json.lua -- small, dependency-free JSON encode/decode for boggart.
-- Arrays vs objects: a table is encoded as an array when its keys are exactly
-- 1..#t; otherwise as an object. Empty tables encode as {} (object). To force
-- an empty array, use json.array (a sentinel understood by encode).
local json = {}

json.array = setmetatable({}, { __tostring = function() return "json.array" end })
json.null = setmetatable({}, { __tostring = function() return "json.null" end })

-- ---- encode --------------------------------------------------------------
local encode

local escape_map = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_char(c)
  return escape_map[c] or string.format('\\u%04x', string.byte(c))
end

local function encode_string(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return n > 0
end

encode = function(v, out)
  local tv = type(v)
  if v == json.null then
    out[#out + 1] = "null"
  elseif tv == "nil" then
    out[#out + 1] = "null"
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("json: cannot encode non-finite number")
    end
    if math.type(v) == "integer" then
      out[#out + 1] = string.format("%d", v)
    else
      out[#out + 1] = string.format("%.14g", v)
    end
  elseif tv == "string" then
    out[#out + 1] = encode_string(v)
  elseif tv == "table" then
    if v == json.array or (getmetatable(v) == nil and next(v) == nil and rawget(v, "__isarray")) then
      out[#out + 1] = "[]"
    elseif is_array(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encode(v[i], out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      -- deterministic key order helps prompt caching
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        if not first then out[#out + 1] = "," end
        first = false
        out[#out + 1] = encode_string(tostring(k))
        out[#out + 1] = ":"
        encode(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("json: cannot encode " .. tv)
  end
end

function json.encode(v)
  local out = {}
  encode(v, out)
  return table.concat(out)
end

-- ---- decode --------------------------------------------------------------
local decode_value

local function skip_ws(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return (j or i - 1) + 1
end

local function decode_error(s, i, msg)
  error(string.format("json decode error at %d: %s", i, msg))
end

local esc_dec = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/', ['b'] = '\b',
  ['f'] = '\f', ['n'] = '\n', ['r'] = '\r', ['t'] = '\t',
}

local function codepoint_to_utf8(n)
  if n < 0x80 then
    return string.char(n)
  elseif n < 0x800 then
    return string.char(0xC0 + n // 0x40, 0x80 + n % 0x40)
  elseif n < 0x10000 then
    return string.char(0xE0 + n // 0x1000, 0x80 + (n // 0x40) % 0x40, 0x80 + n % 0x40)
  else
    return string.char(0xF0 + n // 0x40000, 0x80 + (n // 0x1000) % 0x40,
                       0x80 + (n // 0x40) % 0x40, 0x80 + n % 0x40)
  end
end

local function decode_string(s, i)
  -- s:sub(i) == '"'
  local buf = {}
  i = i + 1
  while true do
    local c = s:sub(i, i)
    if c == "" then decode_error(s, i, "unterminated string") end
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local hex = s:sub(i + 2, i + 5)
        local n = tonumber(hex, 16)
        if not n then decode_error(s, i, "bad \\u escape") end
        -- surrogate pair
        if n >= 0xD800 and n <= 0xDBFF then
          local hex2 = s:sub(i + 8, i + 11)
          local n2 = tonumber(hex2, 16)
          if s:sub(i + 6, i + 7) == "\\u" and n2 and n2 >= 0xDC00 and n2 <= 0xDFFF then
            n = 0x10000 + (n - 0xD800) * 0x400 + (n2 - 0xDC00)
            i = i + 6
          else
            n = 0xFFFD -- lone high surrogate -> replacement char (valid UTF-8)
          end
        elseif n >= 0xDC00 and n <= 0xDFFF then
          n = 0xFFFD -- lone low surrogate
        end
        buf[#buf + 1] = codepoint_to_utf8(n)
        i = i + 6
      else
        local m = esc_dec[e]
        if not m then decode_error(s, i, "bad escape \\" .. e) end
        buf[#buf + 1] = m
        i = i + 2
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
end

local function decode_number(s, i)
  local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
  if not num or num == "" then decode_error(s, i, "bad number") end
  local n = tonumber(num)
  if not n then decode_error(s, i, "bad number " .. num) end
  return n, i + #num
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      i = skip_ws(s, i)
      if s:sub(i, i) ~= '"' then decode_error(s, i, "expected key string") end
      local key
      key, i = decode_string(s, i)
      i = skip_ws(s, i)
      if s:sub(i, i) ~= ":" then decode_error(s, i, "expected ':'") end
      local val
      val, i = decode_value(s, i + 1)
      obj[key] = val
      i = skip_ws(s, i)
      local d = s:sub(i, i)
      if d == "," then i = i + 1
      elseif d == "}" then return obj, i + 1
      else decode_error(s, i, "expected ',' or '}'") end
    end
  elseif c == "[" then
    local arr = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    local n = 0
    while true do
      local val
      val, i = decode_value(s, i)
      n = n + 1
      arr[n] = val
      i = skip_ws(s, i)
      local d = s:sub(i, i)
      if d == "," then i = i + 1
      elseif d == "]" then return arr, i + 1
      else decode_error(s, i, "expected ',' or ']'") end
    end
  elseif c == '"' then
    return decode_string(s, i)
  elseif c == "t" then
    if s:sub(i, i + 3) == "true" then return true, i + 4 end
    decode_error(s, i, "invalid literal")
  elseif c == "f" then
    if s:sub(i, i + 4) == "false" then return false, i + 5 end
    decode_error(s, i, "invalid literal")
  elseif c == "n" then
    if s:sub(i, i + 3) == "null" then return json.null, i + 4 end
    decode_error(s, i, "invalid literal")
  else
    return decode_number(s, i)
  end
end

function json.decode(s)
  local v, i = decode_value(s, 1)
  i = skip_ws(s, i)
  if i <= #s then decode_error(s, i, "trailing garbage") end
  return v
end

return json
