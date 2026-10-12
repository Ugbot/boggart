-- story/draft.lua -- drafting by continuous expansion, one line at a time.
--
-- What broke before was context: a swarm drafting whole chapters, each agent
-- holding a different, drifting picture of the book, and long single turns
-- that ran out of window or output and came back short while claiming
-- otherwise. What works (Story Engine's lesson, and Ben's experience) is to
-- break the chapter down until every step is small, then expand in order,
-- each step seeing what was just written:
--
--   chapter card  ->  beats (a line per scene movement)
--                 ->  paragraph lines (a line per paragraph, under its beat)
--                 ->  prose (one paragraph per line, appended in order)
--
-- The PLAN is a markdown file in the book, <root>/.boggart/plans/chNN.md:
--
--   ---
--   chapter: 13
--   title: The Red Door
--   pov: vera
--   target: chapters/13.md
--   ---
--   Card: Vera opens the door; Moth learns the price.
--
--   - Vera reaches the red door.
--     - [x] She counts the steps; nine, as always.
--     - [ ] Moth waits below with the lamp, humming.
--   - The door does not open.
--
-- Beats are top-level bullets; paragraph lines are indented checkboxes. The
-- next step is always the FIRST unfinished thing in reading order: a beat with
-- no lines is outlined (expanded into paragraph lines), else its first
-- unchecked line is written. So the outline never runs far ahead of the prose,
-- and every paragraph is written knowing the one before it.
--
-- Each step gets a BOUNDED packet, not a growing conversation: the rules, the
-- POV voice, the card, the beats as the chapter's own summary (done beats are
-- what already happened; the next ones are what not to get ahead of), the last
-- few hundred words verbatim, the cast named in this line, and retrieval from
-- the canon. The plan lines ARE the running summary -- nothing to re-read.
--
-- `draft run` loops steps with a FRESH model call each (context never grows);
-- `draft next` + `draft write` let a model in a conversation do the same by
-- hand. Words are always measured on disk, never taken from the model. Every
-- write is appended (a chapter can only grow here) and checkpointed to a
-- hidden git ref, so nothing written is ever only in a chat again.
local sb = require("story.book")
local si = require("story.index")
local ss = require("story.style")
local sd_decode = require("story.decode")
local bl = require("story.baseline")
local M = {}

