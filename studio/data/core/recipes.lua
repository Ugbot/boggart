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

-- ---------------------------------------------------------------------------
-- Workflows: recipes in a row
-- ---------------------------------------------------------------------------
--
-- A recipe is one prompt. A workflow is several, in order, where each step can
-- read what the step before it returned. That is the idea worth taking from
-- MindStudio: an agent is a thing you *build* -- a sequence, some variables, a
-- model per step, and a form for its inputs -- rather than a message you retype
-- with different nouns in it.
--
-- The format is the recipe format with a delimiter and a few headers:
--
--     lines before the first step are the description
--
--     --- step: Outline
--     model: deepseek-v4-flash
--     tools: read, grep
--     out: outline
--
--     Read {{file}} and list what it does, one bullet each.
--
--     --- step: Critique
--
--     Here is an outline of {{file}}:
--
--     {{previous}}
--
--     Which bullet is wrong?
--
-- Why text and not a serialised Lua table: a workflow is user data that the
-- agent itself can write, and boggart has already been bitten once by persisted
-- "data" that was really code -- a generated tool carried its own load() and
-- with it a way out of the sandbox. This parser only ever produces strings,
-- lists of strings, and integers; there is no load(), no setmetatable, no
-- evaluation of any kind, so a hostile workflow file is at worst a hostile
-- prompt. It is also the same shape as a recipe, which means you can read one
-- in `less` and edit one in any editor, including this one.
--
-- Two deliberate limitations, both visible rather than papered over:
--   * `--- step` at the start of a line is the delimiter and cannot be escaped,
--     so a prompt cannot contain that line. Nothing else in the file is
--     reserved.
--   * headers are a fixed, known set (model, tools, out). An unrecognised
--     `Note: ...` line at the top of a prompt stays part of the prompt, which
--     is what you meant; the alternative -- "anything word-colon is a header"
--     -- silently eats prose.
local WF_KEYS = { model = true, tools = true, out = true }

local workflows = {}
recipes.workflows = workflows

function workflows.dir()
  return bog.userdir .. "/workflows"
end

function workflows.path(name)
  return workflows.dir() .. "/" .. name .. ".txt"
end

function workflows.list()
  local out = {}
  for _, f in ipairs(sys.listdir(workflows.dir()) or {}) do
    local name = f:match("^(.+)%.txt$")
    if name then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

local function joined(lines)
  while #lines > 0 and lines[1]:match("^%s*$") do table.remove(lines, 1) end
  while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end
  return table.concat(lines, "\n")
end

-- "read, grep" and "read grep" both mean the same two tools; a trailing-* entry
-- ("mcp__github__*") is passed through untouched because bog.tools.allowed
-- already understands it.
function workflows.split_list(s)
  local out = {}
  for w in tostring(s or ""):gmatch("[^%s,]+") do out[#out + 1] = w end
  return out
end

function workflows.parse(text)
  local wf = { description = "", steps = {} }
  local desc, cur, body = {}, nil, nil

  local function close()
    if cur then
      cur.prompt = joined(body)
      wf.steps[#wf.steps + 1] = cur
    end
  end

  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\r?\n") do
    local title = line:match("^%-%-%-%s*step%s*:%s*(.-)%s*$")
    if not title and line:match("^%-%-%-%s*step%s*$") then title = "" end
    if title then
      close()
      cur, body = { name = (title ~= "" and title) or nil }, {}
    elseif cur then
      local k, v = line:match("^(%a[%w_]*)%s*:%s*(.-)%s*$")
      k = k and k:lower()
      if #body == 0 and k and WF_KEYS[k] then
        if k == "tools" then cur.tools = workflows.split_list(v)
        elseif v ~= "" then cur[k] = v end
      elseif #body == 0 and line:match("^%s*$") then
        -- blank lines between the headers and the prompt are separators
      else
        body[#body + 1] = line
      end
    else
      desc[#desc + 1] = line
    end
  end
  close()
  wf.description = joined(desc)
  return wf
end

function workflows.serialise(wf)
  local out = {}
  local d = (wf.description or ""):gsub("%s+$", "")
  if d ~= "" then out[#out + 1] = d; out[#out + 1] = "" end
  for _, s in ipairs(wf.steps or {}) do
    out[#out + 1] = (s.name and s.name ~= "") and ("--- step: " .. s.name)
                    or "--- step"
    if s.model and s.model ~= "" then out[#out + 1] = "model: " .. s.model end
    if s.tools and #s.tools > 0 then
      out[#out + 1] = "tools: " .. table.concat(s.tools, ", ")
    end
    if s.out and s.out ~= "" then out[#out + 1] = "out: " .. s.out end
    out[#out + 1] = ""
    out[#out + 1] = s.prompt or ""
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

function workflows.load(name)
  local body = bog.util.read_file(workflows.path(name))
  if not body then return nil end
  local wf = workflows.parse(body)
  wf.name = name
  return wf
end

function workflows.save(name, wf)
  sys.mkdir_p(workflows.dir())
  bog.util.write_file(workflows.path(name), workflows.serialise(wf))
  return workflows.path(name)
end

-- The name a step's answer is stored under, so a later step can say
-- {{outline}} instead of relying on {{previous}} still being it.
function workflows.slot(step, i)
  local name = step.out
  if name and name ~= "" then return name end
  return "step" .. i
end

-- What the form has to ask for: every {{variable}} across the steps, minus the
-- ones the run produces itself. Order is first appearance, which is the order
-- you wrote them in and therefore the order it makes sense to be asked.
function workflows.params(wf)
  local produced = { previous = true }
  local out, seen = {}, {}
  for i, s in ipairs(wf.steps or {}) do
    for _, p in ipairs(recipes.params(s.prompt)) do
      if not produced[p] and not seen[p] then
        seen[p] = true
        out[#out + 1] = p
      end
    end
    produced[workflows.slot(s, i)] = true
  end
  return out
end

return recipes
