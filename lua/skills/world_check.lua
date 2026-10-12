-- skill: world_check -- the world-consistency gate for a book. The check runs as
-- CODE (lua/story/geo.lua audit): place-tree cycles, moves to things that are not
-- places, two places at once, travelling faster than the declared routes allow,
-- items held twice, acting after death. No model is asked whether the world holds
-- together, and "it checks out" cannot be said without the audit passing.
local function run_audit(spec)
  if not (bog and bog.db) then return nil, "store not open" end
  local ok_b, sb = pcall(require, "story.book")
  if not ok_b then return nil, "the story layer is not available" end
  local b, e = sb.resolve(spec)
  if not b then return nil, e end
  local sm, geo = require("story.model"), require("story.geo")
  sm.ensure_schema()
  sm.sync_in(b.name, b.root)
  return geo.audit(b.name), b, geo
end

return {
  description = "Check a book's world for consistency before or after writing: where "
    .. "everyone and everything is, place containment, travel times against declared "
    .. "routes, items held twice, acting after death. Use before drafting a scene that "
    .. "moves people, and before calling a chapter or world done.",
  invocation = "model",
  fallback = { "core" },
  tools = { "story", "read" },

  -- The audit, up front, so the model starts from the facts instead of guessing.
  before = function(ctx)
    local rep, b, geo = run_audit(ctx and ctx.book)
    if not rep then return { set = { world_audit = "unavailable: " .. tostring(b) } } end
    return { set = { world_audit = geo.audit_text(rep), world_errors = rep.counts.error } }
  end,

  instructions = function(ctx)
    local audit = ctx and ctx.world_audit or "(not run)"
    return [[
# World check

The world was audited in code just now:

]] .. audit .. [[


Rules:
1. Never assert where a character or item is, or who holds what, from memory. Ask the
   story tool: `check claim claim="vera in paris" as_of=<t>` (TRUE / FALSE / UNKNOWN),
   `geo where`, `geo contents`, `geo inside`.
2. UNKNOWN means the book does not say. Do not treat it as false and do not invent the
   answer; propose it (`event add`, `geo set`) for the author to accept.
3. Before moving someone, check the journey: `geo travel name=<who> to=<place> t1= t2=`.
4. Fix every error above (or propose the fix); warnings need a decision, notes do not.

The verify step below re-runs the audit in code and blocks "the world is consistent"
while any error remains.
]]
  end,

  verify = function(_, ctx)
    local rep, b, geo = run_audit(ctx and ctx.book)
    if not rep then return true end -- no book / no store: nothing to gate
    if rep.counts.error == 0 then return true end
    return "world audit found " .. rep.counts.error .. " error(s):\n" .. geo.audit_text(rep)
  end,
}
