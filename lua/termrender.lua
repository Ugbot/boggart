-- termrender.lua -- turn a transcript entry into styled runs, then ANSI text.
--
-- This is the terminal twin of studio/data/core/agentview.lua: the studio draws
-- the same transcript into a GPU/software canvas, this renders it into the
-- scrolling REPL. It is deliberately PURE -- every function is (input -> value)
-- with no side effects, no terminal control (no cursor moves, no clearing), and
-- no global state. The one environment read is NO_COLOR, which the spec (and the
-- de-facto https://no-color.org convention) requires.
--
-- The core (Contract B) produces STYLED RUNS, not strings:
--   runs(entry, opts) -> lines,  lines = { line, ... },  line = { run, ... }
--   run  = { text=<string>, fg=<"rrggbb"|nil>, bg=<"rrggbb"|nil>,
--            attr={bold?,dim?,italic?,underline?,reverse?}|nil }
-- Concatenating a line's run texts yields that line's plain text, and every
-- visible char lives in exactly one run. The public .entry/.assistant/.diff/...
-- functions are a thin SERIALISER over those runs: they walk the lines and emit
-- 24-bit truecolour SGR (matching the studio palette by construction), or plain
-- text when colour is off. runs -> string is the only place a "\27[" is minted.
--
-- The entry shapes are the real ones the turn loop and agentview produce, not
-- invented: an entry is { role = <kind>, text = <string>, ... } where role is
-- one of user / assistant / tool / diff / error / system (see agentview.ROLE).
-- A diff entry additionally carries { diff = <difflib result>, path = <string> }
-- exactly as agentview pushes it:  push("diff", "", { diff = rec.diff, path = ... })
-- and difflib.compute returns { added, removed, hunk = {{" "/"+"/"-", text},...},
-- start_line, unchanged }.
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
local BOLD, DIM, ITALIC, UNDERLINE, REVERSE = "1", "2", "3", "4", "7"

local function rgb(hex)
  return tonumber(hex:sub(1, 2), 16),
         tonumber(hex:sub(3, 4), 16),
         tonumber(hex:sub(5, 6), 16)
end
local function fg(hex) local r, g, b = rgb(hex); return "38;2;" .. r .. ";" .. g .. ";" .. b end
local function bg(hex) local r, g, b = rgb(hex); return "48;2;" .. r .. ";" .. g .. ";" .. b end

-- ---------------------------------------------------------------------------
-- The serialiser primitives. RESET closes a styled span; esc wraps a list of
-- SGR codes as one introducer. run_codes flattens a run's fg + attrs into that
-- code list, in the fixed order the old painter emitted (fg, then bold, dim,
-- italic, underline, reverse) so a serialised run is byte-for-byte what the
-- previous span-emitting core produced. bg is deliberately absent here: it is
-- handled by the code band (see serialise_line), never per-run.
-- ---------------------------------------------------------------------------
local RESET = "\27[0m"
local function esc(codes) return "\27[" .. table.concat(codes, ";") .. "m" end

local function run_codes(r)
  local c = {}
  if r.fg then c[#c + 1] = fg(r.fg) end
  local a = r.attr
  if a then
    if a.bold then c[#c + 1] = BOLD end
    if a.dim then c[#c + 1] = DIM end
    if a.italic then c[#c + 1] = ITALIC end
    if a.underline then c[#c + 1] = UNDERLINE end
    if a.reverse then c[#c + 1] = REVERSE end
  end
  return c
end

-- ---------------------------------------------------------------------------
-- The painter -- one per serialise, bound to opts. When colour is off (opts.color
-- == false or NO_COLOR in the environment) the serialiser degrades to plain
-- text, so the output provably contains no "\27[" at all. This is a closure over
-- locals, not module state, so it stays pure.
-- ---------------------------------------------------------------------------
local function painter(opts)
  local color = not (opts and opts.color == false)
  if os.getenv("NO_COLOR") ~= nil then color = false end
  return { enabled = color }
end

-- ---------------------------------------------------------------------------
-- Width-aware helpers. Wrapping and table layout count DISPLAY COLUMNS, not
-- bytes and not codepoints: a CJK ideograph is one codepoint but occupies two
-- cells, and an emoji likewise. Measuring by codepoints (utf8.len) makes table
-- columns drift and wrapped lines overrun the margin for any non-Latin text.
--
-- The authoritative width tables (Unicode East-Asian-Width + emoji, Markus
-- Kuhn's wcwidth rules) live in C as sys.width / sys.wtake (see src/lsys.c and
-- src/utf8width.h) -- the SAME helpers dash.lua and the C renderer measure with,
-- so every surface agrees. We bind them if present and keep a pure codepoint
-- fallback (utf8.len) so the module still loads and renders Latin text correctly
-- in a bare Lua harness where the C `sys` library is absent.
-- ---------------------------------------------------------------------------
local sys = rawget(_G, "sys")
local sys_width = sys and sys.width
local sys_wtake = sys and sys.wtake

local function vis_len(s)
  if s == "" then return 0 end
  if sys_width then return sys_width(s) end
  local n = utf8 and utf8.len(s)
  return n or #s
end

-- Longest prefix of s that fits in n display columns, and the remainder. A
-- double-width character straddling the limit is left out whole, so the prefix
-- may be one column short of n -- callers pad the shortfall.
local function take(s, n)
  if n <= 0 then return "", s end
  if sys_wtake then
    local head = sys_wtake(s, n)
    return head, s:sub(#head + 1)
  end
  if not utf8 then return s:sub(1, n), s:sub(n + 1) end
  local off = utf8.offset(s, n + 1)
  if not off then return s, "" end
  return s:sub(1, off - 1), s:sub(off)
end

-- ---------------------------------------------------------------------------
-- The serialiser -- runs -> ANSI. A line is a list of runs; most runs become a
-- self-contained "\27[..m..\27[0m" span (or bare text when unstyled). The one
-- exception is the fenced-code band: consecutive runs sharing a background open
-- that bg ONCE, ride it while each contributes only its foreground, then close
-- with a single reset and (when a width is given) pad the band to a full-width
-- stripe. Colour off collapses the whole line to concatenated run texts, which
-- is exactly a line's plain text and provably escape-free.
-- ---------------------------------------------------------------------------
local function serialise_line(runs, P, width)
  if not P.enabled then
    local t = {}
    for _, r in ipairs(runs) do t[#t + 1] = r.text end
    return table.concat(t)
  end
  local buf, i, n, cols = {}, 1, #runs, 0
  while i <= n do
    local r = runs[i]
    if r.bg then
      -- A background band: open the bg, then each run sets only its fg on top,
      -- so the band rides underneath a run of fg changes with no intermediate
      -- reset -- fewer escapes, contiguous visible text.
      local band = r.bg
      buf[#buf + 1] = esc({ bg(band) })
      while i <= n and runs[i].bg == band do
        local rr = runs[i]
        local codes = run_codes(rr)
        buf[#buf + 1] = (#codes > 0 and esc(codes) or "") .. rr.text
        cols = cols + vis_len(rr.text)
        i = i + 1
      end
      if width then                             -- pad the stripe to the margin
        local pad = width - cols
        if pad > 0 then buf[#buf + 1] = string.rep(" ", pad); cols = cols + pad end
      end
      buf[#buf + 1] = RESET
    else
      local codes = run_codes(r)
      if #codes == 0 then buf[#buf + 1] = r.text
      else buf[#buf + 1] = esc(codes) .. r.text .. RESET end
      cols = cols + vis_len(r.text)
      i = i + 1
    end
  end
  return table.concat(buf)
end

-- lines -> string. Every public ANSI function funnels through here: build a
-- painter from opts, serialise each line, join with newlines.
local function serialise(lines, opts)
  local P = painter(opts)
  local width = opts and opts.width
  local out = {}
  for _, line in ipairs(lines) do out[#out + 1] = serialise_line(line, P, width) end
  return table.concat(out, "\n")
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

-- One inline token -> one run, carrying its colour and any emphasis attrs.
local function token_run(sty, text)
  local attr
  if sty.bold or sty.italic or sty.underline then
    attr = {}
    if sty.bold then attr.bold = true end
    if sty.italic then attr.italic = true end
    if sty.underline then attr.underline = true end
  end
  return { text = text, fg = sty.hex, attr = attr }
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

-- Wrap a token row to width and build its runs, giving the first line `prefix` (a
-- { text, hex, bold } record) and the continuations a blank indent of the same
-- width so bullets and quotes hang correctly. Returns a list of lines (each a
-- list of runs). Adjacent pieces that share a style coalesce into one run, so a
-- run of same-styled words becomes a single span rather than one per word.
local function wrap_runs(tokens, width, prefix)
  local plen = prefix and vis_len(prefix.text) or 0
  local inner = width and math.max(1, width - plen) or nil
  local rows = pack(split_pieces(tokens), inner)
  local lines = {}
  for i, row in ipairs(rows) do
    local line = {}
    if prefix then
      if i == 1 then
        line[#line + 1] = { text = prefix.text, fg = prefix.hex,
          attr = prefix.bold and { bold = true } or nil }
      else
        line[#line + 1] = { text = string.rep(" ", plen) }   -- blank indent, unstyled
      end
    end
    local j = 1
    while j <= #row do
      local sty, run = row[j].sty, {}
      while j <= #row and row[j].sty == sty do run[#run + 1] = row[j].text; j = j + 1 end
      line[#line + 1] = token_run(sty, table.concat(run))
    end
    lines[#lines + 1] = line
  end
  if #lines == 0 then
    lines[1] = prefix and { { text = prefix.text, fg = prefix.hex } } or { { text = "" } }
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

-- One code line as runs: a dim gutter (its own span), then the highlighted
-- tokens, each a run carrying its fg over the shared code background. The band's
-- bg is what the serialiser opens once and rides; an empty line still needs a
-- band, so it gets a single bg-only run so the stripe is drawn. No padding is
-- baked in here -- the serialiser stripes to width, keeping plain text clean.
-- One source line of code -> one OR MORE rendered rows (a list), each within
-- `width`. A code line is not prose and cannot be re-flowed on spaces, so a line
-- wider than the viewport is hard-wrapped at the column boundary with the same
-- "│ " gutter on every row -- otherwise it overflows the viewport (and, in the
-- cTUI, spills into whatever is beside it). Highlighting is preserved: the line
-- is tokenised once, then the coloured tokens are packed into rows, splitting a
-- token across rows only when it does not fit. With no width (or too narrow to
-- be worth it) it stays a single row, byte-identical to before.
local function code_line_runs(line, lang, st, width)
  local toks
  toks, st = hl(line, lang, st)
  local gutter = { text = "\226\148\130 ", fg = PAL.dim } -- "│ ", outside the band
  local cw = width and (width - 2) or nil                 -- content width after the gutter

  if not cw or cw < 4 then
    local runs = { gutter }
    for _, t in ipairs(toks) do runs[#runs + 1] = { text = t[1], fg = t[2], bg = CODEBG } end
    if #toks == 0 then runs[#runs + 1] = { text = "", bg = CODEBG } end
    return { runs }, st
  end

  local rows, row, used = {}, { gutter }, 0
  local function flush() rows[#rows + 1] = row; row, used = { gutter }, 0 end
  for _, t in ipairs(toks) do
    local text, hex = t[1], t[2]
    while #text > 0 do
      local room = cw - used
      if room <= 0 then flush(); room = cw end
      if vis_len(text) <= room then
        row[#row + 1] = { text = text, fg = hex, bg = CODEBG }
        used = used + vis_len(text); text = ""
      else
        local head, rest = take(text, room)
        row[#row + 1] = { text = head, fg = hex, bg = CODEBG }
        used = cw; text = rest
      end
      if used >= cw then flush() end
    end
  end
  if #row > 1 then flush() end
  if #rows == 0 then rows = { { gutter, { text = "", bg = CODEBG } } } end
  return rows, st
end

-- ---------------------------------------------------------------------------
-- Block markdown for one non-code line: headings, blockquotes, bullet and
-- numbered lists, horizontal rules, then the inline scanner for the rest.
-- Returns a list of lines (a source line may wrap to several), each a run list.
-- ---------------------------------------------------------------------------
local function md_line_runs(line, width)
  if line:match("^%s*[-*_][-*_ ]*$") and #line:gsub("%s", "") >= 3 then
    return { { { text = string.rep("\226\148\128", math.min(width or 48, 48)), fg = PAL.divider } } }
  end

  local hashes, htext = line:match("^(#+)%s+(.*)$")
  local quote = line:match("^%s*>%s?(.*)$")
  local ind, bullet = line:match("^(%s*)[-*+]%s+(.*)$")
  local numlead, numbody = line:match("^(%s*%d+[.)]%s+)(.*)$")
  local letlead, letbody = line:match("^(%s*%l[.)]%s+)(.*)$")

  if hashes then
    local toks = inline(htext, PAL.accent)
    for _, t in ipairs(toks) do t.bold = true end
    local rows = wrap_runs(toks, width, nil)
    if #hashes <= 2 then     -- underline h1/h2, as agentview draws a rule
      rows[#rows + 1] = { { text = string.rep("\226\148\128",
        math.min(width or vis_len(htext), math.max(4, vis_len(htext)))), fg = PAL.divider } }
    end
    return rows
  elseif quote then
    return wrap_runs(inline(quote, PAL.dim), width,
      { text = "\226\148\130 ", hex = PAL.divider })     -- "│ "
  elseif bullet then
    return wrap_runs(inline(bullet, PAL.text), width,
      { text = ind .. "\226\128\162 ", hex = PAL.accent })  -- indent + "• "
  elseif numlead then
    return wrap_runs(inline(numbody, PAL.text), width,
      { text = numlead, hex = PAL.accent })
  elseif letlead then
    return wrap_runs(inline(letbody, PAL.text), width,
      { text = letlead, hex = PAL.accent })
  else
    return wrap_runs(inline(line, PAL.text), width, nil)
  end
end

-- ---------------------------------------------------------------------------
-- A plain (non-markdown) line block with a coloured prefix -- used for the user
-- echo, tool headers, errors and system notes. The prefix leads the first line;
-- wrapped and subsequent source lines get a blank indent so the text stays in a
-- clean column. Returns a list of lines (run lists).
-- ---------------------------------------------------------------------------
local function simple_runs(text, prefix_text, hex, opts, bold)
  local width = opts and opts.width
  local blank = string.rep(" ", vis_len(prefix_text))
  local out, first = {}, true
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    local pfx = {
      text = first and prefix_text or blank,
      hex  = first and hex or nil,
      bold = first and bold or nil,
    }
    for _, l in ipairs(wrap_runs({ { text = line, hex = hex, bold = bold } }, width, pfx)) do
      out[#out + 1] = l
    end
    first = false
  end
  if #out == 0 then out[1] = { { text = prefix_text, fg = hex } } end
  return out
end

local function textof(x)
  if type(x) == "table" then return x.text or "" end
  return tostring(x or "")
end

-- A hunk row from difflib.compute, as one run: green add, red remove, dim context.
local function diff_row_run(kind, text)
  if kind == "+" then return { text = "+ " .. text, fg = PAL.good }
  elseif kind == "-" then return { text = "- " .. text, fg = PAL.err }
  else return { text = "  " .. text, fg = PAL.dim } end
end

-- One line of a raw unified diff as a run, classified by its leading marker.
local function unified_run(line)
  local h = line:sub(1, 1)
  if line:match("^%+%+%+") or line:match("^%-%-%-") or line:match("^diff ") then
    return { text = line, fg = PAL.accent, attr = { bold = true } }
  elseif line:match("^@@") then
    return { text = line, fg = PAL.keyword }
  elseif h == "+" then return { text = line, fg = PAL.good }
  elseif h == "-" then return { text = line, fg = PAL.err }
  else return { text = line, fg = PAL.dim } end
end

-- ---------------------------------------------------------------------------
-- GFM tables -- terminals are monospace, so a table renders as CLEANLY aligned
-- columns rather than the raw pipe soup markdown source. A block is a header
-- row, a delimiter row (dashes/colons, not rendered, only read for alignment),
-- and zero or more data rows. We measure columns in display cells (vis_len),
-- pad/truncate every cell to its column so the grid stays square, and never
-- wrap a cell -- an overlong one is cut to (w-1)+"…" so the row keeps its width.
-- ---------------------------------------------------------------------------

-- A real (unescaped) column pipe: '\|' is an escaped literal, not a separator.
local function has_pipe(line)
  return line:gsub("\\|", ""):find("|", 1, true) ~= nil
end

-- Split a table row into trimmed cells. One optional leading and trailing '|'
-- (the outer border) is stripped, the split is on '|' that is not escaped as
-- '\|', and each '\|' collapses back to a literal '|' in the cell text.
local function split_row(line)
  local s = line:match("^%s*(.-)%s*$")            -- trim the row ends
  s = s:gsub("^|", "")                            -- drop one leading border pipe
  if s:sub(-1) == "|" and s:sub(-2) ~= "\\|" then -- ...and an unescaped trailing one
    s = s:sub(1, -2)
  end
  local cells, cur, i, n = {}, {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\\" and s:sub(i + 1, i + 1) == "|" then
      cur[#cur + 1] = "|"; i = i + 2                -- unescape '\|' -> '|'
    elseif c == "|" then
      cells[#cells + 1] = table.concat(cur); cur = {}; i = i + 1
    else
      cur[#cur + 1] = c; i = i + 1
    end
  end
  cells[#cells + 1] = table.concat(cur)
  for k, v in ipairs(cells) do cells[k] = v:match("^%s*(.-)%s*$") end
  return cells
end

-- Is `line` a GFM delimiter row? It must carry a real pipe (so a bare "---"
-- hrule under a piped line is not mistaken for one) and every '|'-split cell
-- must be dashes with optional leading/trailing colons.
local function is_delim_row(line)
  if not has_pipe(line) then return false end
  local cells = split_row(line)
  if #cells == 0 then return false end
  for _, c in ipairs(cells) do
    if not c:match("^%s*:?%-+:?%s*$") then return false end
  end
  return true
end

-- Column alignment from its delimiter cell: ':-:' centre, '--:' right, ':--'
-- and plain '---' left (the default).
local function align_of(cell)
  local c = cell:match("^%s*(.-)%s*$")
  local l, r = c:sub(1, 1) == ":", c:sub(-1) == ":"
  if l and r then return "center" elseif r then return "right" else return "left" end
end

-- Pad or truncate `s` to exactly `w` display cells under `align`. An overlong
-- cell is cut to (w-1) cells plus "…" so it still occupies w -- never wrapped.
local function fit_cell(s, w, align)
  local len = vis_len(s)
  if len > w then
    local head = take(s, math.max(0, w - 1))
    s = head .. "\226\128\166"                       -- append "…" (U+2026)
    len = vis_len(s)
  end
  local pad = w - len
  if pad <= 0 then return s end
  if align == "right" then return string.rep(" ", pad) .. s
  elseif align == "center" then
    local left = math.floor(pad / 2)
    return string.rep(" ", left) .. s .. string.rep(" ", pad - left)
  else return s .. string.rep(" ", pad) end
end

-- Force a cell list to exactly `ncol` entries: missing cells are empty, extra
-- cells beyond the header's column count are dropped (GFM ignores them).
local function normalise(cells, ncol)
  for c = 1, ncol do cells[c] = cells[c] or "" end
  for c = #cells, ncol + 1, -1 do cells[c] = nil end
  return cells
end

-- Render the table beginning at L[start] (header, L[start+1] delimiter) into
-- `out`, and return the index of the first line PAST the block. Separators are
-- " │ " (U+2502) and the header gets a "─" rule; both ride the dim/divider
-- colour, header cells are bold accent, data cells the base text colour.
local MIN_COL = 3
local function table_runs(L, start, width, out)
  local n = #L
  local header = normalise(split_row(L[start]), #split_row(L[start]))
  local ncol   = #header
  local delim  = split_row(L[start + 1])
  local align = {}
  for c = 1, ncol do align[c] = delim[c] and align_of(delim[c]) or "left" end

  -- Data rows: the contiguous run of following lines that still look like table
  -- rows (non-blank, carry a pipe, not a fence). Advance past the whole block.
  local rows, i = {}, start + 2
  while i <= n do
    local ln = L[i]
    if ln:match("^%s*$") or not has_pipe(ln) or ln:match("^%s*```") then break end
    rows[#rows + 1] = normalise(split_row(ln), ncol)
    i = i + 1
  end

  -- Natural column widths = widest cell in the column, floored at MIN_COL.
  local col = {}
  for c = 1, ncol do
    local w = vis_len(header[c])
    for _, r in ipairs(rows) do local cw = vis_len(r[c]); if cw > w then w = cw end end
    col[c] = math.max(MIN_COL, w)
  end

  -- Fit the whole grid (columns + the 3-cell " │ " separators) inside width by
  -- shrinking the widest column a cell at a time until it fits or all are at
  -- the floor; fit_cell then truncates any cell that no longer fits its column.
  local function total()
    local t = 0
    for c = 1, ncol do t = t + col[c] end
    return t + 3 * (ncol - 1)
  end
  if width then
    while total() > width do
      local widest, wc = 0, nil
      for c = 1, ncol do
        if col[c] > MIN_COL and col[c] > widest then widest, wc = col[c], c end
      end
      if not wc then break end                       -- everything at the floor
      col[wc] = col[wc] - 1
    end
  end

  -- One row of runs: cells styled by fg/bold, separated by a dim " │ ". The
  -- concatenated run texts are exactly the padded row (the plain-text invariant).
  local function row_runs(cells, hex, bold)
    local line = {}
    for c = 1, ncol do
      if c > 1 then line[#line + 1] = { text = " \226\148\130 ", fg = PAL.dim } end   -- " │ "
      line[#line + 1] = { text = fit_cell(cells[c], col[c], align[c]), fg = hex,
        attr = bold and { bold = true } or nil }
    end
    return line
  end

  out[#out + 1] = row_runs(header, PAL.accent, true)
  -- The under-header rule: each column's "─" run, joined by "─┼─" so a crossing
  -- lands under every " │ ", the whole thing in the divider colour.
  local segs = {}
  for c = 1, ncol do segs[#segs + 1] = string.rep("\226\148\128", col[c]) end
  out[#out + 1] = { { text = table.concat(segs, "\226\148\128\226\148\188\226\148\128"),
    fg = PAL.divider } }
  for _, r in ipairs(rows) do out[#out + 1] = row_runs(r, PAL.text, false) end
  return i
end

-- ---------------------------------------------------------------------------
-- Core run builders, one per kind. Each returns lines = { {run,...}, ... }.
-- ---------------------------------------------------------------------------

local function assistant_runs(entry, opts)
  local text = textof(entry)
  local width = opts and opts.width
  local out = {}
  local in_code, fence_len, lang = false, 0, nil
  local st = { block = false }

  -- Collect the lines into an array so a table can look ahead one line (a table
  -- is only a table when the NEXT line is its delimiter row). Non-table content
  -- flows through the same fence/md_line_runs path as before, unchanged.
  local L = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do L[#L + 1] = line end

  local i, n = 1, #L
  while i <= n do
    local line = L[i]
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
      i = i + 1
    elseif in_code then
      local rws
      rws, st = code_line_runs(line, lang, st, width)
      for _, r in ipairs(rws) do out[#out + 1] = r end
      i = i + 1
    elseif not in_code and has_pipe(line) and i < n and is_delim_row(L[i + 1]) then
      -- A GFM table: header L[i], delimiter L[i+1]. Consume the whole block.
      i = table_runs(L, i, width, out)
    else
      for _, l in ipairs(md_line_runs(line, width)) do out[#out + 1] = l end
      i = i + 1
    end
  end
  return out
end

-- Diffs. Accepts, in order of preference:
--   * an entry { diff = <difflib result>, path = ... } (what agentview pushes)
--   * a difflib result directly (has .hunk)
--   * a raw unified-diff string
local function diff_runs(x, opts)
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
    out[#out + 1] = { { text = "\226\150\184 " .. head, fg = PAL.accent, attr = { bold = true } } }
    for _, row in ipairs(d.hunk) do
      out[#out + 1] = { diff_row_run(row[1], row[2]) }
    end
  elseif raw and raw ~= "" then
    for line in (raw .. "\n"):gmatch("(.-)\n") do
      out[#out + 1] = { unified_run(line) }
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Public runs API + dispatcher. runs(entry, opts) -> lines is the core; the
-- ANSI functions below serialise the same lines. Each simple kind carries its
-- own prefix glyph and colour (see agentview).
-- ---------------------------------------------------------------------------
local RUNS = {
  assistant = assistant_runs,
  user  = function(e, o) return simple_runs(textof(e), "\226\128\186 ", PAL.accent, o) end,        -- "› "
  tool  = function(e, o) return simple_runs(textof(e), "\194\187 ", PAL.keyword, o) end,           -- "» "
  error = function(e, o) return simple_runs(textof(e), "\226\156\151 ", PAL.err, o, true) end,     -- "✗ "
  system = function(e, o) return simple_runs(textof(e), "\194\183 ", PAL.dim, o) end,              -- "· "
  diff  = diff_runs,
}

-- runs(entry, opts) -> lines. Unknown roles fall back to assistant, the most
-- forgiving builder (plain prose still reads correctly through it).
function M.runs(entry, opts)
  entry = entry or {}
  local fn = RUNS[entry.role or "assistant"] or assistant_runs
  return fn(entry, opts)
end

-- ---------------------------------------------------------------------------
-- Public per-kind ANSI renderers -- a serialiser over the runs above. Each
-- accepts either an entry table or a bare string, plus opts { width, color }.
-- ---------------------------------------------------------------------------
function M.assistant(entry, opts) return serialise(assistant_runs(entry, opts), opts) end
function M.user(entry, opts)  return serialise(RUNS.user(entry, opts), opts) end
function M.tool(entry, opts)  return serialise(RUNS.tool(entry, opts), opts) end
function M.error(entry, opts) return serialise(RUNS.error(entry, opts), opts) end
function M.system(entry, opts) return serialise(RUNS.system(entry, opts), opts) end
function M.diff(x, opts) return serialise(diff_runs(x, opts), opts) end

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
