-- dispatch.lua -- OPTIONAL auto-routing. A cheap, no-LLM heuristic that decides
-- whether an incoming request is "different enough" from what the current agent
-- does to be worth handing to a fresh specialist -- and, when so, delegates it:
-- spawn a sub-agent granted the matched skills, run the request there, and
-- return its answer as this turn's result. Off by default; toggle with
-- `/dispatch on` or BOGGART_AUTO_DISPATCH=1.
--
-- "Different enough" requires BOTH signals to agree (fewer spurious hand-offs):
--   1. route mismatch -- the best-matching skill (FTS5/bm25, via skillrouter) is
--      one the current agent does NOT hold, so the work belongs to a specialist;
--   2. topic shift    -- the request is mostly NEW vocabulary versus the recent
--      conversation (lexical novelty), i.e. not a continuation of what's going on.
-- Plus a triviality guard, so "yes", "thanks", "continue" never route.
local M = {}

M.MIN_WORDS = 4    -- shorter requests never delegate
M.NOVELTY   = 0.6  -- >= this fraction of new content words counts as a topic shift
M.depth     = 0    -- recursion guard: a delegated child never re-dispatches

local function truthy(v)
  return v == true or v == "1" or v == "true" or v == "on" or v == "yes"
end
M.enabled_flag = truthy(os.getenv("BOGGART_AUTO_DISPATCH"))
function M.enabled() return M.enabled_flag == true end
function M.set(on) M.enabled_flag = on and true or false; return M.enabled_flag end

-- Content-word set: lowercased, stopwords dropped, length >= 2.
local STOP = {}
for w in ([[the a an and or of to in on at for with is are was were be been it its
this that these those i you we they he she my our your me us do does did can could
would should will please help need want make get set use using how what why when
which who from into out over under again more most some any all not no yes ok]])
  :gmatch("%S+") do STOP[w] = true end

local function words_of(text)
  local set, n = {}, 0
  for w in tostring(text or ""):lower():gmatch("[%a][%w_]+") do
    if #w >= 2 and not STOP[w] and not set[w] then set[w] = true; n = n + 1 end
  end
  return set, n
end

-- novelty(request, context) -> fraction of the request's content words that do
-- NOT appear in the context (0 = all seen before, 1 = all new).
function M.novelty(request, context)
  local req, n = words_of(request)
  if n == 0 then return 0 end
  local ctx = words_of(context)
  local novel = 0
  for w in pairs(req) do if not ctx[w] then novel = novel + 1 end end
  return novel / n
end

-- Recent conversation text (last few turns) for the topic-shift signal.
function M.context_text(sess, skip_last)
  local msgs = sess and sess.messages or {}
  local upto = #msgs - (skip_last and 1 or 0)
  local parts = {}
  for i = math.max(1, upto - 5), upto do
    local m = msgs[i]
    if m then
      if type(m.content) == "string" then
        parts[#parts + 1] = m.content
      elseif type(m.content) == "table" then
        for _, b in ipairs(m.content) do
          if b.type == "text" and b.text then parts[#parts + 1] = b.text end
        end
      end
    end
  end
  return table.concat(parts, " ")
end

-- assess(request, current_skills, sess) -> decision table:
--   { delegate, skills, match, novelty, reason }
function M.assess(request, current_skills, sess)
  request = tostring(request or "")
  local nwords = 0
  for _ in request:gmatch("%S+") do nwords = nwords + 1 end
  if nwords < M.MIN_WORDS then
    return { delegate = false, skills = {}, novelty = 0,
             reason = "trivial (" .. nwords .. " words)" }
  end

  -- signal 1: route mismatch (best-matching skill not held by this agent)
  local held = {}
  for _, s in ipairs(current_skills or {}) do held[s] = true end
  local matches
  if bog.skillrouter and bog.db then
    local ok, res = pcall(bog.skillrouter.route, request, 5)
    if ok then matches = res end
  end
  local best = matches and matches[1]
  local route_mismatch = best ~= nil and not held[best.name]

  -- signal 2: topic shift (mostly new vocabulary vs the recent conversation)
  local nov = M.novelty(request, M.context_text(sess, true))
  local topic_shift = nov >= M.NOVELTY

  local delegate = route_mismatch and topic_shift
  local reason
  if delegate then
    reason = string.format("-> %s (novelty %.2f)", best.name, nov)
  elseif not route_mismatch then
    reason = best and ("best skill '" .. best.name .. "' already held") or "no skill matched"
  else
    reason = string.format("same topic (novelty %.2f < %.2f)", nov, M.NOVELTY)
  end
  return { delegate = delegate, skills = best and { best.name } or {},
           match = best and best.name or nil, novelty = nov, reason = reason }
end

-- delegate(request, skills, on_text) -> text, ok | nil, err
-- Spawn a specialist child for the request and await its result over the swarm
-- bus (the same protocol thread._run / the await tool use). Runs under the
-- scheduler, so the recv-wait yields cooperatively. `depth` is held > 0 for the
-- duration, so the child (and anyone else) will not re-dispatch mid-flight.
function M.delegate(request, skills, on_text)
  if not (bog.thread and bog.sched and swarm) then return nil, "swarm unavailable" end
  local self = bog.sched.current()
  if not self then return nil, "no current agent" end

  M.depth = M.depth + 1
  local ok, child = pcall(bog.thread.spawn,
    { task = request, skills = skills, parent_id = self })
  if not ok or not child then
    M.depth = M.depth - 1
    return nil, "spawn failed: " .. tostring(child)
  end

  local result, guard = nil, 0
  while not result do
    while true do
      local payload, jid = swarm.recv(self)
      if not payload then break end
      local dok, m = pcall(bog.json.decode, payload)
      if dok and type(m) == "table" and m.kind == "result" and m.from == child then
        result = m
      end
      if jid then swarm.mark_processed(jid) end
    end
    if not result then
      guard = guard + 1
      if guard > 1000000 then break end
      coroutine.yield("recv")
    end
  end
  M.depth = M.depth - 1

  if not result then return nil, "child produced no result" end
  return result.text or "", result.ok
end

return M
