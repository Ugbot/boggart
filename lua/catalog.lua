-- catalog.lua -- what models exist, where they live, and what they can do.
--
-- The store is the truth (three tables in lua/store.lua, reached through the C
-- operations in src/lrepo.c). This module is everything around it: the seed
-- import, JSON in and out, role bindings, and the small conversions that make
-- SQLite rows pleasant to use from Lua.
--
-- JSON is the EXCHANGE format, not the store. That distinction is the whole
-- design: rows can be queried ("which models do vision above 500k context"),
-- edited by the agent through the `sql`/`kv` tools it already has, and joined
-- against telemetry to say what a model actually cost -- none of which a file
-- can do. A file is how a catalog arrives, leaves, and gets shared.
local M = {}

local json = require "json"

M.SEED = "models.json"          -- baked into the binary (see tools/bake_embedded.cmake)
M.SOURCES = { seed = true, import = true, refresh = true, user = true }

-- ---------------------------------------------------------------------------
-- row conversions
-- ---------------------------------------------------------------------------
--
-- SQLite has no boolean: a capability comes back as 0 or 1, and in Lua BOTH are
-- truthy. `if model.effort then` on a row straight from the store is therefore
-- always true, which is exactly the kind of bug that hides for months. Every
-- row leaves this module with real booleans.
local FLAGS = { "tools", "vision", "effort" }

local function to_bool(v)
  if v == nil then return nil end
  if type(v) == "boolean" then return v end
  if type(v) == "number" then return v ~= 0 end
  return v == "true" or v == "1"
end

local function from_row(row)
  if not row then return nil end
  for _, f in ipairs(FLAGS) do
    if row[f] ~= nil then row[f] = to_bool(row[f]) end
  end
  if type(row.headers) == "string" and row.headers ~= "" then
    local ok, t = pcall(json.decode, row.headers)
    row.headers = ok and t or nil
  end
  return row
end
M.from_row = from_row

-- ---------------------------------------------------------------------------
-- reading
-- ---------------------------------------------------------------------------

function M.model(id)
  if not (bog.db and id) then return nil end
  local ok, row = pcall(bog.store.model_get, id)
  return ok and from_row(row) or nil
end

function M.provider(name)
  if not (bog.db and name) then return nil end
  local ok, row = pcall(bog.store.provider_get, name)
  return ok and from_row(row) or nil
end

-- The full destination for a model id: its own row plus its provider's.
-- Returns nil when the model is not catalogued, which the caller treats as
-- "a bare model id on the current endpoint" rather than an error.
function M.destination(id)
  local m = M.model(id)
  if not m then return nil end
  local p = m.provider and M.provider(m.provider) or nil
  if not p then return nil end
  return {
    model = id, url = p.url, wire = p.wire, auth = p.auth,
    key_slot = p.key_slot or p.name, headers = p.headers,
    provider = p.name, name = p.name,
    context = m.context, tools = m.tools, vision = m.vision, effort = m.effort,
    max_output = m.max_output,
  }
end

function M.models(filter)
  if not bog.db then return {} end
  local ok, rows = pcall(bog.store.models_where, filter or {})
  if not ok then return {} end
  for i, r in ipairs(rows) do rows[i] = from_row(r) end
  return rows
end

function M.providers()
  if not bog.db then return {} end
  local ok, rows = pcall(bog.store.catalog_list, "providers")
  if not ok then return {} end
  for i, r in ipairs(rows) do rows[i] = from_row(r) end
  return rows
end

-- ---------------------------------------------------------------------------
-- roles: an agent declares intent, a user binds it to a model
-- ---------------------------------------------------------------------------
--
-- A role's spec is either a model id or an ordered list of them. A list is a
-- fallback chain: the next entry is tried when one is rate-limited, erroring,
-- or has no key. Always returned as a list so callers have one shape to handle.
function M.role(name)
  if not (bog.db and name) then return nil end
  local ok, raw = pcall(bog.store.role_get, name)
  if not ok or type(raw) ~= "string" or raw == "" then return nil end
  local okj, spec = pcall(json.decode, raw)
  if not okj then return { raw } end
  if type(spec) == "string" then return { spec } end
  if type(spec) == "table" then return spec end
  return nil
