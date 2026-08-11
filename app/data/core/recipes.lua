-- recipes.lua -- saved, parameterised prompts.
--
-- A recipe is a prompt you run more than once: "review @{{file}} for races",
-- "write tests for {{module}}". Goose stores these as YAML with a schema; here
-- a recipe is a text file under ~/.boggart/recipes/ whose {{placeholders}} are
-- the parameters. That is the whole format.
--
-- The reason it is not a schema: boggart already has a mechanism for "a thing
-- the agent can do repeatedly with arguments" -- a generated tool, which is
-- code, is validated, and has provenance. A recipe is deliberately the weaker,
-- dumber sibling: text with holes in it, for the cases where you want the
-- model to think rather than a function to run. Giving it a schema would blur
-- two things that are useful precisely because they are different.
local core = require "core"

local recipes = {}

function recipes.dir()
  return bog.userdir .. "/recipes"
end

-- sys.*, not lite's system.*: these are boggart's capability layer, they know
-- the platform's rules, and mkdir_p already handles the "parent missing" case
-- that lite's mkdir does not.
local function ensure_dir()
  local d = recipes.dir()
  sys.mkdir_p(d)
  return d
end

function recipes.path(name)
  return recipes.dir() .. "/" .. name .. ".txt"
end

-- Every {{placeholder}}, in first-appearance order and without duplicates.
function recipes.params(text)
  local out, seen = {}, {}
  for p in tostring(text or ""):gmatch("{{%s*([%w_%-%.]+)%s*}}") do
    if not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  return out
end

function recipes.fill(text, values)
  return (tostring(text or ""):gsub("{{%s*([%w_%-%.]+)%s*}}", function(p)
    return values[p] or ("{{" .. p .. "}}")
  end))
end

function recipes.list()
  local d = recipes.dir()
  local out = {}
  for _, f in ipairs(sys.listdir(d) or {}) do
    local name = f:match("^(.+)%.txt$")
    if name then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

function recipes.load(name)
  return bog.util.read_file(recipes.path(name))
end

function recipes.save(name, text)
  ensure_dir()
  bog.util.write_file(recipes.path(name), text)
  return recipes.path(name)
end

-- Ask for each parameter in turn, then hand the filled prompt to `done`.
--
-- Written as a recursive step rather than a loop because lite's command view is
-- callback-driven: there is no way to block for an answer, so "ask for all the
-- parameters" has to be expressed as "ask for one, and in the callback ask for
-- the rest".
function recipes.prompt_params(text, done)
  local params = recipes.params(text)
  local values = {}
  local function step(i)
    if i > #params then return done(recipes.fill(text, values)) end
    core.command_view:enter(params[i] .. ":", function(answer)
      values[params[i]] = answer
      step(i + 1)
    end, function() return {} end)
  end
  step(1)
end

return recipes
