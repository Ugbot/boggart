-- termrender.lua -- turn a transcript entry into ANSI-coloured terminal text.
--
-- This is the terminal twin of studio/data/core/agentview.lua: the studio draws
-- the same transcript into a GPU/software canvas, this renders it into the
-- scrolling REPL. It is deliberately PURE -- every function is (input -> string)
-- with no side effects, no terminal control (no cursor moves, no clearing), and
-- no global state. The one environment read is NO_COLOR, which the spec (and the
-- de-facto https://no-color.org convention) requires.
--
-- The entry shapes are the real ones the turn loop and agentview produce, not
-- invented: an entry is { role = <kind>, text = <string>, ... } where role is
-- one of user / assistant / tool / diff / error / system (see agentview.ROLE).
-- A diff entry additionally carries { diff = <difflib result>, path = <string> }
-- exactly as agentview pushes it:  push("diff", "", { diff = rec.diff, path = ... })
-- and difflib.compute returns { added, removed, hunk = {{" "/"+"/"-", text},...},
-- start_line, unchanged }.
--
-- Colours echo studio/data/core/style.lua where it makes sense, emitted as
-- 24-bit truecolour SGR so the terminal matches the studio's palette by
-- construction rather than by a hand-maintained 16-colour approximation.
local M = {}

-- ---------------------------------------------------------------------------
-- Palette -- the hexes are lifted straight from style.lua so the two surfaces
-- agree. good/error are the diff pair, keyword is the tool-call colour, and the
-- syntax table mirrors style.syntax for fenced code.
-- ---------------------------------------------------------------------------
local PAL = {
  text        = "97979c",
  accent      = "e1e1e6",
  dim         = "525257",
  divider     = "202024",
  good        = "7fb77e",   -- added lines
  err         = "f77483",   -- removed lines, failures
  keyword     = "e58ac9",   -- tool calls
  warn        = "ffa94d",
  inline_code = "f79b83",   -- `code` in prose
  link        = "93ddfa",
}

-- Subtle band behind fenced code, = style.background2.
local CODEBG = "252529"

-- style.syntax, by token type.
local SYN = {
  normal   = "e1e1e6", symbol  = "e1e1e6", comment  = "676b6f",
  keyword  = "e58ac9", keyword2 = "f77483", number  = "ffa94d",
  literal  = "ffa94d", string  = "f7c95c", operator = "93ddfa",
  ["function"] = "93ddfa",
}

-- SGR attribute codes, kept named so the paint sites read as intent.
local BOLD, DIM, ITALIC, UNDERLINE = "1", "2", "3", "4"

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16),
         tonumber(hex:sub(3, 4), 16),
         tonumber(hex:sub(5, 6), 16)
end
local function fg(hex) local r, g, b = rgb(hex); return "38;2;" .. r .. ";" .. g .. ";" .. b end
local function bg(hex) local r, g, b = rgb(hex); return "48;2;" .. r .. ";" .. g .. ";" .. b end