-- The drafting unit is a BEAT (Ben's decision, and what the field ships: one
-- call writes a beat's paragraph lines as ~400-800 words); `unit: line` in a
-- plan's front matter keeps one paragraph per call for fine control.
M.DEFAULTS = { budget = 24000, tail_words = 450, prev_tail_words = 200, lookahead = 3,
               paragraphs = "4-8", max_tokens_write = 3000, max_tokens_outline = 1024, unit = "beat",
               exemplars = 3 }

local function E(m) return "Error: " .. m end

-- ---- the plan file ------------------------------------------------------------------------
function M.plan_path(book, n)
  return book.root .. "/.boggart/plans/" .. string.format("ch%02d.md", n) end

function M.parse(text)
  local p = { meta = {}, preamble = {}, beats = {} }
  local lines = {}
  for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  local i = 1
  if lines[1] == "---" then
    i = 2
    while lines[i] and lines[i] ~= "---" do
      local k, v = lines[i]:match("^([%w_]+):%s*(.-)%s*$")
      if k then p.meta[k] = v end
      i = i + 1
    end
    i = i + 1
  end
  local cur
  for j = i, #lines do
    local l = lines[j]
    local beat = l:match("^%- (.*)$")
    if beat then
      beat = beat:gsub("^%[[ xX]%]%s*", "")
      cur = { text = beat, lines = {}, notes = {} }
      p.beats[#p.beats + 1] = cur
    elseif cur then
      local box, t = l:match("^%s+%- %[([ xX])%]%s*(.*)$")
      if not box then t = l:match("^%s+%- (.*)$"); box = t and " " end
      if t then cur.lines[#cur.lines + 1] = { text = t, done = box ~= " " }
      elseif l:match("%S") then cur.notes[#cur.notes + 1] = l end
    else
      p.preamble[#p.preamble + 1] = l
    end
  end
  while #p.preamble > 0 and not p.preamble[#p.preamble]:match("%S") do p.preamble[#p.preamble] = nil end
  for bi, b in ipairs(p.beats) do
    b.id = tostring(bi)
    b.done = #b.lines > 0
    for li, ln in ipairs(b.lines) do
      ln.id = bi .. "." .. li
      if not ln.done then b.done = false end
    end
  end
  local last_id, last_off = (p.meta.last or ""):match("^(%S+)%s+(%d+)$")
  p.last_id, p.last_off = last_id, tonumber(last_off)
  p.card = nil
  for _, l in ipairs(p.preamble) do
    local c = l:match("^%s*Card:%s*(.+)$")
    if c then p.card = c end
  end
  return p
end

M.META_ORDER = { "chapter", "title", "pov", "narration", "style", "unit", "target", "append", "started", "last" }
function M.render(p)
  local out = { "---" }
  if p.last_id then p.meta.last = p.last_id .. " " .. tostring(p.last_off) end
  local seen = {}
  for _, k in ipairs(M.META_ORDER) do
    if p.meta[k] and p.meta[k] ~= "" then out[#out + 1] = k .. ": " .. p.meta[k]; seen[k] = true end
  end
  local extra = {}
  for k in pairs(p.meta) do if not seen[k] then extra[#extra + 1] = k end end
  table.sort(extra)
  for _, k in ipairs(extra) do out[#out + 1] = k .. ": " .. p.meta[k] end
  out[#out + 1] = "---"
  for _, l in ipairs(p.preamble) do out[#out + 1] = l end
  if #p.preamble > 0 then out[#out + 1] = "" end
  for _, b in ipairs(p.beats) do
    out[#out + 1] = "- " .. b.text
    for _, l in ipairs(b.lines) do out[#out + 1] = "  - [" .. (l.done and "x" or " ") .. "] " .. l.text end
    for _, nt in ipairs(b.notes) do out[#out + 1] = nt end
  end
  return table.concat(out, "\n") .. "\n"
end

local function write_file(path, text)
  local dir = path:match("^(.*)/[^/]+$")
  if dir and sys.stat(dir) ~= "dir" then sys.mkdir_p(dir) end
  local tmp = path .. ".tmp"
  local f, e = io.open(tmp, "wb")
  if not f then return nil, e end
  f:write(text); f:close()
  local ok, re = os.rename(tmp, path)
  if not ok then return nil, re end
  return true
end

function M.load_plan(book, n)
  local text = sb.read(M.plan_path(book, n))
  if not text then return nil end
  return M.parse(text)
end

function M.save_plan(book, n, p) return write_file(M.plan_path(book, n), M.render(p)) end

-- ---- what comes next ----------------------------------------------------------------------------
function M.unit(p) return (p.meta.unit == "line") and "line" or M.DEFAULTS.unit end

-- -> { kind = "outline", beat } | { kind = "write", beat, line, lines } | { kind = "done" | "empty" }
-- A write covers the beat's remaining lines (unit beat) or its next line (unit line).
function M.next_task(p)
  for _, b in ipairs(p.beats) do
    if #b.lines == 0 then return { kind = "outline", beat = b } end
    local todo = {}
    for _, l in ipairs(b.lines) do if not l.done then todo[#todo + 1] = l end end
    if #todo > 0 then
      if M.unit(p) == "line" then todo = { todo[1] } end
      return { kind = "write", beat = b, line = todo[1], lines = todo,
               id = M.unit(p) == "line" and todo[1].id or b.id }
    end
  end
  if #p.beats == 0 then return { kind = "empty" } end
  return { kind = "done" }
end

function M.progress(p)
  local lines, done, beats_done = 0, 0, 0
  for _, b in ipairs(p.beats) do
    for _, l in ipairs(b.lines) do lines = lines + 1; if l.done then done = done + 1 end end
    if b.done then beats_done = beats_done + 1 end
  end
  return { beats = #p.beats, beats_done = beats_done, lines = lines, lines_done = done }
end

-- The chapter file a plan writes to: the plan's `target`, else the manifest's
-- `manuscript.new` pattern ("chapters/%02d.md"), else the first manuscript
-- glob's directory + NN.md.
function M.target_of(book, n, p)
  if p and p.meta.target and p.meta.target ~= "" then return p.meta.target end
  local pat = book.m.manuscript.new
  if pat then return string.format(pat, n) end
  local g = book.m.manuscript.glob[1] or "chapters/*.md"
  local dir = g:match("^(.*)/[^/]*$")
  return (dir and (dir .. "/") or "") .. string.format("%02d.md", n)
end

-- The style set in force for a plan (its `style:`, else its POV's, else the book's).
function M.style_of(book, p)
  local S = ss.load(book)
  local E, err = ss.resolve(S, { set = p.meta.style, pov = p.meta.pov })
  if E and p.meta.narration then E.narration = p.meta.narration end
  return S, E, err
end

-- ---- the packet ---------------------------------------------------------------------------------------
local function last_words(text, n)
  local ws = {}
  for w in text:gmatch("%S+") do ws[#ws + 1] = w end
  if #ws <= n then return (text:gsub("^%s+", ""):gsub("%s+$", "")) end
  local pos = #text + 1
  local k, target = 0, #ws - n + 1
  for s in text:gmatch("()%S+") do
    k = k + 1
    if k == target then pos = s; break end
  end
  return "…" .. (text:sub(pos):gsub("%s+$", ""))
end

local STOPW = { the = 1, with = 1, that = 1, this = 1, from = 1, into = 1, what = 1, when = 1,
                they = 1, them = 1, their = 1, there = 1, have = 1, been = 1, were = 1, will = 1, would = 1,
                about = 1, again = 1, before = 1, after = 1, only = 1, still = 1, ["then"] = 1, than = 1 }

local function cast_in(book, text)
  local out = {}
  local json = require("json")
  for _, c in ipairs(si.characters(book)) do
    for _, a in ipairs(json.decode(c.aliases or "[]")) do
      if text:find("%f[%w]" .. a:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "%f[%W]") then
        out[#out + 1] = c
        break
      end
    end
  end
  return out
end

local function retrieval(book, text, chapter_path, cap)
  local words, seen = {}, {}
  for w in text:lower():gmatch("[%a']+") do
    if #w >= 4 and not STOPW[w] and not seen[w] then seen[w] = true; words[#words + 1] = w end
  end
  if #words == 0 then return "" end
  local files = si.search_files(book, table.concat(words, " "), nil, "or")
  local out, used = {}, 0
  for _, f in ipairs(files) do
    if f.kind ~= "chapter" and f.path ~= chapter_path then
      local body = sb.read(book.root .. "/" .. f.path) or ""
      local ln = 0
      for line in (body .. "\n"):gmatch("(.-)\n") do
        ln = ln + 1
        local low = line:lower()
        local hit = false
        for _, w in ipairs(words) do if low:find(w, 1, true) then hit = true; break end end
        if hit and line:match("%S") and not line:match("^%s*#") then
          local s = string.format("%s:%d: %s", f.path, ln, (line:gsub("^%s+", "")))
          if #s > 300 then s = s:sub(1, 297) .. "..." end
          if used + #s > cap then return table.concat(out, "\n") end
          out[#out + 1] = s; used = used + #s + 1
          break
        end
      end
    end
    if #out >= 6 then break end
  end
  return table.concat(out, "\n")
end

-- Blocks are output in the order given; each has a cap, and when the whole is
-- over budget the blocks with the HIGHEST `prio` number are trimmed, then
-- dropped, first -- `keep` blocks never. The report says what happened.
local function assemble(blocks, budget)
  local total = 0
  for _, b in ipairs(blocks) do
    if b.cap and #b.text > b.cap then b.text = b.text:sub(1, b.cap) .. "\n[trimmed]"; b.trimmed = true end
    total = total + #b.text
  end
  local order = {}
  for i, b in ipairs(blocks) do if not b.keep then order[#order + 1] = i end end
  table.sort(order, function(x, y) return (blocks[x].prio or 5) > (blocks[y].prio or 5) end)
  for _, i in ipairs(order) do
    if total <= budget then break end
    local b = blocks[i]
    local over = total - budget
    if over >= #b.text - 200 then
      total = total - #b.text; b.text = ""; b.dropped = true
    else
      total = total - over
      b.text = b.text:sub(1, #b.text - over) .. "\n[trimmed]"; b.trimmed = true
    end
  end
  local out, report = {}, {}
  for _, b in ipairs(blocks) do
    if b.text ~= "" then out[#out + 1] = "## " .. b.title .. "\n" .. b.text end
    report[#report + 1] = string.format("%s %d%s", b.title, #b.text, b.dropped and " (dropped)" or (b.trimmed and " (trimmed)" or ""))
  end
  return table.concat(out, "\n\n"), report
end

-- The drafting packet (docs/story-style.md): the voice card first, the
-- author's own prose as the main signal, the manuscript so far, and the task
-- LAST -- so the model continues the manuscript. No rules, no banned words:
-- those are the checker's job (long rule lists get dropped, and naming a
-- banned word can prime it).
function M.packet(book, n, p, task, opts)
  opts = opts or {}
  local budget = tonumber(opts.budget) or M.DEFAULTS.budget
  local S, Est, serr = M.style_of(book, p)
  local target = M.target_of(book, n, p)
  local chapter_text = sb.read(book.root .. "/" .. target) or ""
  local body = sb.drop_sections(chapter_text, book.m.drop_sections)
  local pov = p.meta.pov

  local blocks = {}
  local function add(title, text, cap, keep, prio)
    if text and text:match("%S") then blocks[#blocks + 1] = { title = title, text = text, cap = cap, keep = keep, prio = prio } end
  end

  -- 1. the voice card (short, positive; narration pinned)
  local voice
  if Est then
    voice = ss.voice_block(Est, pov)
  else
    voice = "Narration: " .. (p.meta.narration or book.m.narration or "match the person and tense already on the page") .. "."
  end
  add("Voice", voice, 1600, true)

  -- 2. the plan as the chapter's running summary
  local plan_lines = { "Chapter " .. n .. (p.meta.title and (": " .. p.meta.title) or "") }
  if p.card then plan_lines[#plan_lines + 1] = "Card: " .. p.card end
  if pov then plan_lines[#plan_lines + 1] = "POV: " .. pov end
  local ahead, after = 0, false
  local current = {}
  for _, l in ipairs(task.lines or {}) do current[l] = true end
  for _, b in ipairs(p.beats) do
    if b == task.beat then
      plan_lines[#plan_lines + 1] = "NOW  " .. b.id .. ". " .. b.text
      for _, l in ipairs(b.lines) do
        local mark = l.done and "done" or (current[l] and "THIS" or "next")
        plan_lines[#plan_lines + 1] = string.format("       %s %s %s", mark, l.id, l.text)
      end
      after = true
    elseif not after then
      plan_lines[#plan_lines + 1] = "done " .. b.id .. ". " .. b.text
    elseif ahead < M.DEFAULTS.lookahead then
      ahead = ahead + 1
      plan_lines[#plan_lines + 1] = "later " .. b.id .. ". " .. b.text
    end
  end
  add("Chapter plan", table.concat(plan_lines, "\n"), nil, true)

  -- 3-4. who is here, and what the canon says about it
  local here = task.beat.text
  for _, l in ipairs(task.lines or {}) do here = here .. " " .. l.text end
  local cast = {}
  for _, c in ipairs(cast_in(book, here)) do
    local sheet = sb.read(book.root .. "/" .. c.path) or ""
    cast[#cast + 1] = "### " .. (c.title ~= "" and c.title or c.id) .. "\n" .. sheet:sub(1, 900)
  end
  add("Cast", table.concat(cast, "\n\n"), math.floor(budget * 0.15), false, 3)
  add("From the book's canon", retrieval(book, here, target, math.floor(budget * 0.1)), math.floor(budget * 0.1), false, 4)

  -- 5. the author's own prose: the strongest style signal there is
  if Est then
    local mode = ss.mode_of(here, true)
    local ex = ss.pick(Est, { pov = pov, mode = mode, k = opts.exemplars or M.DEFAULTS.exemplars,
                              seed = n * 100 + (tonumber(task.beat.id) or 0) })
    if #ex > 0 then
      add("How this book is written (the author's own passages -- match this, not their content)",
        ss.exemplar_block(ex), math.floor(budget * 0.3), false, 2)
    end
  end

  -- 6. the manuscript so far, verbatim: the model continues it
  local tail = body:match("%S") and last_words(body, tonumber(opts.tail_words) or M.DEFAULTS.tail_words)
  if not tail or tail == "" then
    for _, c in ipairs(si.chapters(book)) do
      if c.n == n - 1 then
        local prev = sb.drop_sections(sb.read(book.root .. "/" .. c.path) or "", book.m.drop_sections)
        tail = "(end of chapter " .. c.n .. ")\n" .. last_words(prev, M.DEFAULTS.prev_tail_words)
      end
    end
  end
  add("The manuscript so far", tail, math.floor(budget * 0.25), true)

  -- 7. the task, last
  local task_text
  if task.kind == "outline" then
    task_text = string.format("Break beat %s into %s paragraph lines: one line per paragraph, in order, "
      .. "each a plain sentence with its own subject saying what happens in that paragraph "
      .. "(e.g. \"Vera counts the steps; there are nine.\"), not prose and not \"this paragraph...\". "
      .. "Cover this beat only; later beats are listed so you do not get ahead of them. "
      .. "Answer with the lines only, one per line.\n\nBEAT %s: %s", task.beat.id,
      opts.paragraphs or M.DEFAULTS.paragraphs, task.beat.id, task.beat.text)
  elseif #task.lines == 1 then
    task_text = string.format("Continue the manuscript with ONE paragraph that does exactly this and no more:\n\n  %s\n\n"
      .. "Pick up from its last words; do not repeat them, do not summarise, do not get ahead of what follows. "
      .. "Answer with the paragraph only.", task.lines[1].text)
  else
    local ls = {}
    for i, l in ipairs(task.lines) do ls[#ls + 1] = string.format("  %d. %s", i, l.text) end
    task_text = string.format("Continue the manuscript with beat %s: %d paragraphs, one for each line below, in order, "
      .. "as finished prose. Dramatise -- do not summarise, do not skip a line, do not get ahead of the beats that follow. "
      .. "Pick up from the manuscript's last words without repeating them. Answer with the prose only, paragraphs "
      .. "separated by a blank line.\n\n%s", task.beat.id, #task.lines, table.concat(ls, "\n"))
  end
  add("Task", task_text, nil, true)

  local text, report = assemble(blocks, budget)
  if serr then report[#report + 1] = "style: " .. serr end
  return text, report
end

-- ---- applying a step ---------------------------------------------------------------------------------
-- Model output -> clean text: fences, headings and wrapping quotes removed.
function M.clean_prose(s)
  s = tostring(s or ""):gsub("\r", "")
  s = s:gsub("^%s*```[%w]*\n", ""):gsub("\n```%s*$", "")
  local out = {}
  for l in (s .. "\n"):gmatch("(.-)\n") do
    if not l:match("^%s*#") then out[#out + 1] = l end
  end
  s = table.concat(out, "\n"):gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n\n\n+", "\n\n")
  if s:match('^".*"$') and not s:sub(2, -2):find('"', 1, true) then s = s:sub(2, -2) end
  return s
end

function M.clean_lines(s)
  local out = {}
  for raw in (tostring(s or "") .. "\n"):gmatch("(.-)\n") do
    local l = raw:gsub("^%s*[%-%*•]%s*", ""):gsub("^%s*%[[ xX]%]%s*", ""):gsub("^%s*%d+[%.%)]%s*", "")
         :gsub("^%s*[Pp]aragraph%s*[%d%.]*:?%s*", ""):gsub("%s+$", "")
    if l:match("%S") and not l:match("^%s*#") and not l:match("^```") then out[#out + 1] = l end
  end
  return out
end

local function checkpoint(book, n, beat_id)
  if not (type(_G.git) == "table" and type(_G.git.checkpoint) == "function") then return nil, "no git" end
  local ref = string.format("refs/boggart/checkpoints/story/%s/ch%02d/b%s",
    (book.name:gsub("[^%w%-_]", "_")), n, beat_id)
  local ok, sha, err = pcall(git.checkpoint, book.root, ref)
  if not ok then return nil, tostring(sha) end
  if not sha then return nil, err end
  return ref
end

local function chapter_words(book, target)
  return sb.word_count(sb.drop_sections(sb.read(book.root .. "/" .. target) or "", book.m.drop_sections))
end

-- One JSON line appended to a file in the book (generated prose, preferences).
local function append_jsonl(path, rec)
  sys.mkdir_p(path:match("^(.*)/[^/]+$"))
  local f = io.open(path, "ab")
  if f then f:write(require("json").encode(rec), "\n"); f:close() end
end
M.GENERATED = ".boggart/story/generated.jsonl"
M.PREFS = ".boggart/style/prefs.jsonl"
M.append_jsonl = append_jsonl

-- The style verdict and the drift for a piece of prose, as report lines.
function M.style_lines(book, p, prose, label)
  local out = {}
  local r = ss.check(book, prose, { set = p.meta.style, pov = p.meta.pov, label = label })
  if r then
    if r.errors > 0 then
      local es = {}
      for _, f in ipairs(r.findings) do
        if f.level == "error" then es[#es + 1] = f.id .. " " .. (f.line > 0 and ("line " .. f.line .. ": ") or "") .. f.message end
      end
      out[#out + 1] = "STYLE FAIL: " .. table.concat(es, "; ")
    elseif r.warnings > 0 then
      out[#out + 1] = string.format("style: %d warning(s) -- story style check", r.warnings)
    end
  end
  local B = bl.load(book.root)
  if B then
    local d = bl.drift(prose, B)
    if d and (#d.flagged > 0 or d.normalization >= 1) then
      local fl = {}
      for i, m in ipairs(d.flagged) do if i <= 3 then fl[#fl + 1] = string.format("%s %+.1f sd", m.label, m.z) end end
      out[#out + 1] = "VOICE DRIFT: " .. (#fl > 0 and table.concat(fl, "; ") or "")
        .. string.format(" (AI-normalization %+.2f)", d.normalization)
    end
  end
  return out, r
end

-- Append the prose for the next write task (a beat, or a line with unit=line).
-- -> report text, info | nil, err
function M.write(book, n, p, id, text, opts)
  opts = opts or {}
  local task = M.next_task(p)
  if task.kind ~= "write" then
    return nil, task.kind == "outline" and ("beat " .. task.beat.id .. " has no paragraph lines yet: outline it first (plan expand)")
      or ("nothing left to write in chapter " .. n)
  end
  local sid = id and tostring(id)
  if sid and sid ~= task.id and sid ~= task.line.id and not opts.force then
    return nil, "the next step is " .. task.id .. " (" .. (M.unit(p) == "line" and task.line.text or task.beat.text)
      .. "), not " .. sid .. " -- the chapter is written in order (force=true to override)"
  end
  local prose = M.clean_prose(text)
  if prose == "" then return nil, "empty prose" end

  local target = M.target_of(book, n, p)
  local full = book.root .. "/" .. target
  local existing = sb.read(full)
  if existing and existing:match("%S") and not p.meta.started and p.meta.append ~= "true" then
    return nil, target .. " already exists and this plan did not start it: set append=true on the plan "
      .. "(plan set ... append=true) or give the plan another target="
  end
  local before_words = existing and chapter_words(book, target) or 0
  local new
  if not existing or not existing:match("%S") then
    new = "# " .. (p.meta.title or ("Chapter " .. n)) .. "\n\n" .. prose .. "\n"
    p.last_off = 0
  else
    local base = existing:gsub("%s+$", "")
    p.last_off = #base
    new = base .. "\n\n" .. prose .. "\n"
  end
  local okw, we = write_file(full, new)
  if not okw then return nil, "could not write " .. target .. ": " .. tostring(we) end
  for _, l in ipairs(task.lines) do l.done = true end
  p.meta.started = "true"
  p.meta.target = target
  p.last_id = task.id
  local okp, pe = M.save_plan(book, n, p)
  if not okp then return nil, "wrote the prose but not the plan: " .. tostring(pe) end
  p = M.parse(M.render(p))
  append_jsonl(book.root .. "/" .. M.GENERATED, { chapter = n, id = task.id, text = prose, set = p.meta.style or "",
    origin = opts.origin or "model" })

  local after_words = chapter_words(book, target)
  local style, result = M.style_lines(book, p, prose, "beat " .. task.id)
  local beat_id = task.beat.id
  local beat_done = true
  for _, b in ipairs(p.beats) do if b.id == beat_id then beat_done = b.done end end
  local ref, cerr = checkpoint(book, n, beat_id)
  local out = { string.format("Wrote %s to %s: %d words; chapter %d -> %d words (measured on disk).",
    task.id, target, sb.word_count(prose), before_words, after_words) }
  for _, s in ipairs(style) do out[#out + 1] = s end
  out[#out + 1] = ref and ("Checkpoint: " .. ref) or ("No checkpoint (" .. tostring(cerr) .. ")")
  if beat_done then out[#out + 1] = "Beat " .. beat_id .. " complete." end
  local nt = M.next_task(p)
  out[#out + 1] = nt.kind == "write" and ("Next: write " .. nt.id .. " — " .. (M.unit(p) == "line" and nt.line.text or nt.beat.text))
    or nt.kind == "outline" and ("Next: outline beat " .. nt.beat.id .. " — " .. nt.beat.text)
    or "Chapter plan complete."
  return table.concat(out, "\n"), { result = result, words = after_words, prose = prose,
    issues = result and result.errors > 0 and { "style errors" } or {} }
end

-- Replace the most recently written step (a style fix, a better take). An
-- edit is measured against what it replaced: a rewrite that moved the prose
-- the way AI revision moves prose is said so. The author's own redo is logged
-- as a preference (before -> after).
function M.redo(book, n, p, text, opts)
  opts = opts or {}
  if not p.last_id or not p.last_off then return nil, "nothing written by this plan to redo" end
  local target = M.target_of(book, n, p)
  local full = book.root .. "/" .. target
  local existing = sb.read(full) or ""
  local prose = M.clean_prose(text)
  if prose == "" then return nil, "empty prose" end
  local old = existing:sub(p.last_off + 1):gsub("^%s+", ""):gsub("%s+$", "")
  if p.last_off == 0 then old = old:gsub("^#[^\n]*\n+", "") end
  local head = existing:sub(1, p.last_off)
  local new
  if p.last_off == 0 then new = "# " .. (p.meta.title or ("Chapter " .. n)) .. "\n\n" .. prose .. "\n"
  else new = head .. "\n\n" .. prose .. "\n" end
  local okw, we = write_file(full, new)
  if not okw then return nil, tostring(we) end
  checkpoint(book, n, tostring(p.last_id):match("^(%d+)"))
  local style, result = M.style_lines(book, p, prose, "redo " .. p.last_id)
  local out = { string.format("Rewrote %s: %d words (was %d); chapter now %d words.", p.last_id, sb.word_count(prose),
    sb.word_count(old), chapter_words(book, target)) }
  for _, s in ipairs(style) do out[#out + 1] = s end
  if #style == 0 then out[#out + 1] = "Style clean." end
  local shift = bl.edit_shift(old, prose)
  if shift and shift.normalization >= 1 then
    out[#out + 1] = string.format("VOICE: this rewrite moved the prose the way AI revision does (%+.2f): "
      .. "check it against the original.", shift.normalization)
  end
  if opts.author then
    append_jsonl(book.root .. "/" .. M.PREFS, { kind = "edit", chapter = n, id = p.last_id, before = old, after = prose })
  end
  return table.concat(out, "\n"), { result = result, issues = result and result.errors > 0 and { "style errors" } or {} }
end

function M.expand(book, n, p, beat_id, lines)
  local b
  for _, x in ipairs(p.beats) do if x.id == tostring(beat_id) then b = x end end
  if not b then return nil, "no beat " .. tostring(beat_id) end
  if type(lines) == "string" then lines = M.clean_lines(lines) end
  if #lines == 0 then return nil, "no paragraph lines given" end
  for _, l in ipairs(lines) do b.lines[#b.lines + 1] = { text = l, done = false } end
  local ok, e = M.save_plan(book, n, p)
  if not ok then return nil, tostring(e) end
  return string.format("Beat %s: %d paragraph line(s) added (%d now).", b.id, #lines, #b.lines)
end

-- ---- the model -------------------------------------------------------------------------------------
M.SYSTEM = "You are drafting a novel one small step at a time, continuing the author's manuscript in the author's "
  .. "own voice. Do only the step asked for, and answer with nothing but the text requested."

-- Overridable (tests): (system, user, opts) -> text, stop_reason
function M.model_impl(system, user, opts)
  local api = require("api")
  local rt = opts.model and require("route").resolve(opts.model) or nil
  -- sched.drive: inside a turn (the tool) this calls straight through; from
  -- `boggart story draft run` it becomes a one-shot actor on the loop.
  return require("sched").drive(function()
    local msg, stop = api.stream_async({
      model = (rt and rt.model) or (bog.session and bog.session.model),
      max_tokens = opts.max_tokens, system = system, sampler = opts.sampler,
      messages = { { role = "user", content = user } }, stream = true,
    }, nil, nil, rt)
    return api.msg_text(msg), stop
  end)
end

-- The call a step makes: book's sampler settings on a local model, and
-- backtracking over the book's error-level bans on every backend.
local function caller(book, p, opts, max_tokens)
  local S, E = M.style_of(book, p)
  local rules = E and ss.rules(E, book) or {}
  local okr, rt = pcall(function() return opts.model and require("route").resolve(opts.model) or require("route").current() end)
  local sampler = E and sd_decode.sampler(E, okr and rt or nil, rules) or nil
  local function call(user)
    return M.model_impl(M.SYSTEM, user, { model = opts.model, max_tokens = max_tokens, sampler = sampler })
  end
  return call, rules, S, E
end

-- ---- candidates: generate several, rank, the author picks ----------------------------------------
-- Lower is better: errors dominate, then warnings, then drift from the
-- author's baseline (and movement toward the AI median), then an optional
-- judge's score (LAMP's categories). -> score, detail
function M.score(book, p, prose, opts)
  opts = opts or {}
  local r = ss.check(book, prose, { set = p.meta.style, pov = p.meta.pov })
  local s = 0
  local detail = {}
  if r then
    s = s + r.errors * 100 + r.warnings * 5 + r.suggestions * 0.5
    detail[#detail + 1] = string.format("%d errors, %d warnings", r.errors, r.warnings)
  end
  local B = bl.load(book.root)
  if B then
    local d = bl.drift(prose, B)
    if d then
      s = s + #d.flagged * 3 + math.max(0, d.normalization) * 10
      detail[#detail + 1] = string.format("drift %d markers, AI-normalization %+.2f", #d.flagged, d.normalization)
    end
  end
  if opts.judge then
    local j = M.judge(prose, opts.call)
    if j then s = s - j * 5; detail[#detail + 1] = "judge " .. j .. "/10" end
  end
  return s, table.concat(detail, "; ")
end

M.JUDGE = "Rate the prose passage below from 1 (poor) to 10 (excellent) as a professional fiction editor would, "
  .. "counting against it: cliches, unnecessary exposition, purple prose, subtext spelled out, poor sentence rhythm, "
  .. "lack of specific detail, awkward word choice. Answer with the number only.\n\n"
function M.judge(prose, call)
  -- story.judge on the tier ladder (opt-in): a jev rubric first, the model after.
  local lj = bog and bog.ladder_sites and bog.ladder_sites.story_judge(prose, call, M.JUDGE .. prose)
  if lj then return lj end
  if not call then return nil end
  local ok, t = pcall(call, M.JUDGE .. prose)
  if not ok then return nil end
  local nnum = tonumber(tostring(t or ""):match("(%d+)"))
  if nnum and nnum >= 1 and nnum <= 10 then return nnum end
end

local function cand_path(book) return book.root .. "/.boggart/story/candidates.json" end

-- Draft k versions of the next write step, rank them, keep them for `pick`.
function M.candidates(book, n, k, opts)
  opts = opts or {}
  k = math.max(2, math.min(tonumber(k) or 3, 8))
  local p = M.load_plan(book, n)
  if not p then return nil, "no plan for chapter " .. n end
  local task = M.next_task(p)
  if task.kind ~= "write" then return nil, "the next step is not a write (" .. task.kind .. ")" end
  local packet = M.packet(book, n, p, task, opts)
  local call, rules = caller(book, p, opts, M.DEFAULTS.max_tokens_write)
  local items = {}
  for i = 1, k do
    local okc, text, _, stop = pcall(sd_decode.generate, call, packet, rules)
    if okc and text and stop ~= "max_tokens" then
      local prose = M.clean_prose(text)
      if prose ~= "" then
        local sc, detail = M.score(book, p, prose, { judge = opts.judge, call = call })
        items[#items + 1] = { text = prose, score = sc, detail = detail }
      end
    end
  end
  if #items == 0 then return nil, "no usable candidates" end
  table.sort(items, function(a, b) return a.score < b.score end)
  local f = assert(io.open(cand_path(book), "wb"))
  f:write(require("json").encode({ chapter = n, id = task.id, items = items }))
  f:close()
  local out = { string.format("%d candidates for %s (best first) -- pick one: story draft pick n=%d c=<number>", #items, task.id, n) }
  for i, it in ipairs(items) do
    out[#out + 1] = string.format("\n[%d] score %.1f  (%s, %d words)\n%s", i, it.score, it.detail, sb.word_count(it.text),
      it.text:sub(1, 400) .. (#it.text > 400 and " ..." or ""))
  end
  return table.concat(out, "\n")
end

-- Write candidate c and log the choice (chosen vs the rest) as a preference.
function M.pick(book, n, c, opts)
  opts = opts or {}
  local f = io.open(cand_path(book), "rb")
  if not f then return nil, "no candidates waiting (story draft candidates n=" .. n .. ")" end
  local ok, t = pcall(require("json").decode, f:read("a"))
  f:close()
  if not ok or t.chapter ~= n then return nil, "the waiting candidates are for chapter " .. tostring(t and t.chapter) end
  c = tonumber(c) or 1
  local chosen = t.items[c]
  if not chosen then return nil, "no candidate " .. c .. " (1-" .. #t.items .. ")" end
  local p = M.load_plan(book, n)
  local r, info = M.write(book, n, p, t.id, chosen.text, { origin = opts.author and "author-pick" or "auto-pick" })
  if not r then return nil, info end
  local rejected = {}
  for i, it in ipairs(t.items) do if i ~= c then rejected[#rejected + 1] = it.text end end
  append_jsonl(book.root .. "/" .. M.PREFS, { kind = opts.author and "pick" or "auto", chapter = n, id = t.id,
    chosen = chosen.text, rejected = rejected, rank = c })
  os.remove(cand_path(book))
  return r, info
end

-- ---- the loop ---------------------------------------------------------------------------------------
-- Run up to `steps` steps, each a fresh bounded call. Stops early when the
-- plan is done or empty, on a truncated answer (max_tokens: never written), or
-- on an error. Error-level bans are backtracked during generation; anything
-- still failing an error rule afterwards is repaired span by span (only the
-- failing paragraphs, with the rule and its guide section).
function M.run(book, n, steps, opts)
  opts = opts or {}
  steps = math.max(1, math.min(tonumber(steps) or 1, 200))
  local log = {}
  for step = 1, steps do
    local p = M.load_plan(book, n)
    if not p then return nil, "no plan for chapter " .. n end
    local task = M.next_task(p)
    if task.kind == "done" then log[#log + 1] = "Chapter plan complete."; break end
    if task.kind == "empty" then return nil, "the plan has no beats yet (plan set beats=...)" end
    local packet = M.packet(book, n, p, task, opts)
    local mt = task.kind == "outline" and M.DEFAULTS.max_tokens_outline or M.DEFAULTS.max_tokens_write
    local call, rules, S, E = caller(book, p, opts, mt)
    if task.kind == "outline" then
      local okc, text, stop = pcall(call, packet)
      if not okc then log[#log + 1] = "step " .. step .. ": model call failed: " .. tostring(text); break end
      if stop == "max_tokens" then log[#log + 1] = "step " .. step .. ": the outline hit max_tokens and was NOT used."; break end
      local r, e = M.expand(book, n, p, task.beat.id, text)
      log[#log + 1] = "step " .. step .. ": " .. (r or ("outline failed: " .. tostring(e)))
      if not r then break end
    elseif (tonumber(opts.candidates) or 1) > 1 then
      local r, e = M.candidates(book, n, opts.candidates, opts)
      if not r then log[#log + 1] = "step " .. step .. ": " .. tostring(e); break end
      local w, info = M.pick(book, n, 1, {})
      if not w then log[#log + 1] = "step " .. step .. ": " .. tostring(info); break end
      log[#log + 1] = "step " .. step .. " (best of " .. opts.candidates .. "): " .. w:gsub("\n", "\n  ")
    else
      local okc, text, blog, stop = pcall(sd_decode.generate, call, packet, rules)
      if not okc then log[#log + 1] = "step " .. step .. ": model call failed: " .. tostring(text); break end
      if stop == "max_tokens" then
        log[#log + 1] = "step " .. step .. ": the answer hit max_tokens and was NOT written (it would be cut off). "
          .. "Split the beat's lines, or use unit: line, and run again."
        break
      end
      local r, info = M.write(book, n, p, task.id, text)
      if not r then log[#log + 1] = "step " .. step .. ": " .. tostring(info); break end
      for _, b in ipairs(blog or {}) do r = r .. "\n" .. b end
      if info and info.result and info.result.errors > 0 and not opts.no_retry and E then
        local fixed, rlog = sd_decode.repair(call, info.prose,
          ss.check(book, info.prose, { set = p.meta.style, pov = p.meta.pov }),
          function(fs) return ss.guide_for(S, E, fs) end)
        if #rlog > 0 then
          local r2 = M.redo(book, n, M.load_plan(book, n), fixed)
          if r2 then r = r .. "\n" .. table.concat(rlog, "\n") .. "\n  " .. r2:gsub("\n", "\n  ") end
        end
      end
      log[#log + 1] = "step " .. step .. ": " .. r:gsub("\n", "\n  ")
    end
  end
  return table.concat(log, "\n")
end

-- ---- rendering a plan -------------------------------------------------------------------------------
function M.show(book, n, p)
  local pr = M.progress(p)
  local target = M.target_of(book, n, p)
  local out = { string.format("Chapter %d%s — plan %s", n, p.meta.title and (": " .. p.meta.title) or "",
    M.plan_path(book, n):sub(#book.root + 2)),
    string.format("Target %s (%d words on disk)   beats %d/%d   paragraphs %d/%d   unit %s%s", target,
      chapter_words(book, target), pr.beats_done, pr.beats, pr.lines_done, pr.lines, M.unit(p),
      p.meta.style and ("   style " .. p.meta.style) or "") }
  if p.card then out[#out + 1] = "Card: " .. p.card end
  if p.meta.pov then out[#out + 1] = "POV: " .. p.meta.pov end
  out[#out + 1] = ""
  local nt = M.next_task(p)
  local cur = {}
  for _, l in ipairs(nt.lines or {}) do cur[l] = true end
  for _, b in ipairs(p.beats) do
    local g = b.done and "✓" or (#b.lines == 0 and "○" or "◐")
    out[#out + 1] = string.format("%s %s. %s%s", g, b.id, b.text, (nt.kind == "outline" and nt.beat == b) and "   ← outline next" or "")
    for _, l in ipairs(b.lines) do
      out[#out + 1] = string.format("    %s %s %s%s", l.done and "✓" or "○", l.id, l.text,
        (nt.kind == "write" and cur[l] and l == nt.line) and "   ← write next" or "")
    end
  end
  if #p.beats == 0 then out[#out + 1] = "(no beats yet: plan set n=" .. n .. " beats=\"...\")" end
  return table.concat(out, "\n")
end

return M
