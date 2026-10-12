-- story/decode.lua -- keeping banned phrases out of generated prose, by backend.
--
-- Two tiers (docs/story-style.md, "decode"):
--   * LOCAL models (llama.cpp behind the OpenAI wire): the book's sampler
--     settings (min_p, DRY, XTC) and a logit_bias that forbids single-word
--     error-level bans go into the request itself (api.lua forwards
--     body.sampler on that wire only);
--   * EVERY backend: backtracking at sentence grain -- when an error-level ban
--     appears, cut back to the start of that sentence and ask for a
--     continuation from there that avoids it (the Antislop idea, at the grain
--     an API allows: Anthropic exposes no logit controls, reasoning models
--     reject them); then span repair -- any paragraph still breaking an
--     error-level rule is regenerated alone, with that rule's message and its
--     section of the guide, changing as little as possible.
local lint = require("story.lint")
local M = {}

-- Is this route a local llama.cpp-style server we may send sampler extras to?
function M.is_local(rt)
  if not rt then return false end
  local u = tostring(rt.url or "")
  return (rt.wire == "openai" or rt.wire == nil) and (u:find("localhost", 1, true) or u:find("127.0.0.1", 1, true)
    or u:find("0.0.0.0", 1, true)) ~= nil
end

M.SAMPLER_KEYS = { "min_p", "top_n_sigma", "typical_p", "dry_multiplier", "dry_base", "dry_allowed_length",
  "dry_penalty_last_n", "xtc_probability", "xtc_threshold", "repeat_penalty", "presence_penalty", "frequency_penalty",
  "temperature" }

-- The error-level single-word bans (logit_bias can only forbid tokens/strings).
function M.hard_words(rules)
  local out = {}
  for _, r in ipairs(rules or {}) do
    if r.type == "existence" and r.level == "error" then
      for _, t in ipairs(r.tokens or {}) do
        if t:sub(1, 1) ~= "~" and not t:find("%s") and t:find("%a") then out[#out + 1] = t end
      end
    end
  end
  return out
end

-- -> the `sampler` table for a request, or nil (not local / nothing set)
function M.sampler(E, rt, rules)
  if not (E and (M.is_local(rt) or (E.decode and E.decode.force))) then return nil end
  local s, any = {}, false
  for _, k in ipairs(M.SAMPLER_KEYS) do
    if E.decode[k] ~= nil then s[k] = E.decode[k]; any = true end
  end
  if E.decode.ban_words ~= false then
    local bias = {}
    for _, w in ipairs(M.hard_words(rules)) do
      bias[#bias + 1] = { w, false }
      bias[#bias + 1] = { " " .. w, false }
      local cap = w:sub(1, 1):upper() .. w:sub(2)
      bias[#bias + 1] = { " " .. cap, false }
    end
    if #bias > 0 then s.logit_bias = bias; any = true end
  end
  return any and s or nil
end

-- The first error-level ban in text: -> { rule, token, pos } or nil
function M.first_ban(text, rules)
  local low = text:lower()
  local best
  for _, r in ipairs(rules or {}) do
    if r.type == "existence" and r.level == "error" then
      for _, t in ipairs(r.tokens or {}) do
        local pat = lint.token_pattern(t, true)
        local a = low:find(pat)
        if a and (not best or a < best.pos) then best = { rule = r, token = t, pos = a } end
      end
    end
  end
  return best
end

-- Where the sentence holding byte `pos` starts.
local function sentence_start(text, pos)
  local i = pos
  while i > 1 do
    local c = text:sub(i - 1, i - 1)
    if c == "." or c == "!" or c == "?" or c == "\n" then break end
    i = i - 1
  end
  while text:sub(i, i):match("%s") do i = i + 1 end
  return i
end

-- Generate with backtracking. `call(user) -> text, stop`. -> text, log
function M.generate(call, user, rules, opts)
  opts = opts or {}
  local log = {}
  local text, stop = call(user)
  if stop == "max_tokens" then return text, log, stop end
  for attempt = 1, opts.max_backtracks or 3 do
    local hit = M.first_ban(text or "", rules)
    if not hit then break end
    local cut = sentence_start(text, hit.pos)
    local prefix = text:sub(1, cut - 1):gsub("%s+$", "")
    log[#log + 1] = string.format("backtrack %d: '%s' (%s) -- cut at byte %d", attempt, hit.token, hit.rule.id, cut)
    local avoid = "Do not use the words or phrases: " .. hit.token .. "."
    local more
    if #prefix < 40 then
      more, stop = call(user .. "\n\n" .. avoid)
      text = more
    else
      more, stop = call(user .. "\n\n## Continue from here\nThe passage so far is below. Continue it EXACTLY from its last word: "
        .. "do not repeat it, do not restart. " .. avoid .. "\n\n" .. prefix)
      more = tostring(more or ""):gsub("^%s+", "")
      text = prefix .. (prefix:match("\n$") and "" or " ") .. more
    end
    if stop == "max_tokens" then break end
  end
  return text, log, stop
end

-- Regenerate only the paragraphs (lines) that break an error-level rule.
-- `call(user) -> text`. -> new text, log
function M.repair(call, text, result, guide_for, opts)
  opts = opts or {}
  local by_line = {}
  for _, f in ipairs(result.findings or {}) do
    if f.level == "error" and f.line and f.line > 0 then
      by_line[f.line] = by_line[f.line] or {}
      table.insert(by_line[f.line], f)
    end
  end
  local lines = {}
  for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  local log = {}
  for n, fs in pairs(by_line) do
    if lines[n] and lines[n]:match("%S") then
      local msgs = {}
      for _, f in ipairs(fs) do msgs[#msgs + 1] = f.id .. ": " .. f.message end
      local guide = guide_for and guide_for(fs) or ""
      local user = "Rewrite this paragraph to fix exactly these problems, changing as little as possible "
        .. "and keeping its events, voice and length:\n- " .. table.concat(msgs, "\n- ")
        .. (guide ~= "" and ("\n\nThe relevant part of the book's style guide:\n" .. guide) or "")
        .. (opts.context and ("\n\nContext (do not rewrite):\n" .. opts.context) or "")
        .. "\n\nParagraph:\n" .. lines[n] .. "\n\nAnswer with the rewritten paragraph only."
      local okc, fixed = pcall(call, user)
      if okc and fixed and fixed:match("%S") then
        fixed = fixed:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n+", " ")
        log[#log + 1] = string.format("repaired line %d (%s)", n, table.concat(msgs, "; "))
        lines[n] = fixed
      end
    end
  end
  return table.concat(lines, "\n"), log
end

return M
