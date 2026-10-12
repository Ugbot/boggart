-- tracker_cli.lua -- `boggart tracker ...`: the tracker from a shell or a CI job.
--
--   boggart tracker                               projects (what /tracker shows)
--   boggart tracker BRAIN [done|tree]             what's next / finished / hierarchy
--   boggart tracker BRAIN-35 [full]               one ticket
--   boggart tracker <noun> <action> key=value...  any `tracker` tool call, e.g.
--       boggart tracker task create project=BOG title="Fix the thing"
--       boggart tracker commits scan repo=. close_keywords=true
--       boggart tracker issue sync project=BOG
--   boggart tracker export-file [path] [project=K,...]   (default .boggart/tracker.jsonl)
--   boggart tracker import-file [path]
--   boggart tracker record-junit <results.xml> [project=K,...]
--
-- Exit status is 1 when the answer is an error, so a CI step fails on it.
-- Values are strings (the tool coerces); `true`/`false` pass as booleans.
local M = {}

M.DEFAULT_FILE = ".boggart/tracker.jsonl"
local NOUNS = { project = 1, task = 1, status = 1, criteria = 1, tag = 1, commits = 1, deps = 1,
                issue = 1, query = 1, import = 1 }
local NO_ACTION = { status = true, query = true, import = true }

local function kv(args, from)
  local a = {}
  for i = from, #args do
    local k, v = args[i]:match("^([%w_]+)=(.*)$")
    if not k then return nil, "expected key=value, got '" .. args[i] .. "'" end
    if v == "true" then v = true elseif v == "false" then v = false end
    a[k] = v
  end
  return a
end

local function projects_arg(a)
  if not a or not a.project or a.project == "" then return nil end
  local t = {}
  for p in tostring(a.project):gmatch("[^,%s]+") do t[#t + 1] = p end
  return t
end

-- -> text, exit code
function M.run(args)
  args = args or {}
  local first = args[1]
  local tc, tf = require("tracker_core"), require("tracker_file")
  if first == "export-file" or first == "import-file" or first == "record-junit" then
    local path = args[2]
    local rest = 3
    if path and path:find("=", 1, true) then path, rest = nil, 2 end
    local a, e = kv(args, rest)
    if not a then return "Error: " .. e, 1 end
    local out, err
    if first == "export-file" then out, err = tf.export(path or M.DEFAULT_FILE, projects_arg(a))
    elseif first == "import-file" then out, err = tf.import(path or M.DEFAULT_FILE)
    else
      if not path then return "Error: record-junit needs a JUnit XML path", 1 end
      out, err = tf.record_junit(path, projects_arg(a))
    end
    if not out then return "Error: " .. tostring(err), 1 end
    return out, 0
  end
  if first and NOUNS[first] then
    local a, e = kv(args, NO_ACTION[first] and 2 or 3)
    if not a then return "Error: " .. e, 1 end
    a.noun = first
    if not NO_ACTION[first] then a.action = args[2] end
    local out = tc.call(a)
    return out, (type(out) == "string" and out:find("^Error:")) and 1 or 0
  end
  -- display forms: the same text the TUI's /tracker prints
  local width = tonumber(os.getenv("COLUMNS")) or 100
  local out = require("tracker_view").command(table.concat(args, " "), width)
  return out, out:find("^tracker: ") and 1 or 0
end

return M
