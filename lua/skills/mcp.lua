-- skill: mcp -- manage MCP servers (connect + list). Grant per-server tool
-- access in other skills with a wildcard, e.g. tools = { "mcp__github__*" }.
return {
  description = "Connect to and list MCP servers.",

  -- before: list the connected servers as CODE (`mcp` is a pure read of the host
  -- registry), so the model starts knowing what is already connected instead of
  -- spending a turn to check before it adds one. Guarded so it degrades to {}
  -- when no MCP host is present.
  before = function()
    local ok, servers = pcall(function() return bog.C("mcp")({}) end)
    if ok and type(servers) == "string" and servers ~= "" then
      return { set = { servers = servers } }
    end
    return {}
  end,

  instructions = function(ctx)
    local servers = ctx and ctx.servers
    local head = (servers and servers ~= "") and ("Connected MCP servers:\n" .. servers .. "\n\n") or ""
    return head .. "Use `mcp_add` to connect an MCP server (stdio or http) and `mcp` to list "
      .. "connected servers. A server's tools appear as mcp__<server>__<tool>; a skill grants "
      .. "them with a wildcard like \"mcp__<server>__*\"."
  end,
  tools = { "mcp_add", "mcp" },
}
