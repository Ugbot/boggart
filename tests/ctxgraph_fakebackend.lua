-- tests/ctxgraph_fakebackend.lua -- an in-memory graph backend, plain Lua
-- tables, no SQL. It exists to prove the port (lua/ctxgraph/backend.lua) is
-- not SQLite-shaped: the contract test and the graph tests run against it as
-- well as the SQLite backend. Its search is a naive substring scan, ranked by
-- recency like the minimal backend.
--   local fake = dofile("tests/ctxgraph_fakebackend.lua")()
return function()
  local B = { name = "fake", calls = {} }
  local graphs = {}
  local function g(sid)
    graphs[sid] = graphs[sid] or { nodes = {}, edges = {}, meta = {} }
    return graphs[sid]
  end
  local function copy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
  end
  local function note(op) B.calls[op] = (B.calls[op] or 0) + 1 end
  local function with_links(gr, r)
    if not r then return nil end
    local o = copy(r)
    o.links = {}
    for _, e in ipairs(gr.edges) do
      if e.src == r.id then o.links[#o.links + 1] = { type = e.type, dst = e.dst } end
    end
    table.sort(o.links, function(a, b) return a.type < b.type or (a.type == b.type and a.dst < b.dst) end)
    return o
  end
  local function add_edge(gr, src, t, dst)
    for _, e in ipairs(gr.edges) do
      if e.src == src and e.type == t and e.dst == dst then return end
    end
    gr.edges[#gr.edges + 1] = { src = src, type = t, dst = dst }
  end
  local function sorted(gr, list)
    table.sort(list, function(a, b)
      if (a.seq or 0) ~= (b.seq or 0) then return (a.seq or 0) < (b.seq or 0) end
      return a.id < b.id
    end)
    local out = {}
    for i, r in ipairs(list) do out[i] = with_links(gr, r) end
    return out
  end

  function B.put_nodes(sid, records)
    note("put_nodes")
    local gr = g(sid)
    for _, r in ipairs(records) do
      local c = copy(r)
      c.links = nil
      gr.nodes[r.id] = c
      for _, l in ipairs(r.links or {}) do add_edge(gr, r.id, l.type, l.dst) end
    end
    return true
  end
  function B.put_edges(sid, edges)
    note("put_edges")
    local gr = g(sid)
    for _, e in ipairs(edges) do add_edge(gr, e.src, e.type, e.dst) end
    return true
  end
  function B.get(sid, id) local gr = g(sid); return with_links(gr, gr.nodes[id]) end
  local function linked(sid, id, t, dir)
    local gr, seen, out = g(sid), {}, {}
    for _, e in ipairs(gr.edges) do
      local here, there = dir == "out" and e.src or e.dst, dir == "out" and e.dst or e.src
      if here == id and (t == nil or e.type == t) and gr.nodes[there] and not seen[there] then
        seen[there] = true
        out[#out + 1] = gr.nodes[there]
      end
    end
    return sorted(gr, out)
  end
  function B.children(sid, id, t) return linked(sid, id, t, "out") end
  function B.referrers(sid, id, t) return linked(sid, id, t, "in") end
  function B.versions(sid, id) return linked(sid, id, "version_of", "in") end
  function B.scan(sid, types)
    local gr, set, out = g(sid), nil, {}
    if types and #types > 0 then set = {}; for _, t in ipairs(types) do set[t] = true end end
    for _, r in pairs(gr.nodes) do if not set or set[r.type] then out[#out + 1] = r end end
    return sorted(gr, out)
  end
  function B.search(sid, query, opts)
    opts = opts or {}
    local limit = tonumber(opts.limit) or 8
    local words = {}
    for w in tostring(query):lower():gmatch("[%w_]+") do words[#words + 1] = w end
    if #words == 0 then return {} end
    local hits, typeset = {}, nil
    if opts.types and #opts.types > 0 then
      typeset = {}
      for _, t in ipairs(opts.types) do typeset[t] = true end
    end
    for _, r in pairs(g(sid).nodes) do
      if typeset and not typeset[r.type] then goto next end
      local hay = ((r.title or "") .. "\n" .. (r.stub or "") .. "\n" .. (r.body or "")):lower()
      local all = true
      for _, w in ipairs(words) do if not hay:find(w, 1, true) then all = false end end
      if all then hits[#hits + 1] = r end
      ::next::
    end
    table.sort(hits, function(a, b) return (a.seq or 0) > (b.seq or 0) or ((a.seq or 0) == (b.seq or 0) and a.id < b.id) end)
    local out = {}
    for i = 1, math.min(limit, #hits) do
      out[i] = { id = hits[i].id, type = hits[i].type, stub = hits[i].stub or "", seq = hits[i].seq }
    end
    return out
  end
  function B.record_claim(sid, claim)
    if g(sid).nodes[claim.id] then return claim.id, false end
    B.put_nodes(sid, { claim })
    return claim.id, true
  end
  function B.set_claim_state(sid, id, state)
    local r = g(sid).nodes[id]
    if not r or r.type ~= "claim" then return nil, "no claim " .. tostring(id) end
    r.state = state
    return true
  end
  function B.meta(sid, key, value)
    if value ~= nil then g(sid).meta[key] = tostring(value); return tostring(value) end
    return g(sid).meta[key]
  end
  function B.export_bundle(sid) return { records = B.scan(sid) } end
  return B
end
