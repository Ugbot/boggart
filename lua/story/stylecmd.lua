-- story/stylecmd.lua -- the `style` noun of the `story` tool (docs/story-style.md):
--
--   style get       voice card (+ POV line, exemplars) for a set; bits= pulls guide sections
--   style check     n= | path= | text=  [set= pov=]   the checker (only errors fail)
--   style render    the guide as markdown
--   style sets      the sets a book can use, and the chain for set=
--   style exemplars list | add (text= or path= lines=a-b; pov= mode= set= golden=) | harvest (n= chapter)
--   style baseline  build (from approved chapters + exemplars, or paths=) | show
--   style drift     n= | path= | text=   against the book's baseline
--   style slop      scan: n-grams the drafts over-use vs the author -> ban proposals
--   style ban       phrase= [level=]  (the author: now; the model: a proposal)
--   style decode    what a model/route would be sent (sampler, bans)
--   style prefs     what has been logged (picks, edits)
--   style dataset   training data from the author's prose and picks (mlx-lm / unsloth format)
--   style finetune  a local LoRA on that data: the command, or run=true to start it
local sb = require("story.book")
local si = require("story.index")
local ss = require("story.style")
local bl = require("story.baseline")
local slop = require("story.slop")
local json = require("json")
local M = {}

local function E(m) return "Error: " .. m end

local function open(a)
  local b, e = sb.resolve(a.book)
  if not b then return nil, nil, nil, e end
  local S = ss.load(b)
  local E2, err = ss.resolve(S, { set = a.set, pov = a.pov })
  if not E2 then return nil, nil, nil, err end
  return b, S, E2
end

-- the text an action is about: text=, path=, or chapter n=
local function subject(b, a)
  if a.text then return a.text, "text" end
  local path = a.path
  if not path and a.n then
    si.fresh(b)
    for _, c in ipairs(si.chapters(b)) do if c.n == tonumber(a.n) then path = c.path end end
    if not path then return nil, "no chapter " .. tostring(a.n) end
  end
  if not path then return nil, "needs n=, path= or text=" end
  local full = path:sub(1, 1) == "/" and path or (b.root .. "/" .. path)
  local t = sb.read(full)
  if not t then return nil, "cannot read " .. full end
  return sb.drop_sections(t, b.m.drop_sections), path
end

