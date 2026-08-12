-- libraryview.lua -- the Library: everything the agent has learned to do.
--
-- boggart accumulates capability in four places and shows none of it. Tools it
-- wrote for itself live in ~/.boggart (per scope, with provenance and a
-- staleness hint), skills are bundles of tool grants, memory is a SQLite table
-- with an FTS5 index over it, and MCP servers contribute more tools still.
-- Every one of those is reachable today only by knowing a command name and
-- reading a wall of text in the log. That is a poor deal for the person whose
-- machine this is running on: the interesting question about a self-modifying
-- agent is "what has it done to itself", and the answer should be a screen.
--
-- So this is a browser over the registries that already exist -- it defines no
-- storage of its own. bog.tools.registry is the tool list, bog.store.tool_stats
-- is the provenance, bog.tools.stale_note is the staleness verdict,
-- bog.store.mem_search is the FTS5 query, bog.mcphost.list is the server list.
-- If this view and `tools`/`recall`/`mcp` ever disagree, this view is wrong.
--
-- Shape: a section selector, a search box, a list, and a detail pane. Flat
-- rectangles and text, because that is all this renderer draws.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local widgets = require "core.widgets"

local LibraryView = View:extend()

local SECTIONS = { "tools", "skills", "memory", "mcp" }
local LABEL = {
  tools = "Tools", skills = "Skills", memory = "Memory", mcp = "MCP",
}

-- What each section is, said once. This is the signpost the owner could not find
-- -- particularly for skills, which are always present but were never explained.
-- Drawn as a fixed banner under the tabs, so every section teaches what it holds
-- and how one comes to exist. ASCII only: the bundled monospace font draws these,
-- and a stray glyph outside Latin renders as an empty box in the chrome.
local EXPLAIN = {
  tools =
    "A tool is a small Lua function the agent wrote for itself with define_tool: "
    .. "code it can call to get the same answer every time, with a scope and "
    .. "provenance. Ask the agent to build one and it appears here.",
  skills =
    "A skill is a named bundle of instructions plus the tools an agent is allowed "
    .. "to use -- the thing that scopes what a swarm agent can do. Seven ship built "
    .. "in; overlay your own under ~/.boggart/lua/skills/.",
  memory =
    "Memory is what the agent keeps across sessions: durable facts it saves with "
    .. "`remember` and searches with `recall`. Tell it something worth keeping and "
    .. "it lands here.",
  mcp =
    "MCP servers are external tool servers the agent connects to; each contributes "
    .. "its tools as mcp__<server>__<tool>. Declare them in "
    .. "~/.boggart/lua/mcp_servers.lua -- none are connected until you add one.",
}

-- How long a snapshot is trusted. The data behind this view is SQLite queries
-- and directory scans; update() runs ~60 times a second and must return
-- immediately, so nothing here is read per frame. Three seconds is short enough
-- that a tool the agent defines while you are looking at the screen shows up on
-- its own, and long enough that the database is not being asked the same
-- question sixty times a second for a list that changes once an hour.
local REFRESH_SECS = 3

local MAX_SOURCE_ROWS = 400   -- a tool body longer than this is pathological

