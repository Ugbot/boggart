-- skill: world_lookup -- look a world fact up and verify it, never recall it.
-- Everything it leans on is code (lua/story/geo.lua): the place tree, canon
-- deltas, holdings, facts as of a story time. It answers TRUE, FALSE or UNKNOWN
-- with the record behind the answer.
return {
  description = "Look up or verify a fact about a book's world -- where something is, "
    .. "whether it is inside a city or country, who holds an item, whether someone is "
    .. "alive, what is canon about a place -- before writing it into prose or an answer.",
  invocation = "model",
  fallback = { "core" },
  tools = { "story", "read" },

  -- The map of the world, so the model picks real place names, not plausible ones.
  before = function(ctx)
    if not (bog and bog.db) then return {} end
    local ok_b, sb = pcall(require, "story.book")
    if not ok_b then return {} end
    local b = sb.resolve(ctx and ctx.book)
    if not b then return {} end
    local sm, geo = require("story.model"), require("story.geo")
    sm.ensure_schema()
    sm.sync_in(b.name, b.root)
    local lines = geo.tree(b.name)
    return { set = { world_map = lines and table.concat(lines, "\n") or "", world_book = b.name } }
  end,

  instructions = function(ctx)
    local map = (ctx and ctx.world_map and ctx.world_map ~= "") and ctx.world_map or "(no places recorded yet)"
    return [[
# World lookup

Places in this book (name  [id]):

]] .. map .. [[


How to answer a world question:
- Where is X?                 `geo where name=X as_of=<t>`
- Is X in Y?                  `geo inside name=X of=Y as_of=<t>` or `check claim claim="X in Y"`
- What is in Y?               `geo contents name=Y as_of=<t>`
- What do X and Y share?      `geo between name=X other=Y`
- Can they get there in time? `geo travel name=X to=Y t1= t2=`
- What is canon about X?      `check facts name=X as_of=<t> pos=<where the reader is>`
- Does X hold / know / feel?  `check claim claim="X holds key"` / `"X knows F3"` / `"X mood=calm"`

TRUE and FALSE come with the record that decides them: quote it. UNKNOWN means the book
does not say: report that, and do not fill the gap from plausibility. A fact you are
inventing is a proposal (`event add`, `fact add`, `geo set`), never an answer.
]]
  end,
}
