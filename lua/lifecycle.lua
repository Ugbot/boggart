-- lifecycle.lua -- install, first run, and diagnosis.
--
-- Everything else in the harness assumes its world exists: a data directory it
-- can write, a store it can open, a credential it can send. This module is
-- where that assumption is *made* true on a new machine and where it is
-- explained when it is false. Two rules shape it:
--
--   Missing is normal. A directory that is not there, a database that has
--   never been created, a schema one version behind -- none of those are
--   errors on a fresh install, they are the ordinary state of a program that
--   has not run yet. They get created, quietly, on every start.
--
--   Broken is a sentence, not a traceback. `embedded:store:149: db exec: file
--   is not a database` plus eleven lines of stack tells a user nothing they
--   can act on. Every failure here names the path, says what is wrong with it,
--   and says what to do about it.
--
-- Path policy is not decided here. It lives in C (src/lsys.c, sys.paths()),
-- next to sys.caps(), for the reason given in src/bogpaths.h: Lua asks.
local M = {}

-- Same error shape as api.lua's fail(): bog.try passes a table carrying
-- boggart_error straight through without attaching a traceback, and the REPL
-- prints tostring() of it. Duplicated rather than imported because this module
-- has to work before api.lua (and http, and the store) are wired.
local ERRMT = {
  __tostring = function(e)
    if e.hint and e.hint ~= "" then return e.message .. "\n" .. e.hint end
    return e.message
  end,
}

function M.fail(message, hint)
  error(setmetatable({
    boggart_error = true, kind = "install", message = message, hint = hint,
    fatal = true,
  }, ERRMT), 0)
end

-- ---- paths -----------------------------------------------------------------
-- Resolved once per process. boot.lua calls this before anything else exists,
-- so it deliberately depends on nothing but sys.
function M.paths()
  if bog.paths then return bog.paths end
  local p, err = sys.paths()
  if not p then return nil, err end
  p.db = p.data .. "/boggart.db"
  p.overlay = p.data .. "/lua"
  p.history = p.data .. "/history"
  bog.paths = p
  return p
end

-- ---- directory: create it, or explain why we cannot -------------------------
-- Returns true, or raises a diagnosed error. Idempotent: the common case is an
-- existing directory and this does one stat.
--
-- The writability probe is a real file, not a permission bit: the bits lie on
-- NFS, on a read-only mount, when a container maps the uid differently, and on
-- Windows where the ACL is what matters and the mode is decorative.
function M.ensure_dir(dir)
  local kind = sys.stat(dir)
  if kind == "file" or kind == "other" then
    M.fail(dir .. " already exists and is not a directory.",
      "boggart keeps its store, credentials and editable Lua in that directory.\n" ..
      "Move or rename that file, or set BOGGART_HOME to a different path.")
  end
  if kind ~= "dir" then
    local ok, err = sys.mkdir_p(dir)
    if not ok then
      M.fail("cannot create " .. dir .. ": " .. tostring(err) .. ".",
        "Check that its parent directory exists and is writable,\n" ..
        "or set BOGGART_HOME to a directory boggart may use.")
    end
    -- 0700: the credential file lives in here, and a 0600 file inside a
    -- world-listable directory still leaks its existence and its mtime.
    pcall(sys.chmod, dir, 0x1C0)
  end
  local probe = dir .. "/.write-probe-" .. tostring(sys.pid())
  local f = io.open(probe, "wb")
  if not f then
    M.fail(dir .. " is not writable.",
      "boggart has to write its store and credentials there.\n" ..
      "Fix the permissions on that directory, or set BOGGART_HOME to one you own.")
  end
  f:close()
  os.remove(probe)
  return true
end

