-- skill: grill_me -- user-invoked entry that adopts grilling.
-- Adapted from mattpocock/skills productivity/grill-me (disable-model-invocation).
return {
  description = "User-started grilling session: interview until the design tree "
    .. "is fully resolved. Invoke explicitly; not auto-suggested by find_skill.",
  invocation = "user",
  fallback = "grilling",
  tools = { "read", "list", "bash", "choose", "spawn", "await" },
  instructions = function()
    local g = require("skills.grilling")
    local it = g.instructions
    if type(it) == "function" then
      local ok, res = pcall(it)
      it = ok and res or ""
    end
    return "# Grill me\n\nThe user started this session. Follow the grilling "
      .. "discipline below until they confirm shared understanding — do not "
      .. "implement before that.\n\n" .. tostring(it or "")
  end,
}
