-- markdown.lua -- a proportional Markdown layout engine for the studio.
--
-- Pure layout: a Markdown string + a target pixel width + a drawing context
-- (fonts, colours, a measure function) go in; a flat list of positioned visual
-- rows comes out. The view (markdownview.lua) supplies the context and does the
-- actual drawing, so this module has no dependency on a live renderer and the
-- two stay separable.
--
-- Unlike the chat transcript's renderer (AgentView, monospace/cell-based), this
-- lays out in PIXELS with a real proportional face and a heading size ramp -- the
-- "Zed-level" ask -- while reusing the same inline scanner idea and the editor's
-- tokenizer for fenced-code syntax highlighting.
--
-- A row is:
--   { y, h, kind, runs = { {font, color, text, x, w, bold?, url?, underline?}, ... },
--     rule?=true, code?=true, bg?=color, indent?=px }
-- and layout() returns { rows = {...}, height = px }.
local style = require "core.style"
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"
local common = require "core.common"

local M = {}

-- Fenced-code language -> a syntax table, or nil (no highlighter). Forward
-- declared as a local so M.layout can reach it without a global.
local EXT = {
  lua = "lua", c = "c", h = "h", cpp = "cpp", cc = "cpp", ["c++"] = "cpp",
  py = "py", python = "py", js = "js", javascript = "js", jsx = "js",
  ts = "js", json = "json", sh = "sh", bash = "sh", zsh = "sh", shell = "sh",
  html = "html", xml = "xml", css = "css", md = "md", markdown = "md",
}
local function syntax_get_for(lang)
  if not lang or lang == "" then return nil end
  local ext = EXT[lang:lower()] or lang:lower():match("^%w+$")
  if not ext then return nil end
  local syn = syntax.get("code." .. ext)
  if syn and syn.patterns and #syn.patterns > 0 then return syn end
  return nil
end

-- ---- inline spans ----------------------------------------------------------
-- A scanner, not a parser (same discipline as AgentView): find the earliest of
-- a few spans, emit it, continue -- so unusual markup renders as its own source.
-- Unlike AgentView's, links keep BOTH captures so the URL survives for a click.
local SPANS = {
  { pat = "!%[([^%]]*)%]%(([^)]+)%)", kind = "image" }, -- before link
  { pat = "%[([^%]]+)%]%(([^)]+)%)",  kind = "link"  },
  { pat = "`([^`]+)`",                kind = "code"  },
  { pat = "%*%*([^*]+)%*%*",          kind = "bold"  },
  { pat = "__([^_]+)__",              kind = "bold"  },
  { pat = "%*([^*]+)%*",              kind = "em"    },
  { pat = "_([^_]+)_",                kind = "em"    },
}