end

function M.bind_role(name, spec)
  if type(spec) == "string" then spec = { spec } end
  if type(spec) ~= "table" or #spec == 0 then
    return nil, "a role needs a model id, or a list of them"
  end
  local payload = (#spec == 1) and json.encode(spec[1]) or json.encode(spec)
  local ok, err = pcall(bog.store.role_put, name, payload)
  if not ok then return nil, tostring(err) end
  bog.events.emit("catalog:role", { name = name, spec = spec })
  return spec
end

function M.roles()
  if not bog.db then return {} end
  local ok, rows = pcall(bog.store.catalog_list, "roles")
  if not ok then return {} end
  local out = {}
  for _, r in ipairs(rows) do out[r.name] = M.role(r.name) end
  return out
end

-- ---------------------------------------------------------------------------
-- import / export: the JSON half
-- ---------------------------------------------------------------------------

-- Import a catalog table. An UPSERT per entry, so a file naming one model
-- updates that row and leaves every other one alone -- which is what makes a
-- small hand-written file a useful thing to hand to `import`, rather than
-- something that would wipe the catalog it is added to.
function M.import(t, source)
  if type(t) ~= "table" then return nil, "a catalog must be a table" end
  source = source or "import"
  local n = { providers = 0, models = 0, roles = 0 }

  for name, p in pairs(t.providers or {}) do
    if type(p) == "table" then
      local row = {
        name = name, label = p.label, url = p.url, wire = p.wire, auth = p.auth,
        key_slot = p.key_slot or name, env = p.env, catalog_url = p.catalog_url,
        source = p.source or source,
      }
      if type(p.headers) == "table" then row.headers = json.encode(p.headers) end
      local ok = pcall(bog.store.provider_put, row)
      if ok then n.providers = n.providers + 1 end
    end
  end

  for id, m in pairs(t.models or {}) do
    if type(m) == "table" then
      local ok = pcall(bog.store.model_put, {
        id = id, provider = m.provider, label = m.label,
        context = m.context, max_output = m.max_output,
        tools = m.tools, vision = m.vision, effort = m.effort,
        input_price = m.input_price, output_price = m.output_price,
        source = m.source or source,
      })
      if ok then n.models = n.models + 1 end
    end
  end

  for name, spec in pairs(t.roles or {}) do
    if M.bind_role(name, spec) then n.roles = n.roles + 1 end
  end

  bog.events.emit("catalog:import", { source = source, counts = n })
  return n
end

function M.import_json(text, source)
  local ok, t = pcall(json.decode, text)
  if not ok or type(t) ~= "table" then return nil, "not valid JSON" end
  return M.import(t, source)
end

function M.import_file(path, source)
  local data = bog.util.read_file(path)
  if not data then return nil, "cannot read " .. tostring(path) end
  return M.import_json(data, source or "import")
end

-- Export the live tables in the same shape the seed is written in, so
-- export -> edit -> import is the way to hand-edit the catalog.
function M.export()
  local out = { version = 1, providers = {}, models = {}, roles = {} }
  for _, p in ipairs(M.providers()) do
    local e = { label = p.label, url = p.url, wire = p.wire, auth = p.auth,
                key_slot = p.key_slot, env = p.env, catalog_url = p.catalog_url,
                headers = p.headers, source = p.source }
    out.providers[p.name] = e
  end
  for _, m in ipairs(M.models()) do
    out.models[m.id] = { provider = m.provider, label = m.label, context = m.context,
                         max_output = m.max_output, tools = m.tools, vision = m.vision,
                         effort = m.effort, input_price = m.input_price,
                         output_price = m.output_price, source = m.source }
  end
  for name, spec in pairs(M.roles()) do
    out.roles[name] = (#spec == 1) and spec[1] or spec
  end
  return out
end

function M.export_json() return json.encode(M.export()) end

-- ---------------------------------------------------------------------------
-- refresh: ask a provider what it has
-- ---------------------------------------------------------------------------
--
-- A provider that publishes its own catalog is the only thing that can be right
-- about it for long. `catalog_url` names that list; today only OpenRouter seeds
-- one, and anything else serving the same shape is a row away.
--
-- The shape is OpenAI's: { data = { { id=, context_length=, pricing=,
-- architecture={input_modalities}, supported_parameters={} }, ... } }.
-- Unknown fields are ignored rather than rejected -- a catalog that refuses to
-- import because a vendor added a key is a catalog nobody refreshes.
local function has(list, want)
  for _, v in ipairs(list or {}) do if v == want then return true end end
  return false