-- ---- get / check / render / sets ---------------------------------------------------------------
local function get(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local names = {}
  for n in tostring(a.bits or ""):gmatch("[%w_]+") do names[#names + 1] = n end
  if #names > 0 then
    local t = ss.pull(S, names)
    return t ~= "" and t or E("the guide has no section named " .. a.bits)
  end
  local out = { "Set: " .. St.name .. (#St.chain > 0 and ("  (" .. table.concat(St.chain, " <- ") .. ")") or ""),
    "", ss.voice_block(St, a.pov) }
  local ex = ss.pick(St, { pov = a.pov, k = tonumber(a.limit) or 3 })
  if #ex > 0 then out[#out + 1] = "\n" .. ss.exemplar_block(ex) end
  if #St.voice == 0 and #St.exemplars == 0 then
    out[#out + 1] = "\n(no voice card or exemplars yet: add voice = {...} to .boggart/style.lua, "
      .. "and passages with `story style exemplars add`)"
  end
  return table.concat(out, "\n")
end

local function check(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local text, label = subject(b, a)
  if not text then return E(label) end
  local r, err = ss.check(b, text, { set = a.set, pov = a.pov, label = label })
  if not r then return E(err) end
  return r.report
end

local function render(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local text = ss.render(S, b.m.title or b.name)
  if a.path then
    local full = a.path:sub(1, 1) == "/" and a.path or (b.root .. "/" .. a.path)
    local f, fe = io.open(full, "wb")
    if not f then return E(tostring(fe)) end
    f:write(text); f:close()
    return "Wrote " .. full
  end
  return text
end

local function sets(a)
  local b, e = sb.resolve(a.book)
  if not b then return E(e) end
  local S = ss.load(b)
  local out = { "default set: " .. tostring(S.default_set or "(none -- the book's base style)") }
  local pv = {}
  for pov, set in pairs(S.pov_sets) do pv[#pv + 1] = pov .. " -> " .. set end
  table.sort(pv)
  if #pv > 0 then out[#out + 1] = "per POV: " .. table.concat(pv, ", ") end
  local own = {}
  for name in pairs(S.sets) do own[#own + 1] = name end
  table.sort(own)
  out[#out + 1] = "the book's sets: " .. (#own > 0 and table.concat(own, ", ") or "none")
  for _, dir in ipairs{ b.root .. "/.boggart/style/sets", (os.getenv("HOME") or "") .. "/.boggart/style/sets" } do
    local fs = {}
    for _, f in ipairs(sys.glob(dir .. "/*.lua") or {}) do fs[#fs + 1] = f:match("([^/]+)%.lua$") end
    if #fs > 0 then out[#out + 1] = dir .. ": " .. table.concat(fs, ", ") end
  end
  out[#out + 1] = "built-in library: " .. table.concat(ss.builtin_names(), ", ")
  if a.set then
    local chain, ce = ss.chain(S, a.set)
    if not chain then return E(ce) end
    local E2 = ss.resolve(S, { set = a.set })
    local parts = {}
    for _, c in ipairs(chain) do parts[#parts + 1] = c.name .. " (" .. c.from .. ")" end
    out[#out + 1] = "\n" .. a.set .. ": " .. table.concat(parts, " -> ")
    out[#out + 1] = "narration: " .. tostring(E2.narration)
    out[#out + 1] = string.format("%d voice lines, %d exemplars, %d rules, allow: %s", #E2.voice, #ss.pick(E2, { k = 99 }),
      #E2.rules, #E2.allow > 0 and table.concat(E2.allow, ", ") or "none")
  end
  return table.concat(out, "\n")
end

-- ---- exemplars ----------------------------------------------------------------------------------------
local function ex_dir(b) return b.root .. "/.boggart/style/exemplars" end

local function write_exemplar(b, id, meta, text)
  sys.mkdir_p(ex_dir(b))
  local path = ex_dir(b) .. "/" .. id .. ".md"
  local head = {}
  for _, k in ipairs{ "pov", "mode", "set", "golden", "source" } do
    if meta[k] ~= nil and meta[k] ~= "" then head[#head + 1] = k .. ": " .. tostring(meta[k]) end
  end
  local f = assert(io.open(path, "wb"))
  f:write("---\n", table.concat(head, "\n"), "\n---\n", text, "\n")
  f:close()
  return path
end

-- Passages of about 300-600 words, on paragraph boundaries.
function M.passages(text, lo, hi)
  lo, hi = lo or 300, hi or 600
  local paras, out, cur, n = {}, {}, {}, 0
  for para in (text .. "\n\n"):gmatch("(.-)\n%s*\n") do
    if para:match("%S") and not para:match("^%s*#") and not para:match("^%s*>") and not para:match("^%-%-%-") then
      paras[#paras + 1] = para:gsub("^%s+", ""):gsub("%s+$", "")
    end
  end
  for _, p in ipairs(paras) do
    local w = sb.word_count(p)
    cur[#cur + 1] = p
    n = n + w
    if n >= lo then
      out[#out + 1] = table.concat(cur, "\n\n")
      cur, n = {}, 0
    end
  end
  if n >= lo * 0.6 then out[#out + 1] = table.concat(cur, "\n\n") end
  -- trim any passage beyond hi at a paragraph boundary
  for i, s in ipairs(out) do
    if sb.word_count(s) > hi * 1.3 then
      local keep, c = {}, 0
      for para in (s .. "\n\n"):gmatch("(.-)\n\n") do
        if c >= lo then break end
        keep[#keep + 1] = para; c = c + sb.word_count(para)
      end
      out[i] = table.concat(keep, "\n\n")
    end
  end
  return out
end

local function exemplars(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local act = a.do_ or a.op or a.what or "list"
  if act == "add" then
    local text = a.text
    if not text and a.path then
      local t = sb.read(a.path:sub(1, 1) == "/" and a.path or (b.root .. "/" .. a.path))
      if not t then return E("cannot read " .. a.path) end
      local lo, hi = tostring(a.lines or ""):match("^(%d+)%-(%d+)$")
      if lo then
        local ls, i = {}, 0
        for l in (t .. "\n"):gmatch("(.-)\n") do i = i + 1; if i >= tonumber(lo) and i <= tonumber(hi) then ls[#ls + 1] = l end end
        t = table.concat(ls, "\n")
      end
      text = t
    end
    if not text or not text:match("%S") then return E("exemplars add needs text= or path= [lines=a-b]") end
    if not a._author then return E("only the author adds exemplars (they define the voice)") end
    local id = a.id or ((a.pov or "any") .. "-" .. ss.mode_of(text) .. "-" .. tostring(#St.exemplars + 1))
    local p = write_exemplar(b, id, { pov = a.pov, mode = a.mode or ss.mode_of(text), set = a.set,
      golden = a.golden == true and "true" or nil, source = a.path }, text)
    return "Exemplar written: " .. p:sub(#b.root + 2) .. " (" .. sb.word_count(text) .. " words)"
  elseif act == "harvest" then
    if not a._author then return E("only the author harvests exemplars") end
    local text, label = subject(b, a)
    if not text then return E(label) end
    local ps = M.passages(text)
    local out = {}
    for i, t in ipairs(ps) do
      if i > (tonumber(a.limit) or 4) then break end
      local id = string.format("%s-ch%s-%d", a.pov or "any", tostring(a.n or "x"), i)
      local p = write_exemplar(b, id, { pov = a.pov, mode = ss.mode_of(t), set = a.set, source = label }, t)
      out[#out + 1] = p:sub(#b.root + 2) .. " (" .. sb.word_count(t) .. " words, " .. ss.mode_of(t) .. ")"
    end
    if #out == 0 then return E("no passage of 300+ words found") end
    return "Harvested " .. #out .. " exemplar(s) -- review them, delete the weak ones, mark the best golden:\n  "
      .. table.concat(out, "\n  ")
  end
  local list = ss.pick(St, { pov = a.pov, k = 999 })
  if #list == 0 then return "No exemplars for set " .. St.name .. (a.pov and (", pov " .. a.pov) or "") .. "." end
  local out = {}
  for _, x in ipairs(list) do
    out[#out + 1] = string.format("%-28s %-8s %-10s %s%4d words  %s", x.id or "?", x.pov or "any", x.mode or "?",
      x.golden and "golden " or "       ", sb.word_count(x.text), (x.text:gsub("%s+", " ")):sub(1, 60))
  end
  return table.concat(out, "\n")
end

-- ---- baseline + drift --------------------------------------------------------------------------------
-- The author's approved prose: done chapters (the manifest's `done` variants)
-- and the exemplars, or explicit paths=.
function M.author_texts(b, St, a)
  local texts, sources = {}, {}
  if a and a.paths then
    for p in tostring(a.paths):gmatch("[^,]+") do
      local t = sb.read(p:sub(1, 1) == "/" and p or (b.root .. "/" .. p))
      if t then texts[#texts + 1] = sb.drop_sections(t, b.m.drop_sections); sources[#sources + 1] = p end
    end
    return texts, sources
  end
  si.fresh(b)
  for _, c in ipairs(si.chapters(b)) do
    if c.done == 1 then
      local t = sb.read(b.root .. "/" .. c.path)
      if t then texts[#texts + 1] = sb.drop_sections(t, b.m.drop_sections); sources[#sources + 1] = c.path end
    end
  end
  for _, x in ipairs(St and St.exemplars or {}) do texts[#texts + 1] = x.text; sources[#sources + 1] = "exemplar:" .. (x.id or "?") end
  return texts, sources
end

local function baseline(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local act = a.op or a.what or (a.paths and "build") or "show"
  if act == "build" then
    local texts, sources = M.author_texts(b, St, a)
    local B, be = bl.build(texts, sources)
    if not B then return E(be) end
    local p = bl.save(b.root, B)
    return string.format("Baseline built from %d text(s) -> %s", B.n, p:sub(#b.root + 2))
  end
  local B = bl.load(b.root)
  if not B then return "No baseline yet: story style baseline op=build (uses done chapters and exemplars)" end
  local out = { string.format("Baseline: %d texts (%s)", B.n, table.concat(B.sources or {}, ", "):sub(1, 200)) }
  for _, k in ipairs(bl.MARKERS) do
    local m = B.markers[k]
    if m then out[#out + 1] = string.format("  %-38s %.3g  (spread %.3g)", bl.LABEL[k], m.mean, m.sd) end
  end
  return table.concat(out, "\n")
end

local function drift(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local B = bl.load(b.root)
  if not B then return E("no baseline: story style baseline op=build") end
  local text, label = subject(b, a)
  if not text then return E(label) end
  local d, de = bl.drift(text, B)
  if not d then return E(de) end
  return bl.report(d, label)
end

-- ---- slop -----------------------------------------------------------------------------------------------
local function drafts_of(b, a)
  local out = {}
  local f = io.open(b.root .. "/" .. require("story.draft").GENERATED, "rb")
  if f then
    for line in f:lines() do
      local ok, r = pcall(json.decode, line)
      if ok and r.text and (not a.n or tonumber(r.chapter) == tonumber(a.n)) then out[#out + 1] = r.text end
    end
    f:close()
  end
  return out
end

local function slop_scan(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local drafts = drafts_of(b, a)
  if a.text then drafts[#drafts + 1] = a.text end
  if #drafts == 0 then return E("no generated drafts logged yet (" .. require("story.draft").GENERATED .. ")") end
  local base = M.author_texts(b, St, a)
  if #base == 0 then return E("no author prose to compare against (done chapters or exemplars)") end
  local found = slop.overrep(drafts, base, { ratio = tonumber(a.ratio) or 5, min_count = tonumber(a.min_count) or 3 })
  if #found == 0 then return "Nothing the drafts over-use against your prose (ratio >= " .. (a.ratio or 5) .. ")." end
  local sm = require("story.model")
  sm.ensure_schema()
  local out = { "Over-used by the drafts, compared with your prose:" }
  for _, g in ipairs(found) do
    local line = string.format("  '%s'  %d times, %.1f per 10k words vs %.1f in yours (x%.0f)", g.gram, g.count, g.draft, g.base, g.ratio)
    if a.propose ~= false then
      local id = sm.propose(b.name, { kind = "style", action = "ban", grp = "slop",
        payload = { root = b.root, phrase = g.gram, level = "warning", note = string.format("x%.0f vs author", g.ratio) },
        summary = string.format("ban '%s' (drafts use it x%.0f more than you)", g.gram, g.ratio), origin = "slop-scan" })
      if id then line = line .. "   -> " .. id end
    end
    out[#out + 1] = line
  end
  if a.propose ~= false then
    sm.export(b.name, b.root)
    out[#out + 1] = "Accept what you agree with: /story proposal accept group=slop  (or ids=Q..)"
  end
  return table.concat(out, "\n")
end

local function ban(a)
  local b, e = sb.resolve(a.book)
  if not b then return E(e) end
  if not a.phrase then return E("ban needs phrase=") end
  local level = a.level or "warning"
  if not require("story.lint").LEVELS[level] then return E("level must be suggestion|warning|error") end
  if a._author then
    local r, be = slop.add_ban(b.root, a.phrase, level, a.note)
    return r and ("Banned '" .. r .. "' (" .. level .. ") in .boggart/style/slop.json") or E(be)
  end
  local sm = require("story.model")
  sm.ensure_schema()
  local id, pe = sm.propose(b.name, { kind = "style", action = "ban", grp = "slop",
    payload = { root = b.root, phrase = a.phrase, level = level, note = a.note }, summary = "ban '" .. a.phrase .. "'" })
  if not id then return E(pe) end
  sm.export(b.name, b.root)
  return "Proposed " .. id .. ": ban '" .. a.phrase .. "' (the author accepts: /story proposal accept ids=" .. id .. ")"
end

local function decode_show(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local dec = require("story.decode")
  local okr, rt = pcall(function() return a.model and require("route").resolve(a.model) or require("route").current() end)
  rt = okr and rt or nil
  local rules = ss.rules(St, b)
  local s = dec.sampler(St, rt, rules)
  local out = { string.format("route: %s %s (%s)", rt and rt.model or "?", rt and rt.url or "?", rt and rt.wire or "?"),
    "local sampler controls: " .. (dec.is_local(rt) and "yes" or "no (API: backtracking + span repair only)") }
  out[#out + 1] = "sampler: " .. (s and json.encode(s) or "none")
  local hw = dec.hard_words(rules)
  out[#out + 1] = "error-level bans backtracked on every backend: " .. (#hw > 0 and table.concat(hw, ", ") or "none")
  return table.concat(out, "\n")
end

local function prefs(a)
  local b, e = sb.resolve(a.book)
  if not b then return E(e) end
  local f = io.open(b.root .. "/" .. require("story.draft").PREFS, "rb")
  if not f then return "No preferences logged yet (picks from `draft candidates`, and your `draft redo`s)." end
  local counts, n = {}, 0
  for line in f:lines() do
    local ok, r = pcall(json.decode, line)
    if ok then counts[r.kind or "?"] = (counts[r.kind or "?"] or 0) + 1; n = n + 1 end
  end
  f:close()
  local parts = {}
  for k, v in pairs(counts) do parts[#parts + 1] = k .. " " .. v end
  table.sort(parts)
  return string.format("%d preference records: %s", n, table.concat(parts, ", "))
end

-- ---- S6: training data + a local LoRA -------------------------------------------------------------------------
local function train_dir(b) return b.root .. "/.boggart/style/train" end

-- Continuation pairs from the author's own prose (previous ~300 words -> the
-- next paragraph), in the chat form mlx-lm and unsloth both read; plus
-- preference pairs from picks and the author's edits.
local function dataset(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local texts, sources = M.author_texts(b, St, a)
  local system = ss.voice_block(St, nil)
  local rows, words = {}, 0
  for _, t in ipairs(texts) do
    local paras = {}
    for para in (t .. "\n\n"):gmatch("(.-)\n%s*\n") do
      if para:match("%S") and not para:match("^%s*#") then paras[#paras + 1] = para:gsub("^%s+", ""):gsub("%s+$", "") end
    end
    for i = 2, #paras do
      local ctx, c = {}, 0
      for j = i - 1, 1, -1 do
        table.insert(ctx, 1, paras[j]); c = c + sb.word_count(paras[j])
        if c >= 300 then break end
      end
      rows[#rows + 1] = { messages = {
        { role = "system", content = system },
        { role = "user", content = "Continue the manuscript:\n\n" .. table.concat(ctx, "\n\n") },
        { role = "assistant", content = paras[i] } } }
      words = words + sb.word_count(paras[i]) + c
    end
  end
  if #rows < 10 then return E("only " .. #rows .. " examples: not enough of the author's prose (done chapters, exemplars, or paths=)") end
  local dir = train_dir(b)
  sys.mkdir_p(dir)
  -- deterministic split: every 10th example is validation
  local tr, va = {}, {}
  for i, r in ipairs(rows) do
    if i % 10 == 0 then va[#va + 1] = json.encode(r) else tr[#tr + 1] = json.encode(r) end
  end
  local function put(name, lines)
    local f = assert(io.open(dir .. "/" .. name, "wb")); f:write(table.concat(lines, "\n"), "\n"); f:close()
  end
  put("train.jsonl", tr)
  put("valid.jsonl", va)
  -- preferences (DPO-style pairs) from picks and edits
  local prefs_out = {}
  local f = io.open(b.root .. "/" .. require("story.draft").PREFS, "rb")
  if f then
    for line in f:lines() do
      local ok, r = pcall(json.decode, line)
      if ok and r.kind == "edit" then prefs_out[#prefs_out + 1] = json.encode({ prompt = "Revise in the author's voice.", chosen = r.after, rejected = r.before })
      elseif ok and r.kind == "pick" then
        for _, rej in ipairs(r.rejected or {}) do
          prefs_out[#prefs_out + 1] = json.encode({ prompt = "Continue the manuscript.", chosen = r.chosen, rejected = rej })
        end
      end
    end
    f:close()
  end
  if #prefs_out > 0 then put("preferences.jsonl", prefs_out) end
  local tokens = math.floor(words * 1.33)
  return string.format("Wrote %s/{train,valid}.jsonl: %d continuation examples (~%d tokens) from %d text(s)%s.\n%s",
    dir:sub(#b.root + 2), #rows, tokens, #texts,
    #prefs_out > 0 and (", and " .. #prefs_out .. " preference pairs (preferences.jsonl)") or "",
    tokens < 1000000 and "Note: reports of a LoRA that really sounds like its author used ~1M+ tokens of the author's prose; "
      .. "with less, expect a light touch (the preference pairs and the checker do more)." or "Enough text for a voice LoRA.")
end

local function has_cmd(c)
  local p = io.popen("command -v " .. c .. " 2>/dev/null")
  local r = p and p:read("a") or ""
  if p then p:close() end
  return r:match("%S") ~= nil
end

local function finetune(a)
  local b, S, St, e = open(a)
  if not b then return E(e) end
  local dir = train_dir(b)
  if sys.stat(dir .. "/train.jsonl") ~= "file" then return E("no training data: story style dataset first") end
  local base = a.base or a.model_name or "mlx-community/Qwen3-8B-4bit"
  local adapter = dir .. "/adapter"
  local cmd
  if has_cmd("mlx_lm.lora") then
    cmd = string.format("mlx_lm.lora --model %q --train --data %q --adapter-path %q --iters %d --batch-size 2 --num-layers 16 --learning-rate 1e-5",
      base, dir, adapter, tonumber(a.iters) or 600)
  elseif has_cmd("python3") then
    cmd = string.format("python3 -m mlx_lm lora --model %q --train --data %q --adapter-path %q --iters %d",
      base, dir, adapter, tonumber(a.iters) or 600)
  end
  local out = {
    "Local LoRA for this book's voice (API fine-tuning is not an option: OpenAI is winding it down, Anthropic offers none).",
    "data:    " .. dir:sub(#b.root + 2) .. "/{train,valid}.jsonl",
    "base:    " .. base .. "  (base= to change; any mlx-lm or HF model)",
    "adapter: " .. adapter:sub(#b.root + 2),
    "command: " .. (cmd or "(install mlx-lm: pip install mlx-lm -- or train the same files with unsloth)"),
    "Serve it with llama.cpp or mlx_lm.server and point a boggart preset at it; `story style decode model=<preset>` shows what it gets.",
  }
  if a.run == true then
    if not a._author then return E("only the author starts training") end
    if not cmd then return E("no trainer found (mlx_lm.lora); see the command above") end
    local log = dir .. "/lora.log"
    os.execute(string.format("nohup sh -c %q > %q 2>&1 &", cmd, log))
    out[#out + 1] = "Started in the background; log: " .. log:sub(#b.root + 2)
  end
  return table.concat(out, "\n")
end

M.ACTIONS = { get = get, check = check, render = render, sets = sets, exemplars = exemplars, baseline = baseline,
  drift = drift, slop = slop_scan, ban = ban, decode = decode_show, prefs = prefs, dataset = dataset, finetune = finetune }

-- the story model applies an accepted ban proposal
local sm = require("story.model")
sm.APPLY["style.ban"] = function(_, p) return slop.add_ban(p.root, p.phrase, p.level, p.note) end

return M
