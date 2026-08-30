-- wire.lua -- the per-wire request-body transforms (lua/api.lua). The exact
-- shape each wire sends is verified against the documented provider contracts,
-- offline, via the api._body_for_wire test hook. This is where the "400 on
-- Sonnet" class of bug is caught before it reaches a live endpoint.
local api = bog.api or require("api")

local passed, failed = 0, 0
local function ok(c, n) if c then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", n, "\n") end end
local function eq(a, b, n)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", n, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

local function base(extra)
  local b = { model = "claude-sonnet-5", max_tokens = 16000,
              messages = { { role = "user", content = "hi" } }, stream = true }
  for k, v in pairs(extra or {}) do b[k] = v end
  return b
end

-- ---- Anthropic: effort -> output_config.effort, NEVER reasoning_effort or
-- ---- thinking.budget_tokens (both 400 on the 4.7+/5 family) -----------------
do
  local out = api._body_for_wire("anthropic", base{ reasoning_effort = "medium" })
  ok(out.reasoning_effort == nil, "anthropic: reasoning_effort (OpenAI field) is dropped")
  ok(out.thinking == nil, "anthropic: never sends thinking{} (400 on Sonnet 5)")
  ok(type(out.output_config) == "table", "anthropic: effort becomes output_config")
  eq(out.output_config.effort, "medium", "anthropic: output_config.effort carries the level")
end
do
  local out = api._body_for_wire("anthropic", base{ reasoning_effort = "minimal" })
  eq(out.output_config.effort, "low", "anthropic: 'minimal' maps to Anthropic 'low' (no minimal there)")
end
do
  local out = api._body_for_wire("anthropic", base{ reasoning_effort = "xhigh" })
  eq(out.output_config.effort, "xhigh", "anthropic: xhigh passes through")
end
do
  local out = api._body_for_wire("anthropic", base{})   -- no effort
  ok(out.output_config == nil, "anthropic: no effort -> no output_config (defaults to server high)")
end
do
  -- effort only for a Claude model, not a local anthropic-wire server (ds4)
  local out = api._body_for_wire("anthropic",
    { model = "deepseek-v4-flash", max_tokens = 8000, reasoning_effort = "high",
      messages = { { role = "user", content = "hi" } } })
  ok(out.output_config == nil, "anthropic: output_config not sent to a non-Claude model")
  ok(out.reasoning_effort == nil, "anthropic: reasoning_effort still stripped for non-Claude too")
end

