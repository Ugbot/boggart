-- util.lua -- small helpers shared across the harness.
local json = require("json")
local M = {}

-- Is t a dense 1..n array?
function M.is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return n > 0
end

-- Serialize a plain data value (from json.decode or hand-built) to a Lua
-- literal string. Used to persist model-defined tools as readable .lua files.
local function ser(v, ind)
  local t = type(v)
  if v == json.null then return "nil" end
  if t == "string" then return string.format("%q", v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "nil" then return "nil"
  elseif t == "number" then
    return math.type(v) == "integer" and string.format("%d", v) or string.format("%.14g", v)
  elseif t == "table" then
    local nind = ind .. "  "
    local parts = {}
    if M.is_array(v) then
      for i = 1, #v do parts[#parts + 1] = nind .. ser(v[i], nind) end
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        local kk
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
          kk = k
        else
          kk = "[" .. ser(k, nind) .. "]"
        end
        parts[#parts + 1] = nind .. kk .. " = " .. ser(v[k], nind)
      end
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
  end
  return "nil"
end

function M.serialize(v)
  return ser(v, "")
end

-- UTF-8 sanitizer -------------------------------------------------------------
--
-- Scrub a byte string to well-formed UTF-8, replacing every ill-formed sequence
-- with U+FFFD (EF BF BD). Valid ASCII and valid 2/3/4-byte sequences -- emoji,
-- CJK, accents -- pass through byte-for-byte. O(n), single pass, and it returns
-- the input string *unchanged* (no allocation) when it is already valid, so the
-- overwhelmingly common case is just a scan.
--
-- Why this exists: the JSON encoder (lua/json.lua) escapes only control bytes,
-- backslash and quote and passes every byte >= 0x80 through raw. A tool result
-- that is not valid UTF-8 -- `cat` on a binary file, a subprocess writing Latin-1
-- or a truncated multibyte read -- therefore lands verbatim in the request body,
-- and the Messages API rejects the ENTIRE turn with HTTP 400 "invalid unicode
-- code point". One bad byte from one tool must never kill a turn, so invalid
-- bytes are scrubbed the moment content is assembled into the transcript.
--
-- The validity rules are the ones the Unicode standard (Table 3-7) makes
-- well-formed: reject C0/C1 (0xC0-0xC1, overlong 2-byte), the E0/ED/F0/F4 lead
-- bytes get tightened continuation ranges so overlong 3/4-byte forms, the
-- surrogate range U+D800-U+DFFF, and code points > U+10FFFF are all rejected,
-- and any lead byte >= 0xF5 or stray continuation (0x80-0xBF) is invalid.
local REPL = "\239\191\189" -- U+FFFD, three bytes
function M.to_valid_utf8(s)
  if type(s) ~= "string" then return s end
  local n = #s
  local byte, sub = string.byte, string.sub
  local i, seg_start, out = 1, 1, nil

  while i <= n do
    local c = byte(s, i)
    if c < 0x80 then
      i = i + 1 -- ASCII, always fine
    else
      -- Expected total length, plus the *tightened* range for the second byte
      -- that rejects overlong forms and surrogates. Bytes 3/4 are 0x80..0xBF.
      local len, lo, hi
      if c >= 0xC2 and c <= 0xDF then len, lo, hi = 2, 0x80, 0xBF
      elseif c == 0xE0        then len, lo, hi = 3, 0xA0, 0xBF -- no overlong
      elseif c >= 0xE1 and c <= 0xEC then len, lo, hi = 3, 0x80, 0xBF
      elseif c == 0xED        then len, lo, hi = 3, 0x80, 0x9F -- no surrogates
      elseif c >= 0xEE and c <= 0xEF then len, lo, hi = 3, 0x80, 0xBF
      elseif c == 0xF0        then len, lo, hi = 4, 0x90, 0xBF -- no overlong
      elseif c >= 0xF1 and c <= 0xF3 then len, lo, hi = 4, 0x80, 0xBF
      elseif c == 0xF4        then len, lo, hi = 4, 0x80, 0x8F -- <= U+10FFFF
      -- else: 0x80-0xBF stray continuation, 0xC0/0xC1 overlong, >= 0xF5
      end

      local valid = false
      if len and i + len - 1 <= n then
        local b2 = byte(s, i + 1)
        if b2 >= lo and b2 <= hi then
          valid = true
          for k = 2, len - 1 do
            local bk = byte(s, i + k)
            if bk < 0x80 or bk > 0xBF then valid = false; break end
          end
        end
      end

      if valid then
        i = i + len
      else
        -- One ill-formed byte -> one U+FFFD; resume at the very next byte, so a
        -- bad lead byte does not consume the (possibly valid) bytes after it.
        out = out or {}
        if i > seg_start then out[#out + 1] = sub(s, seg_start, i - 1) end
        out[#out + 1] = REPL
        i = i + 1
        seg_start = i
      end
    end
  end

  if not out then return s end -- fast path: nothing was ill-formed
  if n >= seg_start then out[#out + 1] = sub(s, seg_start, n) end
  return table.concat(out)
end

-- File helpers ----------------------------------------------------------------
function M.read_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local data = f:read("*a")
  f:close()
  return data
end

function M.write_file(path, content)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(content)
  f:close()
  return true
end

-- A writable temp-file path.
--
-- os.tmpname() is not usable on Windows: the CRT returns a path in the root of
-- the current drive ("\s2h4.") which is not writable without elevation, and it
-- does not consult %TEMP%. It is also only a *name* on POSIX, so there is a
-- race either way. sys.tmpdir() (uv_os_tmpdir) knows the right directory on
-- every platform, so this does not go environment-variable hunting; the pid
-- plus a counter keeps concurrent agents in one process apart.
local tmp_seq = 0
function M.tmpname(suffix)
  local dir = sys.tmpdir()
  if not dir or dir == "" then dir = bog.userdir end
  dir = dir:gsub("[/\\]+$", "")
  sys.mkdir_p(dir)
  tmp_seq = tmp_seq + 1
  return string.format("%s/boggart-%d-%d%s", dir, sys.pid(), tmp_seq, suffix or "")
end

function M.slug(title)
  local s = title:lower():gsub("[^%w%-_]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if s == "" then s = "note" end
  return s
end

-- Result-shaping (ds4 pattern): keep small output inline; for large output,
-- write the whole thing to a temp file and return a head plus the path so the
-- model can page through it with the read tool instead of blowing the context.
function M.shape_result(text, opts)
  opts = opts or {}
  local max_bytes = opts.max_bytes or 6000
  local head_lines = opts.head_lines or 80
  if #text <= max_bytes then return text end

  local tmp = M.tmpname()
  M.write_file(tmp, text)

  -- collect the first head_lines lines (or first max_bytes, whichever is less)
  local lines, count, bytes = {}, 0, 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    count = count + 1
    bytes = bytes + #line + 1
    lines[#lines + 1] = line
    if count >= head_lines or bytes >= max_bytes then break end
  end
  local total_lines = select(2, text:gsub("\n", "\n")) + 1
  local head = table.concat(lines, "\n")
  return string.format(
    "%s\n\n[output truncated: %d bytes, ~%d lines. Full output saved to %s -- "
      .. "read it with the read tool, e.g. read{path=%q, start_line=%d, max_lines=200}]",
    head, #text, total_lines, tmp, tmp, head_lines + 1)
end

return M