-- Split inline text into typed spans: { text=, bold=, em=, code=, url= }.
local function inline(text)
  local out, i = {}, 1
  while i <= #text do
    local best
    for _, sp in ipairs(SPANS) do
      local s1, e1, cap, cap2 = text:find(sp.pat, i)
      if s1 and (not best or s1 < best.s) then
        best = { s = s1, e = e1, cap = cap, cap2 = cap2, kind = sp.kind }
      end
    end
    if not best then
      out[#out + 1] = { text = text:sub(i) }
      break
    end
    if best.s > i then out[#out + 1] = { text = text:sub(i, best.s - 1) } end
    if best.kind == "code" then
      out[#out + 1] = { text = best.cap, code = true }
    elseif best.kind == "bold" then
      out[#out + 1] = { text = best.cap, bold = true }
    elseif best.kind == "em" then
      out[#out + 1] = { text = best.cap, em = true }
    elseif best.kind == "image" then
      out[#out + 1] = { text = best.cap ~= "" and best.cap or best.cap2, url = best.cap2, image = true }
    else -- link
      out[#out + 1] = { text = best.cap, url = best.cap2, link = true }
    end
    i = best.e + 1
  end
  return out
end

-- Split a GFM table row "| a | b |" into trimmed cell strings.
local function split_cells(s)
  s = s:gsub("^%s*|", ""):gsub("|%s*$", "")
  local out = {}
  for cell in (s .. "|"):gmatch("(.-)|") do
    out[#out + 1] = (cell:gsub("^%s+", ""):gsub("%s+$", ""))
  end
  return out
end

-- ---- block parse -----------------------------------------------------------
-- Turn the source into a list of blocks (no measurement yet).
--   { kind = "heading", level=, text= }
--   { kind = "para", text= }
--   { kind = "code", lang=, lines={...} }
--   { kind = "quote", text= }
--   { kind = "list", ordered=, marker=, indent=, text= }
--   { kind = "rule" }  { kind = "blank" }
local function parse(src)
  local blocks = {}
  local lines = {}
  for line in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end

  local i = 1
  while i <= #lines do
    local line = lines[i]
    local fence, lang = line:match("^%s*(```+)%s*([%w_+#%-]*)")
    if fence then
      local body = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^%s*" .. fence .. "%s*$") do
        body[#body + 1] = lines[i]; i = i + 1
      end
      i = i + 1 -- past the closing fence
      blocks[#blocks + 1] = { kind = "code", lang = lang, lines = body }
    else
      -- GFM table: a `| ... |` header line followed by a `| --- | :--: |`
      -- separator. Consume the header, the alignment row, and the body rows.
      local nxt = lines[i + 1]
      if line:match("^%s*|.*|%s*$") and nxt and nxt:match("^%s*|?[%s:%-|]-%-%-%-?[%s:%-|]*$") then
        local header = split_cells(line)
        local align = {}
        for c, cell in ipairs(split_cells(nxt)) do
          local l, r = cell:match("^:"), cell:match(":$")
          align[c] = (l and r and "center") or (r and "right") or "left"
        end
        i = i + 2
        local trows = {}
        while i <= #lines and lines[i]:match("^%s*|.*|?%s*$") and lines[i]:find("|") do
          trows[#trows + 1] = split_cells(lines[i]); i = i + 1
        end
        blocks[#blocks + 1] = { kind = "table", header = header, align = align, rows = trows }
      else
        local hashes, htext = line:match("^(#+)%s+(.*)$")
        local q = line:match("^%s*>%s?(.*)$")
        local li_ind, li_marker, li_text = line:match("^(%s*)([-*+])%s+(.*)$")
        local ol_ind, ol_num, ol_text = line:match("^(%s*)(%d+[.)])%s+(.*)$")
        if line:match("^%s*[-*_]%s*[-*_]%s*[-*_][-*_ ]*$") then
          blocks[#blocks + 1] = { kind = "rule" }
        elseif hashes then
          blocks[#blocks + 1] = { kind = "heading", level = math.min(#hashes, 6), text = htext }
        elseif q then
          blocks[#blocks + 1] = { kind = "quote", text = q }
        elseif li_marker then
          -- task list: "- [ ] todo" / "- [x] done"
          local box, rest = li_text:match("^%[([ xX])%]%s+(.*)$")
          blocks[#blocks + 1] = { kind = "list", ordered = false, marker = "\u{2022}",
            indent = #li_ind, text = box and rest or li_text,
            task = box ~= nil, done = (box == "x" or box == "X") }
        elseif ol_num then
          blocks[#blocks + 1] = { kind = "list", ordered = true, marker = ol_num,
            indent = #ol_ind, text = ol_text }
        elseif line:match("^%s*$") then
          blocks[#blocks + 1] = { kind = "blank" }
        else
          blocks[#blocks + 1] = { kind = "para", text = line }
        end
      end
      i = i + 1
    end
  end
  return blocks
end

M.parse = parse
M.inline = inline

-- ---- layout ----------------------------------------------------------------
-- ctx = {
--   body, code, em, h = {f1,...,f6},   -- fonts
--   measure(font, s) -> px,            -- text width
--   colors = { text, heading, code, quote, link, rule, code_bg },
--   syntax = bool,                     -- highlight fenced code
-- }
-- Heading size ramp is baked into ctx.h by the view. Body/code/em are fonts.

local HEADING_GAP = 6

-- Wrap a run-list (spans with fonts already chosen) to `avail` px at x origin
-- `x0`, producing visual rows. Returns { {runs=..., w=...}, ... }. Breaks at
-- word boundaries, and inside a word only if it alone overflows.
local function wrap_runs(spans, avail, x0, measure)
  local rows, cur, x = {}, {}, x0
  local function flush()
    rows[#rows + 1] = { runs = cur, w = x - x0 }
    cur, x = {}, x0
  end
  for _, sp in ipairs(spans) do
    -- split the span text into words + the spaces between them, keeping spaces
    for word, space in (sp.text .. "\0"):gmatch("(%S*)([%s%z]*)") do
      if word == "" and space == "" then break end
      for _, piece in ipairs({ { word, false }, { space:gsub("%z", ""), true } }) do
        local txt, is_space = piece[1], piece[2]
        if txt ~= "" then
          local w = measure(sp.font, txt)
          if not is_space and x + w > x0 + avail and x > x0 then flush() end
          -- a single word wider than the line: hard-break it by characters
          if not is_space and w > avail then
            for ch in common.utf8_chars(txt) do
              local cw = measure(sp.font, ch)
              if x + cw > x0 + avail and x > x0 then flush() end
              cur[#cur + 1] = { font = sp.font, color = sp.color, text = ch,
                x = x, w = cw, bold = sp.bold, url = sp.url, underline = sp.underline }
              x = x + cw
            end
          elseif not (is_space and x == x0) then -- swallow leading spaces on a row
            cur[#cur + 1] = { font = sp.font, color = sp.color, text = txt,
              x = x, w = w, bold = sp.bold, url = sp.url, underline = sp.underline }
            x = x + w
          end
        end
      end
    end
  end
  flush()
  return rows
end

-- Turn inline spans into drawable spans with fonts+colours chosen from ctx.
local function style_spans(text, ctx, base_font, base_color)
  local spans = {}
  for _, s in ipairs(inline(text)) do
    local font, color = base_font, base_color
    local underline = false
    if s.code then font, color = ctx.code, ctx.colors.code
    elseif s.link or s.image then color, underline = ctx.colors.link, true
    elseif s.em then font = ctx.em or base_font; color = ctx.colors.text
    end
    spans[#spans + 1] = { font = font, color = color, text = s.text,
      bold = s.bold, url = s.url, underline = underline }
  end
  if #spans == 0 then spans[1] = { font = base_font, color = base_color, text = "" } end
  return spans
end

function M.layout(text, width, ctx)
  local rows = {}
  local pad = style.padding.x
  local avail = math.max(20, width - pad * 2)
  local y = style.padding.y
  local measure = ctx.measure
  local colors = ctx.colors

  local function line_h(font) return math.floor(font:get_height() * 1.35) end
  local function emit_wrapped(spans, x0, kind, extra)
    local wr = wrap_runs(spans, avail - (x0 - pad), x0, measure)
    local lh = line_h(spans[1] and spans[1].font or ctx.body)
    for ri, r in ipairs(wr) do
      rows[#rows + 1] = { y = y, h = lh, kind = kind, runs = r.runs,
        indent = x0, extra = extra, first = ri == 1 }
      y = y + lh
    end
  end

  local blocks = parse(text)
  for bi, b in ipairs(blocks) do
    if b.kind == "blank" then
      y = y + math.floor(line_h(ctx.body) * 0.4)
    elseif b.kind == "rule" then
      y = y + 6
      rows[#rows + 1] = { y = y, h = 1, kind = "rule", runs = {},
        rule = true, x = pad, w = avail }
      y = y + 10
    elseif b.kind == "heading" then
      local hf = ctx.h[b.level] or ctx.body
      y = y + (b.level <= 2 and HEADING_GAP * 2 or HEADING_GAP)
      local spans = style_spans(b.text, ctx, hf, colors.heading)
      for _, s in ipairs(spans) do s.bold = true end
      emit_wrapped(spans, pad, "heading", { level = b.level })
      if b.level <= 2 then
        y = y + 2
        rows[#rows + 1] = { y = y, h = 1, kind = "rule", runs = {}, rule = true,
          x = pad, w = avail, faint = true }
        y = y + 4
      end
    elseif b.kind == "quote" then
      local spans = style_spans(b.text, ctx, ctx.body, colors.quote)
      emit_wrapped(spans, pad + 14, "quote", nil)
    elseif b.kind == "list" then
      local x0 = pad + b.indent * measure(ctx.body, " ") + 18
      local spans = style_spans(b.text, ctx, ctx.body, colors.text)
      -- the marker: a checkbox for a task item, else the bullet/number.
      local mk, mkcolor
      if b.task then
        mk = (b.done and "\u{2611}" or "\u{2610}") .. " "
        mkcolor = b.done and (colors.done or colors.link) or (colors.marker or colors.text)
      else
        mk = b.marker .. " "
        mkcolor = colors.marker or colors.text
      end
      local wr = wrap_runs(spans, avail - (x0 - pad), x0, measure)
      local lh = line_h(ctx.body)
      for ri, r in ipairs(wr) do
        local runs = r.runs
        if ri == 1 then
          table.insert(runs, 1, { font = ctx.body, color = mkcolor,
            text = mk, x = x0 - measure(ctx.body, mk), w = measure(ctx.body, mk) })
        end
        rows[#rows + 1] = { y = y, h = lh, kind = "list", runs = runs, indent = x0, first = ri == 1 }
        y = y + lh
      end
    elseif b.kind == "code" then
      local syn = ctx.syntax and syntax_get_for(b.lang)
      y = y + 4
      local cf = ctx.code
      local clh = line_h(cf)
      local state
      for _, cl in ipairs(b.lines) do
        local runs = {}
        local x = pad + 8
        if syn then
          local res, nxt = tokenizer.tokenize(syn, cl .. "\n", state)
          state = nxt
          for _, tp, tx in tokenizer.each_token(res) do
            tx = tx:gsub("\n$", "")
            if tx ~= "" then
              local w = measure(cf, tx)
              runs[#runs + 1] = { font = cf, color = style.syntax[tp] or colors.code, text = tx, x = x, w = w }
              x = x + w
            end
          end
        else
          local w = measure(cf, cl)
          runs[#runs + 1] = { font = cf, color = colors.code, text = cl, x = pad + 8, w = w }
        end
        rows[#rows + 1] = { y = y, h = clh, kind = "code", runs = runs, code = true,
          bg = colors.code_bg, x = pad, w = avail }
        y = y + clh
      end
      y = y + 4
    elseif b.kind == "table" then
      local ncol = math.max(1, #b.header)
      local cellpad = 8
      local lh = line_h(ctx.body)
      -- natural column widths from header + body, then shrink to fit the width.
      local colw = {}
      for c = 1, ncol do colw[c] = measure(ctx.body, b.header[c] or "") end
      for _, row in ipairs(b.rows) do
        for c = 1, ncol do colw[c] = math.max(colw[c], measure(ctx.body, row[c] or "")) end
      end
      local total = 0
      for c = 1, ncol do colw[c] = colw[c] + cellpad * 2; total = total + colw[c] end
      if total > avail and total > 0 then
        local scale = avail / total
        for c = 1, ncol do colw[c] = math.max(measure(ctx.body, "…") + cellpad * 2,
          math.floor(colw[c] * scale)) end
      end
      local colx, x = {}, pad
      for c = 1, ncol do colx[c] = x; x = x + colw[c] end
      local tw = x - pad

      local function emit_table_row(cells, header)
        local cellrows, maxlines = {}, 1
        for c = 1, ncol do
          local base = header and colors.heading or colors.text
          local spans = style_spans(cells and cells[c] or "", ctx, ctx.body, base)
          if header then for _, s in ipairs(spans) do s.bold = true end end
          local wr = wrap_runs(spans, colw[c] - cellpad * 2, colx[c] + cellpad, measure)
          cellrows[c] = wr
          maxlines = math.max(maxlines, #wr)
        end
        for li = 1, maxlines do
          local runs = {}
          for c = 1, ncol do
            local wr = cellrows[c][li]
            if wr then for _, run in ipairs(wr.runs) do runs[#runs + 1] = run end end
          end
          rows[#rows + 1] = { y = y, h = lh, kind = "table", runs = runs,
            x = pad, w = tw, bg = header and colors.code_bg or nil }
          y = y + lh
        end
      end

      y = y + 4
      emit_table_row(b.header, true)
      rows[#rows + 1] = { y = y, h = 1, kind = "rule", runs = {}, rule = true, x = pad, w = tw }
      y = y + 2
      for _, row in ipairs(b.rows) do emit_table_row(row, false) end
      y = y + 6
    else -- para
      local spans = style_spans(b.text, ctx, ctx.body, colors.text)
      emit_wrapped(spans, pad, "para", nil)
    end
  end

  return { rows = rows, height = y + style.padding.y }
end

return M