end

function M.parse_openai_models(text, provider, prefix)
  local ok, t = pcall(json.decode, text)
  if not ok or type(t) ~= "table" then return nil, "not valid JSON" end
  local rows = t.data or t.models or t
  if type(rows) ~= "table" then return nil, "no model list in the response" end
  local out = {}
  for _, m in ipairs(rows) do
    if type(m) == "table" and type(m.id) == "string" then
      local arch = m.architecture or {}
      local params = m.supported_parameters or {}
      local pricing = m.pricing or {}
      local id = prefix and (prefix .. "/" .. m.id) or m.id
      out[id] = {
        provider = provider,
        label = m.name,
        context = tonumber(m.context_length or m.context_window),
        max_output = tonumber(m.top_provider and m.top_provider.max_completion_tokens),
        vision = has(arch.input_modalities, "image") or nil,
        tools = has(params, "tools") or nil,
        effort = (has(params, "reasoning") or has(params, "reasoning_effort")) or nil,
        -- OpenRouter prices per token as strings; the store keeps per 1M so the
        -- number a person recognises is the number they see.
        input_price = tonumber(pricing.prompt) and tonumber(pricing.prompt) * 1e6 or nil,
        output_price = tonumber(pricing.completion) and tonumber(pricing.completion) * 1e6 or nil,
      }
    end
  end
  return out
end

-- refresh(name) -> counts | nil, err.  Network; call it from a command, not a
-- turn. Rows land with source='refresh', so a hand-edited row is visibly
-- distinct from one a vendor supplied.
function M.refresh(name)
  local p = M.provider(name)
  if not p then return nil, "no provider called " .. tostring(name) end
  if not p.catalog_url or p.catalog_url == "" then
    return nil, name .. " does not publish a catalog"
  end
  local okr, status, body = pcall(http.request, {
    url = p.catalog_url, method = "GET", timeout = 30,
    -- Some catalogs are public; sending the key when we have one is harmless
    -- and required by the ones that are not. C decides whether a key exists
    -- and whether it may go to this host.
    auth = true, key_slot = p.key_slot or p.name, auth_style = p.auth,
  })
  if not okr then return nil, "request failed: " .. tostring(status) end
  if status ~= 200 then return nil, string.format("%s answered %s", name, tostring(status)) end
  -- OpenRouter's ids are already "vendor/model"; prefix them with the provider
  -- so they cannot collide with a directly-configured model of the same name.
  local prefix = (name == "openrouter") and "openrouter" or nil
  local models, perr = M.parse_openai_models(body, name, prefix)
  if not models then return nil, perr end
  local n = M.import({ models = models }, "refresh")
  bog.events.emit("catalog:refresh", { provider = name, models = n and n.models })
  return n
end

-- ---------------------------------------------------------------------------
-- seeding
-- ---------------------------------------------------------------------------

-- Import the baked catalog when the tables are empty. Called once from boot;
-- silent and idempotent, so a user who has curated their own catalog is never
-- re-seeded over, and an install with neither seed nor tables simply behaves
-- as boggart did before a catalog existed.
function M.seed_if_empty()
  if not bog.db then return false end
  local have = M.providers()
  if #have > 0 then return false end
  local text = boggart.embedded(M.SEED)
  if not text or text == "" then return false end
  local n, err = M.import_json(text, "seed")
  if not n then return false, err end
  bog.log(string.format("model catalog seeded: %d providers, %d models",
    n.providers, n.models))
  return n
end

return M