-- ---- first run --------------------------------------------------------------
-- Short on purpose. A new user needs three facts -- what this is, where it put
-- its files, and the one thing standing between them and a working agent --
-- and a wall of text at first launch is how none of them get read. Printed on
-- stderr so it never lands in the middle of piped output, and only when the
-- store was created by this very start (see store.state.first_run).
function M.welcome()
  local p = bog.paths or {}
  local out = {
    "",
    "Welcome to boggart " .. tostring(bog.version) .. " -- a coding agent that can rewrite itself.",
    "",
    "Its files are in " .. tostring(p.data) .. ":",
    "  boggart.db   sessions, memory and tool history",
    "  auth         credentials, owner-readable only",
    "  lua/         your edits to the harness; anything here overrides the built-in",
    "",
  }
  if auth.has_key() or auth.base_url() then
    out[#out + 1] = "You have credentials set, so you are ready to go. Try: boggart \"hello\""
  else
    out[#out + 1] = "One thing left -- point it at a model:"
    out[#out + 1] = "  /auth key sk-ant-...             store an Anthropic API key, or"
    out[#out + 1] = "  /auth url http://127.0.0.1:8000  a local Anthropic-shaped server (e.g. ds4)"
    out[#out + 1] = "  /auth url http://127.0.0.1:8080 + /auth wire openai   a local OpenAI server"
    out[#out + 1] = "                                    (llama.cpp / vLLM / LM Studio), then /model <id>"
    out[#out + 1] = "(ANTHROPIC_API_KEY in the environment works too, and wins over both.)"
  end
  out[#out + 1] = ""
  out[#out + 1] = "`boggart doctor` checks all of this. `boggart --help` lists the rest."
  out[#out + 1] = ""
  return table.concat(out, "\n")
end

-- ---- formatting helpers -----------------------------------------------------
local function human_bytes(n)
  if not n then return "?" end
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i, v = 1, n
  while v >= 1024 and i < #units do v = v / 1024; i = i + 1 end
  if i == 1 then return string.format("%d B", v) end
  return string.format("%.1f %s", v, units[i])
end

local function plural(n, word, many)
  return string.format("%d %s", n, n == 1 and word or (many or (word .. "s")))
end

local function walk(dir, prefix, out)
  for _, name in ipairs(sys.listdir(dir) or {}) do
    local path = dir .. "/" .. name
    local kind = sys.stat(path)
    if kind == "dir" then walk(path, prefix .. name .. "/", out)
    elseif kind == "file" then out[#out + 1] = prefix .. name end
  end
  return out
end

-- ---- doctor -----------------------------------------------------------------
-- Deliberately read-only. Someone runs this *because* the program will not
-- start, so it must not depend on a healthy install and must not try to repair
-- one behind their back -- a repair that happens during a diagnosis is a
-- diagnosis you cannot trust. It opens its own connection to the store rather
-- than using bog.db, so it works whether or not boot got that far.
--
-- Returns (report_text, ok, problems) so the GUI can render it as well as the
-- CLI printing it. `ok` is false only when something is genuinely broken;
-- advisory findings come back as warnings inside the text.
function M.doctor()
  local L, problems, warnings = {}, {}, {}
  local function line(s) L[#L + 1] = s or "" end
  local function head(s) line(""); line(s); end
  local function kv(k, v) line(string.format("  %-12s %s", k, tostring(v))) end
  local function problem(s) problems[#problems + 1] = s end
  local function warn(s) warnings[#warnings + 1] = s end

  line("boggart " .. tostring(bog.version) .. " doctor")

  -- data directory ----------------------------------------------------------
  local p, perr = M.paths()
  head("data directory")
  if not p then
    kv("path", "(cannot resolve)")
    problem(perr)
    line("")
    line(perr)
    return table.concat(L, "\n"), false, problems
  end
  -- What the harness is actually using, which is bog.userdir. Normally that is
  -- what the policy chose; a test or the studio can repoint it, and a doctor
  -- that reported the policy's answer instead would be describing a directory
  -- nothing is reading.
  local data = bog.userdir or p.data
  local dbpath = data .. "/boggart.db"
  local overlay = data .. "/lua"
  kv("path", data)
  kv("chosen by", data == p.data and p.source or "bog.userdir, set at run time")
  local kind = sys.stat(data)
  if kind == "dir" then
    kv("exists", "yes")
    local probe = data .. "/.write-probe-" .. tostring(sys.pid())
    local f = io.open(probe, "wb")
    if f then
      f:close(); os.remove(probe)
      kv("writable", "yes")
    else
      kv("writable", "NO")
      problem(data .. " is not writable. Fix its permissions, or set BOGGART_HOME " ..
        "to a directory you own.")
    end
  elseif kind == nil then
    kv("exists", "no -- it will be created on the next run")
  else
    kv("exists", "NO -- that path is a " .. kind .. ", not a directory")
    problem(data .. " exists and is not a directory. Move it aside, or set " ..
      "BOGGART_HOME to a different path.")
  end
  local freeb, totalb = sys.diskfree(kind == "dir" and data or (p.home or "."))
  if freeb then
    kv("disk", human_bytes(freeb) .. " free of " .. human_bytes(totalb))
    -- 20 MB is not a threshold with theory behind it; it is roughly the point
    -- at which a WAL checkpoint of a working store starts failing.
    if freeb < 20 * 1024 * 1024 then
      problem("Only " .. human_bytes(freeb) .. " free on the volume holding " .. data ..
        ". SQLite will start failing writes; free some space.")
    end
  end
  if p.legacy and p.legacy ~= data and sys.stat(p.legacy) == "dir" then
    kv("note", "an older " .. p.legacy .. " also exists and is NOT being used")
    warn("Two data directories exist: " .. data .. " (in use) and " .. p.legacy ..
      ". Set BOGGART_HOME=" .. p.legacy .. " to go back to the older one.")
  end

  -- database ----------------------------------------------------------------
  head("database")
  kv("path", dbpath)
  local dbkind, _, dbsize = sys.stat(dbpath)
  if dbkind ~= "file" then
    kv("present", "no -- it will be created on the next run")
  else
    local total = dbsize or 0
    for _, sfx in ipairs({ "-wal", "-shm" }) do
      local k, _, sz = sys.stat(dbpath .. sfx)
      if k == "file" then total = total + (sz or 0) end
    end
    kv("size", human_bytes(dbsize) .. " (" .. human_bytes(total) .. " including wal/shm)")
    local conn, oerr = db.open(dbpath)
    if not conn then
      kv("opens", "NO -- " .. tostring(oerr))
      problem("The store at " .. dbpath .. " cannot be opened: " .. tostring(oerr) ..
        ". Check the permissions on the file and its directory.")
    else
      local rows, qerr = conn:query("PRAGMA integrity_check")
      local verdict = rows and rows[1] and (rows[1].integrity_check or rows[1][1])
      if verdict == "ok" then
        kv("integrity", "ok")
      else
        kv("integrity", "FAILED -- " .. tostring(verdict or qerr))
        problem("The store at " .. dbpath .. " is damaged. Starting boggart will move it " ..
          "aside and create a fresh one; sessions and memory in it will be lost. " ..
          "Nothing is deleted -- the damaged file is kept.")
      end
      local want = bog.store and bog.store.SCHEMA_VERSION or 2
      local sv = bog.store and bog.store.schema_version(conn)
      if sv then
        if sv > want then
          kv("schema", "version " .. sv .. " -- NEWER than this build understands (" .. want .. ")")
          problem("The store was written by a newer boggart (schema " .. sv .. "; this " ..
            "build knows " .. want .. "). Upgrade boggart, or point BOGGART_HOME at a " ..
            "different directory. It will not be opened as it is.")
        else
          kv("schema", "version " .. sv .. " (this build: " .. want .. ")")
        end
      else
        kv("schema", "not recorded yet (pre-schema_version store, or brand new)")
      end
      local function count(sql)
        local r = conn:query(sql)
        return (r and r[1] and (r[1].n or r[1][1])) or 0
      end
      if verdict == "ok" then
        kv("contents", table.concat({
          plural(count("SELECT count(*) AS n FROM sessions"), "session"),
          plural(count("SELECT count(*) AS n FROM memory"), "memory", "memories"),
          plural(count("SELECT count(*) AS n FROM journal"), "journal row"),
          plural(count("SELECT count(*) AS n FROM tools"), "recorded tool"),
        }, ", "))
        local jm = conn:query("PRAGMA journal_mode")
        kv("journal", (jm and jm[1] and (jm[1].journal_mode or jm[1][1])) or "?")
      end
      conn:close()
    end
  end
  -- Quarantined stores from an earlier repair. Reported rather than cleaned:
  -- they are the user's data, and only they can say when it stops mattering.
  local quarantined = {}
  for _, name in ipairs(sys.listdir(data) or {}) do
    if name:match("^boggart%.db%.corrupt%-") and not name:match("%-wal$") and not name:match("%-shm$") then
      quarantined[#quarantined + 1] = name
    end
  end
  if #quarantined > 0 then
    table.sort(quarantined)
    kv("quarantined", plural(#quarantined, "damaged store") .. " kept from earlier repairs:")
    for i = 1, math.min(#quarantined, 5) do line("               " .. quarantined[i]) end
    if #quarantined > 5 then
      line(string.format("               ... and %d more", #quarantined - 5))
    end
    warn(plural(#quarantined, "damaged store file") .. " still occupying space in " ..
      data .. ". Delete them yourself once you are sure you do not want them.")
  end

  -- credentials --------------------------------------------------------------
  head("credentials")
  local apath = auth.path()
  local akind, _, _, amode = sys.stat(apath)
  kv("file", apath .. (akind == "file"
    and string.format("  (mode %04o)", amode or 0) or "  (not created yet)"))
  if akind == "file" and amode and (amode & 0x3F) ~= 0 then
    -- Any group or other bit set on a file holding an API key.
    warn("The credential file " .. apath .. string.format(" is mode %04o.", amode) ..
      " It should be 0600; run `chmod 600 " .. apath .. "`.")
  end
  -- Credentials are per provider now, and so is this: reporting "the key"
  -- when there are several would answer a question nobody asked. The provider
  -- is derived from the endpoint, so this is the key that would actually be
  -- sent by the next request.
  local masked, source, provider = auth.masked()
  kv("provider", tostring(provider) .. "  (from the endpoint)")
  if masked == "(unset)" then
    kv("api key", "not set for " .. tostring(provider))
  elseif source and source ~= "stored" then
    kv("api key", masked .. "  from " .. source .. " in the environment")
    -- The confusion this exists to end: the environment silently wins, so a
    -- key set with /auth appears to be ignored.
    line("               this OVERRIDES anything stored in the file above")
  else
    kv("api key", masked .. "  from " .. apath)
  end
  -- Keys for other providers, named but never shown: "I set that key, where
  -- did it go" is otherwise unanswerable once more than one exists.
  local others = {}
  for _, name in ipairs({ "anthropic", "deepseek", "local", "custom" }) do
    if name ~= provider then
      local m2 = auth.masked(name)
      if m2 ~= "(unset)" then others[#others + 1] = name end
    end
  end
  if #others > 0 then
    kv("other keys", table.concat(others, ", ") .. "  (not in use here)")
  end
  local base = auth.base_url()
  local envbase = os.getenv("ANTHROPIC_BASE_URL")
  kv("endpoint", (bog.api and bog.api.endpoint() or (base or "https://api.anthropic.com/v1/messages"))
    .. (envbase and "  from ANTHROPIC_BASE_URL" or (base and "  from " .. apath or "  (default)")))
  kv("model", (auth.model() or bog.session.model) ..
    (auth.model() and "  from " .. apath or "  (default)"))
  if masked == "(unset)" and not base then
    problem("No credentials and no endpoint: boggart cannot reach a model at all.\n" ..
      "  Set one with `/auth key sk-ant-...`, or export ANTHROPIC_API_KEY,\n" ..
      "  or point it at a local server with `/auth url http://127.0.0.1:8000`.")
  end
  if source and source ~= "stored" and akind == "file" then
    warn(source .. " is set, so the key stored in " .. apath
      .. " is not being used for " .. tostring(provider) .. ".")
  end

  -- mcp ----------------------------------------------------------------------
  head("mcp servers")
  local okreq, servers = pcall(require, "mcp_servers")
  if not okreq or type(servers) ~= "table" or #servers == 0 then
    kv("configured", "none  (" .. overlay .. "/mcp_servers.lua)")
  else
    kv("configured", #servers)
    for _, spec in ipairs(servers) do
      local name = type(spec) == "table" and tostring(spec.name) or "(malformed entry)"
      local connected = bog.mcphost and bog.mcphost.conns[name]
      if connected then
        line(string.format("  %-12s connected, %d tools  [%s]", name,
          #((bog.mcphost.tools or {})[name] or {}), bog.mcphost.generation(name)))
      else
        -- Actually connect: "configured" and "working" are different facts and
        -- the second one is why anybody runs this. It does spawn the server.
        -- Called on its own line rather than behind an `and`, which would
        -- truncate the (nil, err) pair to nil and lose the reason.
        local names, err
        if bog.mcphost then names, err = bog.mcphost.add(spec)
        else err = "the MCP host is not loaded" end
        if names then
          line(string.format("  %-12s connects, %d tools", name, #names))
        else
          line(string.format("  %-12s FAILS: %s", name, tostring(err)))
          problem("MCP server '" .. name .. "' is configured but will not connect: " ..
            tostring(err) .. ".\n  Fix or remove it in " .. overlay .. "/mcp_servers.lua.")
        end
      end
    end
  end

  -- overlays -----------------------------------------------------------------
  head("overlay files")
  if sys.stat(overlay) ~= "dir" then
    kv("files", "none  (" .. overlay .. " does not exist)")
  else
    local builtin = {}
    for _, name in ipairs(boggart.embedded_names()) do builtin[name] = true end
    local files, shadows = walk(overlay, "", {}), {}
    for _, rel in ipairs(files) do
      local mod = rel:gsub("%.lua$", "")
      if builtin[mod] then shadows[#shadows + 1] = mod end
    end
    kv("files", plural(#files, "file") .. " under " .. overlay)
    if #shadows > 0 then
      table.sort(shadows)
      kv("shadowing", plural(#shadows, "built-in module") ..
        " -- these are used instead of the baked-in copy:")
      -- Capped: after `boggart init` every module is overlaid, and seventy-six
      -- lines of list is not a diagnosis, it is a haystack.
      local SHOWN = 12
      for i = 1, math.min(#shadows, SHOWN) do line("               " .. shadows[i]) end
      if #shadows > SHOWN then
        line(string.format("               ... and %d more", #shadows - SHOWN))
      end
      -- Not a problem: shadowing is the entire point of the overlay. It is a
      -- warning because a stale overlay of a module that has since changed in
      -- the binary is the most confusing failure this program has.
      warn(plural(#shadows, "built-in module") .. " overridden by files in " .. overlay ..
        ".\n  If boggart misbehaves after an upgrade, `boggart --reset` drops them.")
    end
  end

  -- skills -------------------------------------------------------------------
  head("skills")
  local trust = (bog.skill_trust == "full") and "full" or "sandboxed"
  kv("code trust", trust .. (trust == "full"
    and "  (model-authored skill code runs with FULL io/os/network)"
    or "  (model-authored skill code is sandboxed + budgeted)"))
  local nskills, nprov = 0, 0
  local oks, sk = pcall(require, "skills")
  if oks and sk and sk.list then
    for _, r in ipairs(sk.list()) do
      nskills = nskills + 1
      local s = sk.load(r.name)
      if s and type(s.provides) == "table" then nprov = nprov + #s.provides end
    end
  end
  kv("available", plural(nskills, "skill") .. ", " .. plural(nprov, "provided tool"))
  if trust == "full" then
    warn("skill code trust is FULL: any Lua the model writes into a skill runs with full "
      .. "authority. `/trust sandboxed` (or unset BOGGART_SKILL_TRUST) to sandbox it.")
  end

  -- verdict ------------------------------------------------------------------
  local function numbered(i, s)
    -- Continuation lines line up under the text, not under the number.
    line("  " .. i .. ". " .. tostring(s):gsub("\n%s*", "\n     "))
  end
  head(#problems == 0 and "verdict" or "problems")
  if #problems == 0 then
    line("  Everything checks out.")
  end
  for i, s in ipairs(problems) do numbered(i, s) end
  if #warnings > 0 then
    head("worth knowing")
    for i, s in ipairs(warnings) do numbered(i, s) end
  end
  line("")
  return table.concat(L, "\n"), #problems == 0, problems
end

-- CLI entry: `boggart doctor`. Non-zero exit when something is actually
-- broken, so a script can gate on it.
function M.main()
  local text, ok = M.doctor()
  io.write(text)
  io.flush()
  return ok and 0 or 1
end

return M
