-- skill: memory -- durable cross-session memory.
return {
  description = "Save and recall durable facts (FTS-backed).",

  -- before: a recall probe. `recall` is a pure FTS read (no side effects), so
  -- run it here and hand the model what is already stored -- probing the passed
  -- query if there is one, else the full set. Saves the model a `recall` turn to
  -- see what it already knows. Guarded so it degrades to {} without a store.
  before = function(ctx)
    local args = (ctx and type(ctx.args) == "table" and ctx.args) or {}
    local q = args.query or args.topic or args.title
    local ok, mem = pcall(function() return bog.C("recall")({ query = q }) end)
    if ok and type(mem) == "string" and mem ~= "" and not mem:find("^%(no ") then
      return { set = { memories = mem } }
    end
    return {}
  end,

  instructions = function(ctx)
    local mem = ctx and ctx.memories
    local head = (mem and mem ~= "") and ("Already in memory (recalled):\n" .. mem .. "\n\n") or ""
    return head .. "Save durable facts with `remember`; search them with `recall`."
  end,
  tools = { "remember", "recall", "forget" },
}
