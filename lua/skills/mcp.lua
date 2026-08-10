-- skill: mcp -- manage MCP servers (connect + list). Grant per-server tool
-- access in other skills with a wildcard, e.g. tools = { "mcp__github__*" }.
return {
  description = "Connect to and list MCP servers.",
  instructions = "Use `mcp_add` to connect an MCP server (stdio or http) and `mcp` to list "
    .. "connected servers. A server's tools appear as mcp__<server>__<tool>; a skill grants "
    .. "them with a wildcard like \"mcp__<server>__*\".",
  tools = { "mcp_add", "mcp" },
}