-- Paths are the longest thing on this screen and the home prefix is the least
-- informative part of them.
local HOME = (sys and sys.home and sys.home()) or ""
local function short_path(p)
  p = tostring(p)
  if HOME ~= "" and p:sub(1, #HOME) == HOME then return "~" .. p:sub(#HOME + 1) end
  return p
end

-- ---------------------------------------------------------------------------
-- Reading the registries
-- ---------------------------------------------------------------------------

-- A tool's scope tag, kept to four characters so the list column stays narrow.
local SCOPE_TAG = {
  session = "sess", project = "proj", ["global"] = "glob",
}

-- `may_block` is true only when a person asked for this -- opening the view, or
-- pressing Refresh -- and never on the three-second timer or from a draw.
-- project_root() and stale_note() shell out to git; on the main thread that
-- froze the first paint of the view for as long as git took, and the pcall is
-- no protection because pcall in Lua 5.5 is yieldable.
local function tool_entries(may_block)
  local out = {}
  local reg = (bog and bog.tools and bog.tools.registry) or {}

  -- Provenance and usage come from the tools table, keyed by (name, scope):
  -- tool_stats already returns the rows for this project plus the global ones.
  local stats, root = {}, ""
  pcall(function()
    root = (may_block and bog.tools.project_root()
            or bog.tools.project_root_cached()) or ""
  end)
  if bog.store and bog.store.tool_stats then
    local ok, rows = pcall(bog.store.tool_stats, root)
    if ok then
      for _, r in ipairs(rows) do stats[r.name .. "\0" .. r.scope] = r end
    end
  end

  for name, d in pairs(reg) do
    local kind = (d.body and "generated") or (d.mcp and "mcp") or "built-in"
    local e = {
      key = name, name = name, def = d, kind = kind,
      scope = d.scope, sub = d.description or "",
      stat = stats[name .. "\0" .. tostring(d.scope)],
    }
    -- Staleness is asked of tools.lua rather than recomputed here: it is a
    -- judgement about procedural memory, and two copies of it would drift.
    if d.body and d.scope == "project" and may_block then
      local ok, note = pcall(bog.tools.stale_note, name, d)
      e.stale = ok and note or nil
    end
    out[#out + 1] = e
  end

  -- Generated tools first: they are what this screen exists to show. Built-ins
  -- next, then the MCP surface, which is usually the longest and the least
  -- surprising.
  local rank = { generated = 1, ["built-in"] = 2, mcp = 3 }
  table.sort(out, function(a, b)
    if rank[a.kind] ~= rank[b.kind] then return rank[a.kind] < rank[b.kind] end
    return a.name < b.name
  end)
  return out
end

local function skills_module()
  if bog and bog.skills then return bog.skills end
  local ok, mod = pcall(require, "skills")
  return ok and mod or nil
end

-- Skills are Lua modules, baked into the binary and overlayable under
-- ~/.boggart/lua/skills/. There is no registry to ask, so the names come from
-- both places and the module itself is loaded through skills.load.
local function skill_entries()
  local origin = {}
  if boggart and boggart.embedded_names then
    for _, n in ipairs(boggart.embedded_names()) do
      local s = n:match("^skills/([%w_%-]+)$")
      if s then origin[s] = "built-in" end
    end
  end
  local dir = (bog and bog.userdir or "") .. "/lua/skills"
  if sys.stat(dir) == "dir" then
    for _, f in ipairs(sys.listdir(dir) or {}) do
      local s = f:match("^([%w_%-]+)%.lua$")
      -- An overlay file of the same name is what require() actually loads, so
      -- say so: "built-in" would be a lie about the code that is running.
      if s then origin[s] = origin[s] and "overridden" or "user" end
    end
  end

  local skills = skills_module()
  local out = {}
  for name, from in pairs(origin) do
    local mod = skills and skills.load(name) or nil
    out[#out + 1] = {
      key = name, name = name, origin = from,
      description = (mod and (mod.description or "(no description)"))
                    or "(will not load)",
      instructions = mod and mod.instructions or "",
      tools = (mod and mod.tools) or {},
      sub = (mod and mod.description) or "",
    }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function memory_entries(query)
  if not (bog and bog.store and bog.store.mem_search) then return {} end
  -- mem_search is the same call recall() makes: FTS5 when the query has word
  -- tokens, a LIKE fallback when it does not, everything when it is empty.
  local ok, rows = pcall(bog.store.mem_search, query or "")
  if not ok then return {} end
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = { key = r.title, title = r.title, body = r.body or "",
                      sub = r.body or "" }
  end
  return out
end

local function mcp_entries()
  if not (bog and bog.mcphost) then return {} end
  local ok, servers = pcall(bog.mcphost.list)
  if not ok then return {} end
  local out = {}
  for _, s in ipairs(servers) do
    out[#out + 1] = { key = s.server, server = s.server, tools = s.tools or {},
                      sub = table.concat(s.tools or {}, " ") }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The view
-- ---------------------------------------------------------------------------

function LibraryView:new()
  LibraryView.super.new(self)
  self.scrollable = true
  self.section = "tools"
  self.query = ""        -- what is in the search box
  self.committed = ""    -- the query the memory search actually ran with
  self.searching = false
  self.sel = {}          -- section -> selected key, so going back returns you
  self.hits = {}
  self.data = { tools = {}, skills = {}, memory = {}, mcp = {} }
  self.rev = 0           -- bumped on every refresh; invalidates layout caches
  self.last_refresh = 0
  self.confirm = nil     -- a delete waiting for its second, explicit click
  self.notice = nil
  self:refresh(true)
end

function LibraryView:get_name() return "Library" end

function LibraryView:get_scrollable_size()
  return self.content_height or math.huge
end

function LibraryView:refresh(force)
  local now = os.time()
  if not force and now - self.last_refresh < REFRESH_SECS then return end
  self.last_refresh = now
  self.data = {
    tools = tool_entries(force),
    skills = skill_entries(),
    memory = memory_entries(self.committed),
    mcp = mcp_entries(),
  }
  self.rev = self.rev + 1
  core.redraw = true
end

function LibraryView:update()
  -- Only while this view has the keyboard. lite updates every view in a node,
  -- including the tabs behind the visible one, so without this a Library left
  -- open in a background tab would keep querying the database forever for a
  -- screen nobody is looking at. Coming back to it refreshes on the first
  -- frame, because the timer below is already expired by then.
  if core.active_view == self then self:refresh() end
  LibraryView.super.update(self)
end

function LibraryView:set_section(s)
  if self.section == s then return end
  self.section = s
  self.confirm = nil
  -- The notice belongs to the thing you just did, not the session; it was only
  -- ever set and never cleared, so a deletion banner stayed up for good and
  -- cost a row of the list below it for good too.
  self.notice = nil
  self.scroll.to.y = 0
  -- The query does not follow you between sections. It filters different
  -- things in each one, and a leftover query silently rendering an empty list
  -- reads as "there are no skills", which would be a lie.
  if self.query ~= "" or self.committed ~= "" then
    self.query, self.committed = "", ""
    if s == "memory" then self:refresh(true) end
  end
  core.redraw = true
end

function LibraryView:select(key)
  self.sel[self.section] = key
  self.confirm = nil
  core.redraw = true
end

-- The filtered list, cached against (section, query, rev): rebuilding it is a
-- string scan over every memory body, and doing that per frame is the waste
-- this whole file is careful about.
function LibraryView:list()
  local key = self.section .. "\0" .. self.query .. "\0" .. self.rev
  local c = self._items
  if not (c and c.key == key) then
    local src = self.data[self.section] or {}
    local out = {}
    local q = self.query:lower()
    -- Memory is filtered by SQLite, not here: the committed query already ran
    -- through FTS5, and a second substring pass would quietly drop the rows
    -- FTS matched on a stem rather than a literal.
    if q == "" or self.section == "memory" then
      for _, e in ipairs(src) do out[#out + 1] = e end
    else
      for _, e in ipairs(src) do
        if e.key:lower():find(q, 1, true) or (e.sub or ""):lower():find(q, 1, true) then
          out[#out + 1] = e
        end
      end
    end
    c = { key = key, list = out }
    self._items = c
  end
  -- Something is always selected, so the detail pane is never blank for want
  -- of a click.
  local sel = self.sel[self.section]
  local found = false
  for _, e in ipairs(c.list) do if e.key == sel then found = true; break end end
  if not found then self.sel[self.section] = c.list[1] and c.list[1].key or nil end
  return c.list
end

function LibraryView:selected()
  local sel = self.sel[self.section]
  for _, e in ipairs(self:list()) do if e.key == sel then return e end end
  return nil
end

-- ---------------------------------------------------------------------------
-- Search box
-- ---------------------------------------------------------------------------

function LibraryView:on_text_input(text)
  self.searching = true
  self.query = self.query .. text
  -- Typing filters tools, skills and servers immediately -- that is a table
  -- scan over a few hundred strings. Memory waits for enter, because it is a
  -- database query and running one per keystroke is how a UI starts to stutter.
  core.redraw = true
end

function LibraryView:commit_search()
  self.committed = self.query
  self.searching = false
  if self.section == "memory" then self:refresh(true) end
  core.redraw = true
end

function LibraryView:cancel_search()
  if self.query ~= "" or self.committed ~= "" then
    self.query, self.committed = "", ""
    if self.section == "memory" then self:refresh(true) end
  end
  self.searching = false
  core.redraw = true
end

function LibraryView:backspace()
  -- By character, not by byte: one backspace over a non-ASCII character used to
  -- leave a dangling continuation byte, drawn and handed to SQLite as a term.
  local i = #self.query
  while i > 1 and common.is_utf8_cont(self.query:sub(i, i)) do i = i - 1 end
  self.query = self.query:sub(1, i - 1)
  core.redraw = true
end

-- ---------------------------------------------------------------------------
-- Deleting a generated tool
-- ---------------------------------------------------------------------------
--
-- Two clicks, and the scope is in the label of both of them. Deleting a session
-- tool costs nothing, deleting a global one removes a capability from every
-- project on the machine, and a UI that renders those as the same button is
-- lying about what the second one does.

-- Called from draw(), so it must not discover the project root: tools_dir
-- ("project") calls project_root(), and a git rev-parse reachable from a
-- repaint is a frozen window. A project tool can only have been loaded through
-- the same tools_dir, so by now the root is cached; if not, say so.
function LibraryView:tool_path(e)
  if not (e.def and e.def.body) or not e.scope or e.scope == "session" then return nil end
  if e.scope == "project" and not bog.tools.project_root_cached() then return nil end
  local ok, dir = pcall(bog.tools.tools_dir, e.scope)
  if not ok or not dir then return nil end
  return dir .. "/" .. e.name .. ".lua"
end

function LibraryView:delete_tool(e)
  if not (e and e.def and e.def.body) then return end
  -- Where it sat, so the selection lands on its neighbour rather than the top
  -- of the list.
  local at
  for i, x in ipairs(self:list()) do if x.key == e.key then at = i; break end end
  local path = self:tool_path(e)
  if path then
    local ok, err = os.remove(path)
    if not ok and sys.stat(path) == "file" then
      self.notice = { text = "could not delete " .. path .. ": " .. tostring(err),
                      bad = true }
      self.confirm = nil
      return
    end
    self.notice = { text = string.format("deleted the %s tool '%s' (%s)",
                                         e.scope, e.name, short_path(path)) }
  else
    self.notice = { text = string.format("dropped the session tool '%s'", e.name) }
  end
  bog.tools.registry[e.name] = nil
  -- The provenance row goes with it. Those counts describe a procedure that no
  -- longer exists, and leaving them behind would silently attach this tool's
  -- history to the next tool that happens to take the name.
  if bog.store and bog.store.tool_forget then
    pcall(bog.store.tool_forget, e.name, e.scope or "global", e.def.project or "")
  end
  self.confirm = nil
  self.sel[self.section] = nil
  self:refresh(true)
  if at then
    local list = self:list()
    local pick = list[math.min(at, #list)]
    self.sel[self.section] = pick and pick.key or nil
  end
end

-- ---------------------------------------------------------------------------
-- Detail layout
-- ---------------------------------------------------------------------------
--
-- A row is a list of { colour, text } segments, drawn left to right. Rows are
-- built once per (section, selection, width, revision) and cached: the detail
-- pane can hold a whole tool body, and re-wrapping it sixty times a second for
-- a pane that changes when you click is exactly the cost worth avoiding.

local function seg(color, text) return { { color, text } } end

local function blank(out) out[#out + 1] = seg(style.text, "") end

local FIELD_W = 11

-- A labelled line. The value wraps under itself rather than running off the
-- pane: the values here are paths and provenance, and a path clipped by the
-- window edge is the one that was worth reading.
local function field(out, cols, label, value, color)
  local room = math.max(12, cols - FIELD_W)
  local text = tostring(value)
  local first = true
  local function emit(chunk)
    out[#out + 1] = {
      { style.dim, first and string.format("%-" .. FIELD_W .. "s", label)
        or string.rep(" ", FIELD_W) },
      { color or style.text, chunk },
    }
    first = false
  end
  while #text > room do
    local cut = room
    local sp = text:sub(1, room + 1):match("^.*()%s")
    if sp and sp > room / 2 then cut = sp - 1 end
    emit(text:sub(1, cut))
    text = text:sub(cut + 1):gsub("^%s+", "")
  end
  emit(text)
end

-- Wrap `text` into rows of at most `cols` characters. `hard` breaks anywhere,
-- which is what source code wants; otherwise the break prefers a space.
local function wrap(out, text, color, cols, hard)
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    local s = line:gsub("\t", "  ")
    while #s > cols do
      local cut = cols
      if not hard then
        local sp = s:sub(1, cols + 1):match("^.*()%s")
        if sp and sp > cols / 2 then cut = sp - 1 end
      end
      out[#out + 1] = seg(color, s:sub(1, cut))
      s = s:sub(cut + 1)
      if not hard then s = s:gsub("^%s+", "") end
    end
    out[#out + 1] = seg(color, s)
  end
end

local function when(ts)
  if not ts or ts == 0 then return "unknown" end
  return os.date("%Y-%m-%d %H:%M", ts)
end

function LibraryView:tool_detail(e, cols, head, body)
  field(head, cols, "tool", e.name, style.accent)
  field(head, cols, "kind", e.kind == "generated" and "generated by the agent"
    or (e.kind == "mcp" and ("from the MCP server '" .. (e.def.mcp and e.def.mcp.server or "?") .. "'"))
    or "built in to the harness")
  if e.kind == "generated" then
    local path = self:tool_path(e)
    field(head, cols, "scope", e.scope or "?", style.keyword)
    if e.scope == "session" then
      field(head, cols, "stored", "nowhere -- it dies with this process", style.dim)
    elseif e.scope == "global" then
      field(head, cols, "stored", short_path(path or "?"), style.dim)
      field(head, cols, "reach", "every project on this machine", style.warn)
    else
      field(head, cols, "stored", short_path(path or "?"), style.dim)
      field(head, cols, "project", e.def.project or "?", style.dim)
    end

    local st = e.stat
    if st then
      field(head, cols, "defined", string.format("%s%s%s", when(st.created),
        st.created_session and (" by session " .. st.created_session) or "",
        st.version and (", boggart " .. st.version) or ""))
      if st.git_rev then field(head, cols, "git rev", st.git_rev) end
      local calls = st.calls or 0
      field(head, cols, "used", string.format("%d call%s, %d failure%s%s",
        calls, calls == 1 and "" or "s", st.failures or 0,
        (st.failures or 0) == 1 and "" or "s",
        calls > 0 and string.format(", %.1f ms average", (st.total_ms or 0) / calls) or ""))
      if st.last_used then field(head, cols, "last used", when(st.last_used)) end
    else
      field(head, cols, "defined", "no provenance recorded", style.dim)
    end
    if e.stale then
      blank(head)
      wrap(head, "stale: " .. e.stale, style.warn, cols)
    end
  end

  blank(body)
  wrap(body, e.def.description or "(no description)", style.text, cols)

  if e.def.body then
    blank(body)
    body[#body + 1] = seg(style.dim, "-- source --")
    local rows = {}
    wrap(rows, e.def.body, style.inline_code or style.text, cols, true)
    for i, r in ipairs(rows) do
      if i > MAX_SOURCE_ROWS then
        body[#body + 1] = seg(style.dim, string.format("... %d more lines",
          #rows - MAX_SOURCE_ROWS))
        break
      end
      body[#body + 1] = r
    end
  end
end

function LibraryView:skill_detail(e, cols, head, body)
  field(head, cols, "skill", e.name, style.accent)
  field(head, cols, "source", e.origin == "overridden"
    and "overridden by ~/.boggart/lua/skills/" .. e.name .. ".lua"
    or (e.origin == "user" and ("~/.boggart/lua/skills/" .. e.name .. ".lua")
        or "built in"))
  field(head, cols, "grants", string.format("%d tool pattern%s",
    #e.tools, #e.tools == 1 and "" or "s"))
  blank(head)
  wrap(head, e.description or "", style.text, cols)

  blank(body)
  body[#body + 1] = seg(style.dim, "-- tools granted --")
  local reg = (bog and bog.tools and bog.tools.registry) or {}
  for _, pat in ipairs(e.tools) do
    -- A skill's allowlist is patterns, not names: "mcp__github__*" grants
    -- whatever that server happens to expose today, so the count is the honest
    -- thing to show next to it.
    if pat:sub(-1) == "*" then
      local n, pre = 0, pat:sub(1, #pat - 1)
      for name in pairs(reg) do
        if name:sub(1, #pre) == pre then n = n + 1 end
      end
      body[#body + 1] = {
        { style.keyword, pat },
        { style.dim, string.format("   (%d matching tool%s now)", n, n == 1 and "" or "s") },
      }
    else
      -- Some grants name tools that only exist in a particular mode. The swarm
      -- messaging and orchestration tools (send/publish/subscribe/inbox/spawn/
      -- await/threads) are registered when swarm mode starts, so a skill that
      -- grants them looks broken in a plain window when it is not -- the tool
      -- is real, it just is not loaded right now.
      local SWARM_ONLY = {
        send = true, publish = true, subscribe = true, inbox = true,
        spawn = true, await = true, threads = true,
      }
      local d = reg[pat]
      local desc = SWARM_ONLY[pat] and "   (swarm tool -- loaded in swarm mode)"
        or "   (no such tool)"
      local colour = d and style.text or (SWARM_ONLY[pat] and style.dim or style.error)
      if d then
        local room = math.max(0, cols - #pat - 3)
        desc = d.description or ""
        if #desc > room then desc = desc:sub(1, math.max(0, room - 3)) .. "..." end
        desc = "   " .. desc
      end
      body[#body + 1] = {
        { colour, pat },
        { style.dim, desc },
      }
    end
  end

  if e.instructions ~= "" then
    blank(body)
    body[#body + 1] = seg(style.dim, "-- instructions --")
    wrap(body, e.instructions, style.text, cols)
  end
end

function LibraryView:memory_detail(e, cols, head, body)
  field(head, cols, "memory", e.title, style.accent)
  field(head, cols, "size", string.format("%d bytes", #e.body))
  blank(body)
  wrap(body, e.body, style.text, cols)
end

function LibraryView:mcp_detail(e, cols, head, body)
  field(head, cols, "server", e.server, style.accent)
  field(head, cols, "tools", tostring(#e.tools))
  blank(head)
  wrap(head, "Declared in ~/.boggart/lua/mcp_servers.lua and registered as "
    .. "ordinary tools, so skills can grant the whole server with mcp__"
    .. e.server .. "__*.", style.dim, cols)

  local reg = (bog and bog.tools and bog.tools.registry) or {}
  blank(body)
  for _, name in ipairs(e.tools) do
    local d = reg[name]
    body[#body + 1] = seg(style.keyword, name)
    if d and d.description then
      wrap(body, (d.description:gsub("^%[[^%]]*%]%s*", "")), style.dim, cols)
    end
  end
end

function LibraryView:detail(cols)
  local e = self:selected()
  local key = string.format("%s\0%s\0%d\0%d", self.section,
    tostring(self.sel[self.section]), cols, self.rev)
  local c = self._detail
  if c and c.key == key then return c.head, c.body end

  local head, body = {}, {}
  if not e then
    head[#head + 1] = seg(style.dim, "nothing here yet")
  elseif self.section == "tools" then
    self:tool_detail(e, cols, head, body)
  elseif self.section == "skills" then
    self:skill_detail(e, cols, head, body)
  elseif self.section == "memory" then
    self:memory_detail(e, cols, head, body)
  else
    self:mcp_detail(e, cols, head, body)
  end
  self._detail = { key = key, head = head, body = body }
  return head, body
end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------
--
-- Hit rects are rebuilt by draw() every frame and tested here, the same
-- arrangement the agent panel uses: one layout, so the two cannot drift.

function LibraryView:on_mouse_moved(x, y, dx, dy)
  LibraryView.super.on_mouse_moved(self, x, y, dx, dy)
  self.mouse = { x = x, y = y }
  local item = widgets.hit(self.hits, x, y)
  local was = self.hover
  self.hover = item and item.id or nil
  if was ~= self.hover then core.redraw = true end
  self.cursor = "arrow"
end

function LibraryView:on_mouse_pressed(button, x, y, clicks)
  if LibraryView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  core.set_active_view(self)
  local item = widgets.hit(self.hits, x, y)
  -- Clicking outside the search box takes the keyboard back, so the next
  -- keystroke does not silently extend a query you have stopped thinking about.
  if not (item and item.id == "search") then self.searching = false end
  if item and item.action then item.action() end
  core.redraw = true
  return true
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

function LibraryView:draw()
  self:draw_background(style.background)
  local font = style.code_font
  local lh = font:get_height() * config.line_height
  local pad, vpad = style.padding.x, style.padding.y
  local charw = font:get_width("0")
  local voff = (lh - font:get_height()) / 2
  local bh = widgets.height(font)
  self.hits = {}

  local function add(hit, id, action)
    hit.item = { id = id, action = action }
    self.hits[#self.hits + 1] = hit
  end
  local function hovered(x, y, w, h)
    return self.mouse and widgets.inside({ x = x, y = y, w = w, h = h },
                                         self.mouse.x, self.mouse.y)
  end

  -- ---- header: sections, the search box, then the section signpost --------
  local top = self.position.y
  local x0 = self.position.x + pad
  local full = self.size.x - pad * 2

  -- The signpost for the current section, wrapped to the full width and computed
  -- before the header rect so the rect is tall enough to hold it. Fixed in the
  -- header rather than scrolled with the list, because "what is a skill" should
  -- not scroll away the moment you look at one.
  local ex_cols = math.max(20, math.floor(full / charw))
  local ex_rows = {}
  wrap(ex_rows, EXPLAIN[self.section] or "", style.dim, ex_cols)

  local header_h = bh * 2 + vpad * 4 + #ex_rows * lh + vpad / 2
  renderer.draw_rect(self.position.x, top, self.size.x, header_h, style.background2)
  renderer.draw_rect(self.position.x, top + header_h - 1, self.size.x, 1, style.divider)

  local tabs = {}
  for _, s in ipairs(SECTIONS) do
    tabs[#tabs + 1] = { label = string.format("%s (%d)", LABEL[s], #(self.data[s] or {})),
                        active = self.section == s, id = s }
  end
  -- Refresh is pinned right, so the tabs get an explicit limit: without one a
  -- narrow window laid the last tab under Refresh, and widgets.hit answers with
  -- whichever rect was registered first -- the tab -- so clicking Refresh
  -- changed section instead.
  local rl = "Refresh"
  local rw = widgets.width(font, rl)
  local rx = self.position.x + self.size.x - pad - rw
  for _, hit in ipairs(widgets.row(font, tabs, x0, top + vpad, self.mouse,
                                   rx - style.padding.x)) do
    local id = hit.item.id
    add(hit, id, function() self:set_section(id) end)
  end

  add(widgets.button(font, rl, rx, top + vpad,
        { w = rw, dim = true, hover = hovered(rx, top + vpad, rw, bh) }),
      "refresh", function() self:refresh(true) end)

  -- The search box. Typing anywhere in the view lands here, so it is focused by
  -- use rather than by ceremony; the border says whether it has the keyboard.
  local sy = top + vpad * 2 + bh
  local sh = bh
  renderer.draw_rect(x0, sy, full, sh, style.background)
  local border = self.searching and style.accent or style.divider
  renderer.draw_rect(x0, sy, full, 1, border)
  renderer.draw_rect(x0, sy + sh - 1, full, 1, border)
  renderer.draw_rect(x0, sy, 1, sh, border)
  renderer.draw_rect(x0 + full - 1, sy, 1, sh, border)
  local shown, scol = self.query, style.text
  if shown == "" and not self.searching then
    shown = (self.section == "memory")
      and "type to search memory, enter to run it (FTS5)"
      or  "type to filter"
    scol = style.dim
  elseif self.searching then
    shown = shown .. "|"
  end
  common.draw_text(font, scol, shown, "left", x0 + pad / 2, sy, full - pad, sh)
  add({ x = x0, y = sy, w = full, h = sh }, "search", function()
    self.searching = true
  end)

  -- The section signpost, drawn under the search box. Each row is a single
  -- coloured segment (see wrap), so one draw_text per line is enough.
  local ey = sy + sh + vpad / 4
  for _, r in ipairs(ex_rows) do
    common.draw_text(font, r[1][1], r[1][2], "left", x0, ey, full, lh)
    ey = ey + lh
  end

  -- ---- panes ---------------------------------------------------------------
  local body_top = top + header_h
  local body_bottom = self.position.y + self.size.y
  if self.notice then body_bottom = body_bottom - lh - vpad end

  local list_w = math.max(18 * charw, math.min(34 * charw, (self.size.x - pad * 3) * 0.36))
  local lx = self.position.x + pad
  local dx = lx + list_w + pad
  local dw = self.position.x + self.size.x - pad - dx
  local dcols = math.max(20, math.floor(dw / charw))
  renderer.draw_rect(dx - pad / 2, body_top, 1, body_bottom - body_top, style.divider)

  local function visible(yy) return yy + lh > body_top and yy < body_bottom end

  -- ---- the list ------------------------------------------------------------
  local list = self:list()
  local sel = self.sel[self.section]
  local y = body_top + vpad - self.scroll.y
  local list_chars = math.max(8, math.floor((list_w - pad) / charw))

  if #list == 0 then
    common.draw_text(font, style.dim, "(nothing)", "left", lx, y, list_w, lh)
    y = y + lh
  end
  for i, e in ipairs(list) do
    if visible(y) then
      local is_sel = (e.key == sel)
      if is_sel then
        renderer.draw_rect(lx, y, list_w, lh, style.selection)
      elseif hovered(lx, y, list_w, lh) then
        renderer.draw_rect(lx, y, list_w, lh, style.line_highlight)
      end

      -- Right-hand tag: the one fact that distinguishes entries of a kind.
      local tag = ""
      if self.section == "tools" then
        tag = e.stale and "stale" or (SCOPE_TAG[e.scope] or (e.kind == "mcp" and "mcp") or "core")
      elseif self.section == "skills" then
        tag = (e.origin == "built-in") and "" or e.origin
      elseif self.section == "mcp" then
        tag = tostring(#e.tools)
      end

      local label = e.key
      local room = list_chars - (#tag > 0 and (#tag + 1) or 0)
      if #label > room then label = label:sub(1, math.max(1, room - 1)) .. "~" end

      local col = style.text
      if self.section == "tools" then
        if e.stale then col = style.warn
        elseif e.kind == "built-in" then col = style.dim
        elseif e.kind == "mcp" then col = style.keyword end
      end
      common.draw_text(font, is_sel and style.accent or col, label, "left",
        lx + pad / 4, y, list_w, lh)
      if tag ~= "" then
        common.draw_text(font, e.stale and style.warn or style.dim, tag, "right",
          lx, y, list_w - pad / 2, lh)
      end
      add({ x = lx, y = y, w = list_w, h = lh }, "row" .. i,
          function() self:select(e.key) end)
    end
    y = y + lh
  end
  local list_bottom = y

  -- ---- the detail ----------------------------------------------------------
  local head, body = self:detail(dcols)
  local dy = body_top + vpad - self.scroll.y

  local function draw_rows(rows, yy)
    for _, row in ipairs(rows) do
      if visible(yy) then
        local tx = dx
        for _, s in ipairs(row) do
          tx = renderer.draw_text(font, s[2], tx, yy + voff, s[1])
        end
      end
      yy = yy + lh
    end
    return yy
  end

  dy = draw_rows(head, dy)

  -- Actions sit between the header and the body, high enough that deleting a
  -- tool never means scrolling past its own source to find the button.
  local e = self:selected()
  if e and self.section == "tools" and e.kind == "generated" then
    dy = dy + vpad
    local scope = e.scope or "global"
    local path = self:tool_path(e)
    if self.confirm == e.name then
      -- The confirmation names the scope and the file, because "are you sure"
      -- on its own does not tell you what you are about to lose.
      if visible(dy) then
        common.draw_text(font, style.error, (scope == "global")
          and "This removes the tool from EVERY project on this machine."
          or  ("This removes the " .. scope .. " tool."),
          "left", dx, dy, dw, lh)
      end
      dy = dy + lh
      if visible(dy) then
        if path then
          -- Truncated from the left: the end of a path is the part that says
          -- which file this is.
          local shown = short_path(path)
          if #shown > dcols then shown = "..." .. shown:sub(#shown - dcols + 4) end
          common.draw_text(font, style.dim, shown, "left", dx, dy, dw, lh)
        else
          common.draw_text(font, style.dim, "(session tool: nothing on disk)",
            "left", dx, dy, dw, lh)
        end
      end
      dy = dy + lh + vpad / 2
      if visible(dy) then
        for _, hit in ipairs(widgets.row(font, {
          { label = "Delete the " .. scope .. " tool '" .. e.name .. "'",
            tone = style.error, id = "do-delete" },
          { label = "Cancel", id = "cancel-delete" },
        }, dx, dy, self.mouse)) do
          local id = hit.item.id
          add(hit, id, function()
            if id == "do-delete" then self:delete_tool(e) else self.confirm = nil end
          end)
        end
      end
      dy = dy + bh
    else
      local del = { label = "Delete the " .. scope .. " tool...", id = "ask-delete" }
      local open = path and { label = "Open the file", id = "open" } or nil
      -- widgets.row clips rather than wraps, and a clipped "Open the file" is a
      -- control you cannot click. In a narrow pane they stack instead.
      local rows = { { del, open } }
      if open and widgets.width(font, del.label) + widgets.width(font, open.label)
          + style.padding.x * widgets.GAP > dw then
        rows = { { del }, { open } }
      end
      for _, r in ipairs(rows) do
        if visible(dy) then
          for _, hit in ipairs(widgets.row(font, r, dx, dy, self.mouse)) do
            local id = hit.item.id
            add(hit, id, function()
              if id == "ask-delete" then
                self.confirm = e.name
              else
                core.root_view:open_doc(core.open_doc(path))
              end
            end)
          end
        end
        dy = dy + bh
      end
    end
    dy = dy + vpad
  end

  dy = draw_rows(body, dy)

  -- ---- notice --------------------------------------------------------------
  if self.notice then
    local ny = self.position.y + self.size.y - lh - vpad / 2
    renderer.draw_rect(self.position.x, ny - vpad / 2, self.size.x, 1, style.divider)
    local text = self.notice.text
    local room = math.floor(full / charw)
    if #text > room then text = text:sub(1, math.max(1, room - 3)) .. "..." end
    common.draw_text(font, self.notice.bad and style.error or style.good,
      text, "left", x0, ny, full, lh)
  end

  -- Measured from the top of the VIEW, not body_top: clamp_scroll_position
  -- subtracts the whole view height, so measuring from body_top left the
  -- maximum scroll short by the header and the last entries unreachable.
  self.content_height = math.max(list_bottom, dy) + self.scroll.y
    - self.position.y + vpad * 2
  self:draw_scrollbar()
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------
--
-- lite routes key presses through the keymap to *commands*; a plain View's
-- on_key_pressed is never called (only on_text_input reaches one). So the
-- search box's enter, escape and backspace are commands whose predicate is
-- "this view, with the search box focused". keymap.add prepends, so they are
-- tried before command:submit and doc:newline and fall through to them
-- everywhere else. Guarded because command.add asserts on a duplicate name and
-- this module can be required again after a reload.

local function in_library()
  local v = core.active_view
  return (v and v.is and v:is(LibraryView)) and true or false
end

-- Enter and backspace only mean something while the box has the keyboard, so
-- they fall through when it does not. Escape is different: committing a search
-- takes the focus away, and "escape clears the search" has to keep working
-- afterwards or the only way back to the full list is to delete the query by
-- hand.
local function typing()
  return in_library() and core.active_view.searching and true or false
end

if not command.map["library:search-commit"] then
  command.add(typing, {
    ["library:search-commit"] = function() core.active_view:commit_search() end,
    ["library:search-backspace"] = function() core.active_view:backspace() end,
  })
  command.add(in_library, {
    ["library:search-cancel"] = function() core.active_view:cancel_search() end,
  })
  keymap.add {
    ["return"] = "library:search-commit",
    ["escape"] = "library:search-cancel",
    ["backspace"] = "library:search-backspace",
  }
end

return LibraryView
