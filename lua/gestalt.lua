-- gestalt.lua -- an opt-in client for the Gestalt data plane, for the deep
-- questions the model should not guess at: SQL analytics, graph queries
-- (SPARQL / openCypher over the triple store), and lineage.
--
-- Convert-don't-adopt (docs/extending.md): boggart speaks Gestalt's HTTP CQRS
-- gateway at the boundary and Lua inside. One envelope, POST
-- <base>/api/v1/<domain> with { action, resource, params }; the reply is
-- { ok, data } or { ok=false, error }.
--
-- Opt-in and best-effort: with no daemon reachable, every call returns
-- nil + reason and nothing else changes. Config from the environment:
--   GESTALT_URL      (default http://127.0.0.1:8080)
--   GESTALT_API_KEY  (optional; auth is disabled by default on a dev daemon)
--
-- These answers are CODE, not a model opinion (docs/compounding.md): a graph
-- traversal or an aggregate is computed by a real engine and returned as fact.
-- The tools register as gestalt_query / gestalt_graph / gestalt_lineage, so
-- the agent reaches a graph the way it reaches any tool, and they compose as
-- Callables.
local M = {}

local json = require("json")

function M.base()
  local u = os.getenv("GESTALT_URL")
  if u and u ~= "" then return (u:gsub("/+$", "")) end
  return "http://127.0.0.1:8080"
end

-- One CQRS call. domain is catalog|compute|storage|admin. Returns data | nil,
-- err. Never raises: a down daemon or a Gestalt error becomes nil + reason.
-- http.request returns (status, body) and takes headers as an array of
-- "Key: value" strings (src/lhttp.c); a transport failure returns nil + msg.
function M.call(domain, action, params, timeout)
  if not (http and http.request) then return nil, "http unavailable" end
  local body = json.encode({ action = action, resource = "", params = params or {} })
  local headers = { "content-type: application/json" }
  local key = os.getenv("GESTALT_API_KEY")
  if key and key ~= "" then headers[#headers + 1] = "authorization: Bearer " .. key end
  local ok, status, resp = pcall(http.request, {
    url = M.base() .. "/api/v1/" .. domain,
    method = "POST", headers = headers, body = body,
    timeout = timeout or 30,
  })
  if not ok then return nil, "gestalt call raised: " .. tostring(status) end
  if not status then return nil, "gestalt unreachable: " .. tostring(resp) end
  if status >= 400 then return nil, "gestalt HTTP " .. tostring(status) end
  if type(resp) ~= "string" or resp == "" then return nil, "empty response" end
  local okj, decoded = pcall(json.decode, resp)
  if not okj or type(decoded) ~= "table" then return nil, "bad json from gestalt" end
  if decoded.ok == false then
    local e = decoded.error or {}
    return nil, "gestalt: " .. tostring(e.message or e.code or "error")
  end
  return decoded.data
end

-- Is a daemon reachable? A cheap SQL probe (SELECT 1) doubles as a ping.
function M.available()
  local d = M.call("compute", "query.execute", { sql = "SELECT 1" }, 3)
  return d ~= nil
end

-- SQL over Gestalt's engine. Returns the decoded data table or nil, err.
function M.query(sql, timeout)
  return M.call("compute", "query.execute", { sql = sql }, timeout)
end

-- SPARQL over the triple store. `q` is a SPARQL query string.
function M.sparql(q, timeout)
  return M.call("compute", "sparql.query", { query = q }, timeout)
end

-- openCypher over the triple store's directed labelled graph.
function M.cypher(q, timeout)
  return M.call("compute", "cypher.query", { query = q }, timeout)
end

-- The table catalog: every table with its columns. What the model reads before
-- writing SQL, so a query names real columns instead of guessing them.
function M.tables(timeout)
  return M.call("catalog", "table.list", {}, timeout)
end

-- ---- tool registration -----------------------------------------------------
-- Registered only when a daemon answers, so a machine without Gestalt shows no
-- phantom tools (the station/llm-station rule).
function M.register()
  if not (bog and bog.tools and bog.tools.register) then return false end
  if not M.available() then return false end

  local function as_text(data, err)
    if not data then return "Tool error: [capability] " .. tostring(err) end
    return json.encode(data)
  end

  bog.tools.register("gestalt_schema", {
    description = "List the tables in the Gestalt data plane with their columns "
      .. "and types. Call this FIRST when you intend to run gestalt_query, so "
      .. "your SQL names columns that exist instead of guessing them.",
    input_schema = { type = "object", properties = {} },
    run = function() return as_text(M.tables()) end,
  })

  bog.tools.register("gestalt_query", {
    description = "Run SQL against the Gestalt data plane and return the result "
      .. "as JSON. For analytical questions over the team's stored data that "
      .. "should be COMPUTED, not guessed. Prefer this over reasoning about "
      .. "numbers you would otherwise estimate. Call gestalt_schema first if you "
      .. "do not already know the table and column names.",
    input_schema = { type = "object",
      properties = { sql = { type = "string", description = "a SQL query" } },
      required = { "sql" } },
    run = function(a)
      if type(a.sql) ~= "string" or a.sql == "" then
        return "Tool error: [validation] gestalt_query needs 'sql'"
      end
      return as_text(M.query(a.sql))
    end,
  })

  bog.tools.register("gestalt_graph", {
    description = "Query Gestalt's knowledge graph (the triple store). "
      .. "lang='sparql' runs SPARQL, lang='cypher' runs openCypher. Use for "
      .. "relationship and traversal questions -- who depends on what, paths, "
      .. "neighbourhoods -- that a graph answers exactly and prose guesses at.",
    input_schema = { type = "object", properties = {
      query = { type = "string", description = "the graph query" },
      lang = { type = "string", description = "sparql (default) or cypher" },
    }, required = { "query" } },
    run = function(a)
      if type(a.query) ~= "string" or a.query == "" then
        return "Tool error: [validation] gestalt_graph needs 'query'"
      end
      if a.lang == "cypher" then return as_text(M.cypher(a.query)) end
      return as_text(M.sparql(a.query))
    end,
  })

  bog.tools.register("gestalt_lineage", {
    description = "Read Gestalt data lineage: which datasets/tables a value "
      .. "flowed from. op='list' lists lineage tags on a resource.",
    input_schema = { type = "object", properties = {
      op = { type = "string", description = "list" },
      resource = { type = "string", description = "the resource to trace" },
    }, required = { "op" } },
    run = function(a)
      if a.op == "list" then
        local d, err = M.call("compute", "lineage.tag.list", { resource = a.resource })
        return as_text(d, err)
      end
      return "Tool error: [validation] gestalt_lineage op must be 'list'"
    end,
  })

  bog.log("gestalt: connected (" .. M.base() .. ") -- gestalt_schema/query/graph/lineage live")
  return true
end

return M