-- ---------------------------------------------------------------------------
-- The painter -- one per call, bound to opts. When colour is off (opts.color ==
-- false or NO_COLOR in the environment) every method degrades to plain text, so
-- a caller never has to branch on it and the output provably contains no "\27["
-- at all. This is a closure over locals, not module state, so it stays pure.
-- ---------------------------------------------------------------------------
local function painter(opts)
  local color = not (opts and opts.color == false)
  if os.getenv("NO_COLOR") ~= nil then color = false end
  local P = { enabled = color }

  -- Raw SGR introducer (no trailing reset), for the code band where the
  -- background must persist across several fg changes.
  function P.seq(...)
    if not color then return "" end
    local n, codes = select("#", ...), {}
    for k = 1, n do local c = select(k, ...); if c then codes[#codes + 1] = c end end
    if #codes == 0 then return "" end
    return "\27[" .. table.concat(codes, ";") .. "m"
  end
  P.reset = color and "\27[0m" or ""

  -- A self-contained styled span: codes, text, reset. nil codes are ignored so
  -- callers can pass `cond and CODE or nil` freely.
  function P.span(text, ...)
    if not color then return text end
    local s = P.seq(...)
    if s == "" then return text end
    return s .. text .. "\27[0m"
  end
  return P
end

-- ---------------------------------------------------------------------------
-- Width-aware helpers. Wrapping counts display columns, not bytes, so a UTF-8
-- string measures by codepoints via the stdlib utf8 library (no dependency).
-- This is the same "cells, not bytes" lesson agentview documents at length; we
-- approximate a cell as one codepoint, which is exact for the Latin/code text a
-- REPL mostly shows and only loose for CJK/emoji width.
-- ---------------------------------------------------------------------------
local function vis_len(s)
  if s == "" then return 0 end
  local n = utf8 and utf8.len(s)
  return n or #s
end

-- First n codepoints of s, and the remainder.
local function take(s, n)
  if n <= 0 then return "", s end
  if not utf8 then return s:sub(1, n), s:sub(n + 1) end
  local off = utf8.offset(s, n + 1)
  if not off then return s, "" end
  return s:sub(1, off - 1), s:sub(off)
end

-- ---------------------------------------------------------------------------
-- Inline markdown -- a scanner, not a parser, exactly as agentview's is: it
-- finds the earliest of a few spans, emits it, and continues. Unmatched markup
-- renders as its own source, which keeps the text legible rather than swallowed.
-- Each token is { text, hex, bold?, italic?, underline? }.
-- ---------------------------------------------------------------------------
local SPANS = {
  { pat = "`([^`]+)`",               kind = "code"   },
  { pat = "%*%*([^*]+)%*%*",         kind = "bold"   },
  { pat = "__([^_]+)__",             kind = "bold"   },
  { pat = "%[([^%]]+)%]%(([^)]+)%)",  kind = "link"   },
  { pat = "%*([^*]+)%*",             kind = "italic" },
  { pat = "_([^_]+)_",               kind = "italic" },
}

local function inline(text, base)
  local toks, i = {}, 1
  while i <= #text do
    local best
    for _, sp in ipairs(SPANS) do
      local s1, e1, cap = text:find(sp.pat, i)
      if s1 and (not best or s1 < best.s) then
        best = { s = s1, e = e1, cap = cap, kind = sp.kind }
      end
    end
    if not best then toks[#toks + 1] = { text = text:sub(i), hex = base }; break end
    if best.s > i then toks[#toks + 1] = { text = text:sub(i, best.s - 1), hex = base } end
    if best.kind == "code" then
      toks[#toks + 1] = { text = best.cap, hex = PAL.inline_code }
    elseif best.kind == "bold" then
      toks[#toks + 1] = { text = best.cap, hex = base, bold = true }
    elseif best.kind == "italic" then
      toks[#toks + 1] = { text = best.cap, hex = base, italic = true }
    else -- link
      toks[#toks + 1] = { text = best.cap, hex = PAL.link, underline = true }
    end
    i = best.e + 1
  end
  if #toks == 0 then toks[1] = { text = "", hex = base } end
  return toks
end

local function paint_token(sty, text, P)
  return P.span(text,
    sty.hex and fg(sty.hex) or nil,
    sty.bold and BOLD or nil,
    sty.italic and ITALIC or nil,
    sty.underline and UNDERLINE or nil)
end

-- Split styled tokens into whitespace / word pieces, each keeping its style, so
-- the packer can break between words while preserving colour.
local function split_pieces(tokens)
  local out = {}
  for _, t in ipairs(tokens) do
    local s, i = t.text, 1
    while i <= #s do
      local ws = s:match("^%s+", i)
      if ws then out[#out + 1] = { kind = "ws", text = ws, sty = t }; i = i + #ws
      else
        local wd = s:match("^%S+", i)
        out[#out + 1] = { kind = "wd", text = wd, sty = t }; i = i + #wd
      end
    end
  end
  return out
end

-- Greedy word wrap to `width` columns. Leading whitespace is dropped at the
-- start of a wrapped row, and a single word wider than the column is hard-split
-- (so a long URL wraps rather than blowing past the margin). width nil == no
-- wrap: one row.
local function pack(pieces, width)
  if not width or width < 1 then return { pieces } end
  local rows, cur, used = {}, {}, 0
  local function flush() rows[#rows + 1] = cur; cur, used = {}, 0 end
  for _, p in ipairs(pieces) do
    local pl = vis_len(p.text)
    if p.kind == "ws" then
      if used == 0 then                       -- swallow a row-leading space
      elseif used + pl > width then flush()
      else cur[#cur + 1] = p; used = used + pl end
    else
      if used > 0 and used + pl > width then flush() end
      if pl > width then
        local rest, rlen = p.text, pl
        while rlen > width do
          local room = width - used
          if room <= 0 then flush(); room = width end
          local head, tail = take(rest, room)
          cur[#cur + 1] = { kind = "wd", text = head, sty = p.sty }
          flush()
          rest, rlen = tail, vis_len(tail)
        end
        cur[#cur + 1] = { kind = "wd", text = rest, sty = p.sty }; used = rlen
      else
        cur[#cur + 1] = p; used = used + pl
      end
    end
  end
  flush()
  return rows
end

-- Wrap a token row to width and render it, giving the first line `prefix` (a
-- { text, hex, bold } record) and the continuations a blank indent of the same
-- width so bullets and quotes hang correctly. Returns a list of strings.
local function wrap_render(tokens, width, P, prefix)
  local plen = prefix and vis_len(prefix.text) or 0
  local inner = width and math.max(1, width - plen) or nil
  local rows = pack(split_pieces(tokens), inner)
  local lines = {}
  for i, row in ipairs(rows) do
    local buf = {}
    if prefix then
      if i == 1 then
        buf[#buf + 1] = P.span(prefix.text,
          prefix.hex and fg(prefix.hex) or nil, prefix.bold and BOLD or nil)
      else
        buf[#buf + 1] = string.rep(" ", plen)
      end
    end
    -- Coalesce adjacent pieces that share a style into one painted span, so a
    -- run of same-styled words is a single "\27[..m...\27[0m" rather than one
    -- per word -- fewer escapes, and the visible text stays contiguous.
    local j = 1
    while j <= #row do
      local sty, run = row[j].sty, {}
      while j <= #row and row[j].sty == sty do run[#run + 1] = row[j].text; j = j + 1 end
      buf[#buf + 1] = paint_token(sty, table.concat(run), P)
    end
    lines[#lines + 1] = table.concat(buf)
  end
  if #lines == 0 then
    lines[1] = prefix and P.span(prefix.text, prefix.hex and fg(prefix.hex) or nil) or ""
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- A tiny, language-agnostic code lexer for fenced blocks. No dependency, no
-- lite tokenizer: it recognises strings, line and block comments, numbers and a
-- shared keyword set, which is enough to give lua / c / js / py / sh / go / rust
-- readable colour. Block-comment state is threaded through the caller's loop so
-- a /* */ spanning lines stays a comment; everything else is per-line, whose
-- worst failure is a mis-colour, never lost text.
-- ---------------------------------------------------------------------------
local LINE_COMMENT = {
  lua = "--", py = "#", python = "#", sh = "#", bash = "#", zsh = "#", shell = "#",
  rb = "#", ruby = "#", yaml = "#", yml = "#", toml = "#", ini = "#", conf = "#",
  js = "//", javascript = "//", ts = "//", typescript = "//", jsx = "//", tsx = "//",
  c = "//", h = "//", cpp = "//", cc = "//", ["c++"] = "//", hpp = "//",
  go = "//", rust = "//", rs = "//", java = "//", kt = "//", swift = "//",
  cs = "//", php = "//", scala = "//", json = nil,
}
local BLOCK_LANG = {
  js = true, javascript = true, ts = true, typescript = true, jsx = true, tsx = true,
  c = true, h = true, cpp = true, cc = true, ["c++"] = true, hpp = true,
  go = true, rust = true, rs = true, java = true, kt = true, swift = true,
  cs = true, php = true, css = true, scala = true,
}
local KW = {}
for w in ([[
  if else elseif then end for while do return function local nil true false and or
  not in break repeat until goto def class import from as try except finally with
  lambda pass yield await async const let var new typeof void struct enum switch
  case default continue public private protected static final int char float double
  bool boolean long short unsigned signed string void package func type interface
  map range go defer fn mut use impl match self this super print echo where when
  namespace template using virtual override extern inline sizeof throw catch delete
]]):gmatch("%S+") do KW[w] = true end

local function hl(line, lang, st)
  lang = lang or ""
  local toks, i, n = {}, 1, #line
  local linec = LINE_COMMENT[lang]
  local blocks = BLOCK_LANG[lang]
  local function push(t, hex) toks[#toks + 1] = { t, hex } end

  if st.block then                              -- inside an open /* ... */
    local e = line:find("*/", i, true)
    if e then push(line:sub(i, e + 1), SYN.comment); i = e + 2; st.block = false
    else push(line:sub(i), SYN.comment); return toks, st end
  end

  while i <= n do
    local c = line:sub(i, i)
    if blocks and line:sub(i, i + 1) == "/*" then
      local e = line:find("*/", i + 2, true)
      if e then push(line:sub(i, e + 1), SYN.comment); i = e + 2
      else push(line:sub(i), SYN.comment); st.block = true; return toks, st end
    elseif linec and line:sub(i, i + #linec - 1) == linec then
      push(line:sub(i), SYN.comment); i = n + 1
    elseif c == '"' or c == "'" or c == "`" then
      local j = i + 1
      while j <= n do
        local d = line:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c then j = j + 1; break
        else j = j + 1 end
      end
      push(line:sub(i, j - 1), SYN.string); i = j
    elseif c:match("%d") then
      local num = line:match("^0[xXbB][%x_]+", i) or line:match("^%d[%d_]*%.?%d*", i) or c
      push(num, SYN.number); i = i + #num
    elseif c:match("[%a_]") then
      local word = line:match("^[%w_]+", i)
      push(word, KW[word] and SYN.keyword or SYN.normal); i = i + #word
    elseif c:match("[%+%-%*/%%=<>~&|%^!%?:%.@]") then
      push(c, SYN.operator); i = i + 1
    else
      push(c, SYN.normal); i = i + 1
    end
  end
  return toks, st
end

-- One code line: a dim gutter, then a subtle background band carrying the
-- highlighted tokens. The band's bg is opened once and never reset until the
-- line's end, so each token only sets its foreground -- the background rides
-- underneath. Optionally padded to `width` so the band is a full-width stripe.
local function render_code_line(line, lang, st, P, width)
  local toks
  toks, st = hl(line, lang, st)
  if not P.enabled then return "\226\148\130 " .. line, st end   -- "│ " gutter, plain
  local buf = { P.span("\226\148\130 ", fg(PAL.dim)) }           -- gutter, outside the band
  buf[#buf + 1] = P.seq(bg(CODEBG))                              -- open the band
  for _, t in ipairs(toks) do buf[#buf + 1] = P.seq(fg(t[2])) .. t[1] end
  if width then
    local pad = width - 2 - vis_len(line)
    if pad > 0 then buf[#buf + 1] = string.rep(" ", pad) end
  end
  buf[#buf + 1] = P.reset
  return table.concat(buf), st
end

-- ---------------------------------------------------------------------------
-- Block markdown for one non-code line: headings, blockquotes, bullet and
-- numbered lists, horizontal rules, then the inline scanner for the rest.
-- Returns a list of rendered strings (a line may wrap to several).
-- ---------------------------------------------------------------------------
local function render_md_line(line, width, P)
  if line:match("^%s*[-*_][-*_ ]*$") and #line:gsub("%s", "") >= 3 then
    return { P.span(string.rep("\226\148\128", math.min(width or 48, 48)), fg(PAL.divider)) }
  end

  local hashes, htext = line:match("^(#+)%s+(.*)$")
  local quote = line:match("^%s*>%s?(.*)$")
  local ind, bullet = line:match("^(%s*)[-*+]%s+(.*)$")
  local numlead, numbody = line:match("^(%s*%d+%.%s+)(.*)$")

  if hashes then
    local toks = inline(htext, PAL.accent)
    for _, t in ipairs(toks) do t.bold = true end
    local rows = wrap_render(toks, width, P, nil)
    if #hashes <= 2 then     -- underline h1/h2, as agentview draws a rule
      rows[#rows + 1] = P.span(string.rep("\226\148\128",
        math.min(width or vis_len(htext), math.max(4, vis_len(htext)))), fg(PAL.divider))
    end
    return rows
  elseif quote then
    return wrap_render(inline(quote, PAL.dim), width, P,
      { text = "\226\148\130 ", hex = PAL.divider })     -- "│ "
  elseif bullet then
    return wrap_render(inline(bullet, PAL.text), width, P,
      { text = ind .. "\226\128\162 ", hex = PAL.accent })  -- indent + "• "
  elseif numlead then
    return wrap_render(inline(numbody, PAL.text), width, P,
      { text = numlead, hex = PAL.accent })
  else
    return wrap_render(inline(line, PAL.text), width, P, nil)
  end
end

-- ---------------------------------------------------------------------------
-- A plain (non-markdown) line block with a coloured prefix -- used for the user
-- echo, tool headers, errors and system notes. The prefix leads the first line;
-- wrapped and subsequent source lines get a blank indent so the text stays in a
-- clean column.
-- ---------------------------------------------------------------------------
local function simple(text, prefix_text, hex, opts, bold)
  local P = painter(opts)
  local width = opts and opts.width
  local blank = string.rep(" ", vis_len(prefix_text))
  local lines, first = {}, true
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    local pfx = {
      text = first and prefix_text or blank,
      hex  = first and hex or nil,
      bold = first and bold or nil,
    }
    for _, l in ipairs(wrap_render({ { text = line, hex = hex, bold = bold } }, width, P, pfx)) do
      lines[#lines + 1] = l
    end
    first = false
  end
  if #lines == 0 then lines[1] = P.span(prefix_text, fg(hex)) end
  return table.concat(lines, "\n")
end

local function textof(x)
  if type(x) == "table" then return x.text or "" end
  return tostring(x or "")
end

-- ---------------------------------------------------------------------------
-- Public per-kind renderers. Each accepts either an entry table or a bare
-- string, plus opts { width, color }.
-- ---------------------------------------------------------------------------

function M.assistant(entry, opts)
  local text = textof(entry)
  local P = painter(opts)
  local width = opts and opts.width
  local out = {}
  local in_code, fence_len, lang = false, 0, nil
  local st = { block = false }

  for line in (text .. "\n"):gmatch("(.-)\n") do
    local fence, flang = line:match("^%s*(```+)%s*([%w_+#%-]*)")
    -- A fence only closes one at least as long as the one that opened it, so a
    -- ````-fence can contain a ``` block (agentview's rule). The fence markers
    -- themselves are markup, not content, so they are never emitted.
    if fence and (not in_code or #fence >= fence_len) then
      if in_code then in_code, fence_len, lang, st = false, 0, nil, { block = false }
      else in_code, fence_len = true, #fence
        lang = (flang ~= "" and flang:lower()) or nil
        st = { block = false }
      end
    elseif in_code then
      local rendered
      rendered, st = render_code_line(line, lang, st, P, width)
      out[#out + 1] = rendered
    else
      for _, l in ipairs(render_md_line(line, width, P)) do out[#out + 1] = l end
    end
  end
  return table.concat(out, "\n")
end

function M.user(entry, opts)  return simple(textof(entry), "\226\128\186 ", PAL.accent, opts) end   -- "› "
function M.tool(entry, opts)  return simple(textof(entry), "\194\187 ", PAL.keyword, opts) end       -- "» "
function M.error(entry, opts) return simple(textof(entry), "\226\156\151 ", PAL.err, opts, true) end -- "✗ "
function M.system(entry, opts) return simple(textof(entry), "\194\183 ", PAL.dim, opts) end          -- "· "

-- A hunk row from difflib.compute: green add, red remove, dim context.
local function render_diff_row(kind, text, P)
  if kind == "+" then return P.span("+ " .. text, fg(PAL.good))
  elseif kind == "-" then return P.span("- " .. text, fg(PAL.err))
  else return P.span("  " .. text, fg(PAL.dim)) end
end

-- One line of a raw unified diff, classified by its leading marker.
local function render_unified_line(line, P)
  local h = line:sub(1, 1)
  if line:match("^%+%+%+") or line:match("^%-%-%-") or line:match("^diff ") then
    return P.span(line, fg(PAL.accent), BOLD)
  elseif line:match("^@@") then
    return P.span(line, fg(PAL.keyword))
  elseif h == "+" then return P.span(line, fg(PAL.good))
  elseif h == "-" then return P.span(line, fg(PAL.err))
  else return P.span(line, fg(PAL.dim)) end
end

-- Diffs. Accepts, in order of preference:
--   * an entry { diff = <difflib result>, path = ... } (what agentview pushes)
--   * a difflib result directly (has .hunk)
--   * a raw unified-diff string
function M.diff(x, opts)
  local P = painter(opts)
  local d, path, raw
  if type(x) == "string" then
    raw = x
  elseif type(x) == "table" then
    if x.hunk then d, path = x, x.path
    elseif type(x.diff) == "table" then d, path = x.diff, x.path
    elseif type(x.diff) == "string" then raw = x.diff
    else raw = x.text end
  end

  local out = {}
  if d and d.hunk then
    local head
    if d.unchanged then
      head = (path or "(diff)") .. "  (no change)"
    else
      head = string.format("%s  +%d -%d%s", path or "(diff)",
        d.added or 0, d.removed or 0,
        d.start_line and ("  @ line " .. d.start_line) or "")
    end
    out[#out + 1] = P.span("\226\150\184 " .. head, fg(PAL.accent), BOLD)   -- "▸ " file header
    for _, row in ipairs(d.hunk) do
      out[#out + 1] = render_diff_row(row[1], row[2], P)
    end
  elseif raw and raw ~= "" then
    for line in (raw .. "\n"):gmatch("(.-)\n") do
      out[#out + 1] = render_unified_line(line, P)
    end
  end
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Dispatcher + convenience.
-- ---------------------------------------------------------------------------
M.kinds = {
  user = M.user, assistant = M.assistant, tool = M.tool,
  diff = M.diff, error = M.error, system = M.system,
}

-- entry(entry, opts) -> string. Unknown roles fall back to assistant, which is
-- the most forgiving renderer (plain prose still reads correctly through it).
function M.entry(entry, opts)
  entry = entry or {}
  local fn = M.kinds[entry.role or "assistant"] or M.assistant
  return fn(entry, opts)
end

-- Render a whole transcript, blank-line separated. Handy for a REPL redraw.
function M.transcript(entries, opts)
  local parts = {}
  for _, e in ipairs(entries or {}) do parts[#parts + 1] = M.entry(e, opts) end
  return table.concat(parts, "\n\n")
end

return M