-- ---- Anthropic: signature-less thinking blocks are dropped, signed kept -----
do
  local msgs = {
    { role = "user", content = "write" },
    { role = "assistant", content = {
        { type = "thinking", thinking = "from gpt-oss, no sig" },   -- cross-model: drop
        { type = "text", text = "ok" },
    } },
    { role = "user", content = "more" },
    { role = "assistant", content = {
        { type = "thinking", thinking = "real anthropic", signature = "abc123" }, -- keep
        { type = "text", text = "done" },
    } },
  }
  local out = api._body_for_wire("anthropic", base{ messages = msgs })
  eq(#out.messages[2].content, 1, "anthropic: signature-less thinking block dropped")
  eq(out.messages[2].content[1].type, "text", "anthropic: the text block survives the drop")
  eq(#out.messages[4].content, 2, "anthropic: a SIGNED thinking block is kept")
  eq(out.messages[4].content[1].signature, "abc123", "anthropic: the kept thinking keeps its signature")
end
do
  -- an assistant turn whose ONLY block was a bad thinking block must not go empty
  local msgs = { { role = "user", content = "x" },
    { role = "assistant", content = { { type = "thinking", thinking = "orphan" } } } }
  local out = api._body_for_wire("anthropic", base{ messages = msgs })
  ok(#out.messages[2].content >= 1, "anthropic: a stripped-to-empty assistant turn gets a placeholder (no empty-content 400)")
end

-- ---- OpenAI / Responses: reasoning_effort passes; xhigh/max clamp to high ----
do
  local out = api._body_for_wire("openai", { model = "gpt-oss-120b", max_tokens = 100,
    messages = { { role = "user", content = "hi" } }, reasoning_effort = "medium" })
  eq(out.reasoning_effort, "medium", "openai: reasoning_effort passes through")
end
do
  local out = api._body_for_wire("openai", { model = "gpt-oss-120b", max_tokens = 100,
    messages = { { role = "user", content = "hi" } }, reasoning_effort = "xhigh" })
  eq(out.reasoning_effort, "high", "openai: xhigh clamps to high (OpenAI has no xhigh)")
  ok(out.output_config == nil, "openai: no Anthropic output_config leaks onto the OpenAI wire")
end
do
  local out = api._body_for_wire("responses", { model = "gpt-5.6-sol", max_tokens = 100,
    messages = { { role = "user", content = "hi" } }, reasoning_effort = "max" })
  ok(type(out.reasoning) == "table" and out.reasoning.effort == "high", "responses: max clamps to high under reasoning.effort")
end

-- ---- prompt caching: cache_control only on a real Claude body ---------------
do
  local out = api._body_for_wire("anthropic", base{})
  ok(type(out.cache_control) == "table" and out.cache_control.type == "ephemeral",
     "anthropic: a Claude body carries top-level ephemeral cache_control")
end
do
  local out = api._body_for_wire("anthropic",
    { model = "deepseek-v4-flash", max_tokens = 8000,
      messages = { { role = "user", content = "hi" } } })
  ok(out.cache_control == nil, "anthropic: a non-Claude (ds4) body has NO cache_control (ds4 ignores it)")
end
do
  local o = api._body_for_wire("openai", { model = "gpt-oss-120b", max_tokens = 100,
    messages = { { role = "user", content = "hi" } } })
  local r = api._body_for_wire("responses", { model = "gpt-5.6-sol", max_tokens = 100,
    messages = { { role = "user", content = "hi" } } })
  ok(o.cache_control == nil and r.cache_control == nil, "openai/responses bodies never carry cache_control")
end

-- ---- cost math: cache read @0.1x, write @1.25x, fresh input @1x --------------
-- M.cost returns nil for a local endpoint, so stub status() to a cloud Claude.
do
  local real = api.status
  api.status = function() return { is_local = false, model = "claude-sonnet-5" } end
  local function cost_of(u) return api.cost({ model = "claude-sonnet-5", usage = u }) end
  local base_c = cost_of({ input = 1000000, output = 0, cached = 0, cache_write = 0 })
  ok(base_c and base_c > 0, "cost: fresh input is priced")
  ok(math.abs(cost_of({ cached = 1000000 }) / base_c - api.CACHE_READ_RATIO) < 1e-9,
     "cost: cache-read tokens priced at 0.1x fresh input")
  ok(math.abs(cost_of({ cache_write = 1000000 }) / base_c - api.CACHE_WRITE_RATIO) < 1e-9,
     "cost: cache-write tokens priced at 1.25x fresh input")
  api.status = real
end

-- ---- Anthropic: tool input_schema is sanitised to valid draft-2020-12 -------
-- One invalid tool schema (an MCP server or a model-authored tool) 400s the
-- WHOLE request. The wire must normalise every schema so it cannot.
do
  local tools = {
    { name = "good", description = "d",
      input_schema = { type = "object", properties = { x = { type = "string" } } } },
    -- a draft-07 $schema URI, a draft-04 boolean exclusiveMinimum, an array with
    -- no items, a property given as a bare type string, and a non-object top.
    { name = "bad", description = "d", input_schema = {
        ["$schema"] = "http://json-schema.org/draft-07/schema#",
        type = "string",  -- not an object at the top
        properties = {
          n = { type = "integer", exclusiveMinimum = true },
          tags = { type = "array" },        -- no items
          note = "string",                   -- bare type, not a schema object
        },
        definitions = { Foo = { type = "object" } },
      } },
  }
  local out = api._body_for_wire("anthropic", base{ tools = tools })
  local by = {}
  for _, t in ipairs(out.tools) do by[t.name] = t end

  eq(by.good.input_schema.type, "object", "anthropic: a valid schema is preserved")
  eq(by.good.input_schema.properties.x.type, "string", "anthropic: valid nested property kept")

  local s = by.bad.input_schema
  eq(s.type, "object", "anthropic: a non-object top-level schema is forced to object")
  eq(s["$schema"], nil, "anthropic: a foreign $schema URI is stripped")
  eq(s.properties.n.exclusiveMinimum, nil, "anthropic: draft-04 boolean exclusiveMinimum is dropped")
  eq(s.properties.tags.items and s.properties.tags.items.type, "string",
     "anthropic: an array without items gets a permissive items")
  eq(type(s.properties.note), "table", "anthropic: a bare-string property becomes a schema object")
  eq(s.properties.note.type, "string", "anthropic: the bare-string property keeps its type")
  eq(s.definitions, nil, "anthropic: draft-07 'definitions' is migrated")
  ok(type(s["$defs"]) == "table", "anthropic: ...to '$defs'")

  -- The OpenAI/responses wires normalise via `parameters`, not `input_schema`.
  local oai = api._body_for_wire("openai", base{ tools = tools, reasoning_effort = "low" })
  ok(type(oai.tools[1]["function"].parameters) == "table", "openai: tools still carry parameters")
end

io.write(failed == 0 and ("wire: all " .. passed .. " passed\n")
                      or ("wire: " .. failed .. " FAILED, " .. passed .. " passed\n"))
os.exit(failed == 0 and 0 or 1)
