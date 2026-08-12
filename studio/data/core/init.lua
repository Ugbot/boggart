require "core.strict"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command
local keymap
local RootView
local StatusView
local CommandView
local Doc

local core = {}


-- ---- the project file list --------------------------------------------------
--
-- lite rebuilt this list from scratch on a timer: one system.list_dir per
-- directory and one system.get_file_info per entry, every
-- config.project_scan_rate seconds, forever. On this repository that is ~800
-- directories and ~4,100 entries -- about 20ms of syscalls every five seconds
-- to usually discover that nothing had changed, and up to five seconds of the
-- window disagreeing with the disk when something had.
--
-- What replaces it is a kernel filesystem watcher (system.dirmonitor, see
-- studio/src/api/dirmonitor.c) feeding a tree that is patched rather than
-- rebuilt. A change always arrives as "this directory needs re-reading", so the
-- work is one list_dir plus one get_file_info per entry of that one directory,
-- and the flat list every consumer iterates is spliced in place. Adding one
-- file does not touch the other four thousand entries.
--
-- The polling scan is still here and still correct. It is what runs where the
-- platform has no watcher, where the watcher refuses to start, and where the
-- kernel's watch limit is exhausted -- inotify's is a per-user sysctl, commonly
-- 8192, shared with everything else the user is running. Which of the two is
-- active is readable from core.project_scan_mode and core.project_scan_status(),
-- because the first question to ask about a stale file list is which mode it
-- was in.

-- These describe this mechanism and nothing outside it has an opinion about
-- them, so they are set here rather than in core.config -- which still gets the
-- final word, since `user` loads after this file.
config.project_watch_rate = 0.25   -- how often to drain the watcher when quiet
config.project_settle_time = 0.1   -- quiet period before acting on a burst
config.project_settle_max  = 1.0   -- ...but never stall a burst longer than this

local project = {
  roots = {},        -- root nodes, in the order their entries appear in the list
  nodes = {},        -- path -> directory node, for every directory tracked
  owned = nil,       -- the core.project_files table this module built
  monitor = nil,
  recursive = false, -- one watch covers a whole tree (FSEvents, win32)
  exhausted = false, -- the kernel refused another watch
  version = 0,
}


local function compare_file(a, b)
  return a.filename < b.filename
end


-- Remove `remove` entries at `at` and put `insert` there instead, in one move.
-- The source range deliberately runs past the end of the table so the tail is
-- cleared with nils by the same operation; this is lite-xl's common.splice.
local function splice(t, at, remove, insert)
  insert = insert or {}
  local n = #insert
  if remove ~= n then table.move(t, at + remove, #t + remove, at + n) end
  table.move(insert, 1, n, at, t)
end


-- Read one directory. This is the only place that touches the filesystem, and
-- the whole point of the rewrite is that it is called for the directories that
-- changed rather than for all of them.
local function read_dir(path)
  local all = system.list_dir(path)
  if not all then return nil end
  local size_limit = config.file_size_limit * 10e5
  local dirs, files = {}, {}
  for _, file in ipairs(all) do
    if not common.match_pattern(file, config.ignore_files) then
      local filename = (path ~= "." and path .. PATHSEP or "") .. file
      local info = system.get_file_info(filename)
      if info and info.size < size_limit then
        info.filename = filename
        table.insert(info.type == "dir" and dirs or files, info)
      end
    end
  end
  table.sort(dirs, compare_file)
  table.sort(files, compare_file)
  return dirs, files
end


local function touch(structural)
  core.redraw = true
  if structural then
    -- Consumers that cache anything derived from the *shape* of the list (the
    -- tree view's collapsed-subtree skips) key off this. The list table itself
    -- no longer changes identity on every scan, so identity is no longer a
    -- usable signal that it changed.
    project.version = project.version + 1
    core.project_files_version = project.version
  end
end


-- A node's subtree occupies `span` consecutive entries of core.project_files,
-- laid out exactly as lite's depth-first walk laid them out: the directory's own
-- entry, then each subdirectory's whole subtree in name order, then the
-- directory's files in name order. Keeping the span lets any entry's index be
-- computed without searching the flat list.
local function own_span(node)
  local n = node.info and 1 or 0
  for _, d in ipairs(node.dirs) do n = n + d.span end
  return n + #node.files
end


local function adjust_span(node, delta)
  while node do
    node.span = node.span + delta
    node = node.parent
  end
end


local function build_node(path, parent, info)
  local node = { path = path, parent = parent, info = info,
                 dirs = {}, files = {}, span = 0 }
  project.nodes[path] = node
  local dirs, files = read_dir(path)
  if dirs then
    for _, di in ipairs(dirs) do
      node.dirs[#node.dirs + 1] = build_node(di.filename, node, di)
    end
    node.files = files
  end
  node.span = own_span(node)
  return node
end


local function flatten(node, out)
  if node.info then out[#out + 1] = node.info end
  for _, d in ipairs(node.dirs) do flatten(d, out) end
  for _, f in ipairs(node.files) do out[#out + 1] = f end
  return out
end


local function forget_node(node)
  if node.watch_id and project.monitor then
    project.monitor:unwatch(node.watch_id)
    node.watch_id = nil
  end
  project.nodes[node.path] = nil
  for _, d in ipairs(node.dirs) do forget_node(d) end
end


local function watch_subtree(node)
  local m = project.monitor
  if not m or project.exhausted then return end
  if project.recursive and node.parent then return end
  if not node.watch_id then
    local id, err = m:watch(node.path)
    if id then
      node.watch_id = id
    else
      -- ENOSPC here is inotify's per-user watch limit. Stop asking -- every
      -- refusal costs a syscall -- say so once, and let the periodic scan cover
      -- what is not watched. A watcher that quietly stops noticing changes is
      -- worse than the polling it replaced.
      project.exhausted = true
      project.watch_error = err
      core.log_quiet("dirmonitor: %s after %d watches; polling the rest every %gs",
        tostring(err), m:count(), config.project_scan_rate)
      return
    end
  end
  if not project.recursive then
    for _, d in ipairs(node.dirs) do watch_subtree(d) end
  end
end


-- Index of the first flat entry belonging to this node's subtree.
local function node_start(node)
  local parent = node.parent
  if not parent then
    local i = 1
    for _, r in ipairs(project.roots) do
      if r == node then return i end
      i = i + r.span
    end
    return i
  end
  local i = node_start(parent) + (parent.info and 1 or 0)
  for _, d in ipairs(parent.dirs) do
    if d == node then return i end
    i = i + d.span
  end
  return i
end


local function child_dir_start(node, idx)
  local i = node_start(node) + (node.info and 1 or 0)
  for k = 1, idx - 1 do i = i + node.dirs[k].span end
  return i
end


local function files_start(node)
  local i = node_start(node) + (node.info and 1 or 0)
  for _, d in ipairs(node.dirs) do i = i + d.span end
  return i
end


local function remove_child_dir(node, idx)
  local child = node.dirs[idx]
  local pos = child_dir_start(node, idx)
  splice(core.project_files, pos, child.span, nil)
  table.remove(node.dirs, idx)
  adjust_span(node, -child.span)
  forget_node(child)
  touch(true)
end


local function add_child_dir(node, info, idx)
  local pos = child_dir_start(node, idx)
  local child = build_node(info.filename, node, info)
  table.insert(node.dirs, idx, child)
  adjust_span(node, child.span)
  splice(core.project_files, pos, 0, flatten(child, {}))
  watch_subtree(child)
  touch(true)
end


local function remove_file(node, idx)
  splice(core.project_files, files_start(node) + idx - 1, 1, nil)
  table.remove(node.files, idx)
  adjust_span(node, -1)
  touch(true)
end


local function add_file(node, info, idx)
  splice(core.project_files, files_start(node) + idx - 1, 0, { info })
  table.insert(node.files, idx, info)
  adjust_span(node, 1)
  touch(true)
end


-- Re-read one directory and patch the difference into the flat list. Returns
-- the node that should be refreshed next -- the parent, when this directory has
-- gone away and only the parent can say so -- or nil when there is nothing more
-- to do.
local function refresh_dir(node)
  local dirs, files = read_dir(node.path)
  if not dirs then
    if node.parent then return node.parent end
    -- A root that has gone away (unmounted, deleted, unplugged) must not take
    -- the scanner down with it; it contributes nothing until it comes back.
    while #node.dirs > 0 do remove_child_dir(node, 1) end
    while #node.files > 0 do remove_file(node, 1) end
    return nil
  end

  -- Both lists are sorted by the same key, so one merge walk finds exactly what
  -- appeared, what went away, and what merely changed on disk. A rename shows up
  -- as one of each, which is the honest reading: an editor saving a file writes
  -- a temporary and renames over the target, so "the file moved" would be a
  -- guess where "this directory changed" is a fact.
  local oi, ni = 1, 1
  while oi <= #node.dirs or ni <= #dirs do
    local o, n = node.dirs[oi], dirs[ni]
    if o and (not n or o.path < n.filename) then
      remove_child_dir(node, oi)
    elseif n and (not o or n.filename < o.path) then
      add_child_dir(node, n, oi)
      oi, ni = oi + 1, ni + 1
    else
      if o.info and o.info.modified ~= n.modified then
        o.info.modified = n.modified
        touch(false)
      end
      oi, ni = oi + 1, ni + 1
    end
  end

  oi, ni = 1, 1
  while oi <= #node.files or ni <= #files do
    local o, n = node.files[oi], files[ni]
    if o and (not n or o.filename < n.filename) then
      remove_file(node, oi)
    elseif n and (not o or n.filename < o.filename) then
      add_file(node, n, oi)
      oi, ni = oi + 1, ni + 1
    else
      if o.modified ~= n.modified or o.size ~= n.size then
        o.modified, o.size = n.modified, n.size
        touch(false)
      end
      oi, ni = oi + 1, ni + 1
    end
  end
  return nil
end


local function rebuild()
  for _, r in ipairs(project.roots) do forget_node(r) end
  project.roots, project.nodes = {}, {}
  project.exhausted, project.watch_error = false, nil

  -- Every root, not just the one the process started in.
  --
  -- The project used to be exactly the directory boggart was launched from,
  -- with no way to add another -- so working across two checkouts meant two
  -- windows. Roots are relative "." plus any absolute paths added at runtime;
  -- entries from an added root carry their absolute path, which is what makes
  -- them openable and what tells them apart in the tree.
  local paths = { "." }
  for _, r in ipairs(core.project_roots or {}) do paths[#paths + 1] = r end

  local list = {}
  for _, path in ipairs(paths) do
    local node = build_node(path, nil, nil)
    if path ~= "." and #node.dirs == 0 and #node.files == 0
    and not system.get_file_info(path) then
      core.log_quiet("project root is unreadable: %s", path)
    end
    project.roots[#project.roots + 1] = node
    flatten(node, list)
  end
  for _, r in ipairs(project.roots) do watch_subtree(r) end

  core.project_files = list
  project.owned = list
  -- Counted because a full rescan is the expensive path and the one that means
  -- something went wrong -- a burst too large to coalesce, a root swapped out.
  -- A number that climbs while nothing is happening is the bug report.
  core.project_rescans = (core.project_rescans or 0) + 1
  touch(true)
end


local function roots_changed()
  local want = core.project_roots or {}
  if #project.roots ~= #want + 1 then return true end
  for i, path in ipairs(want) do
    if project.roots[i + 1].path ~= path then return true end
  end
  return false
end


-- The watcher reports paths built from the string it was handed at watch time,
-- so the root comes back as "." and its children as "./src". The tree calls that
-- directory "src".
local function normalise(path)
  if path == "." or path == "" then return "." end
  return (path:gsub("^%./", ""))
end


-- Drop events for anything the project does not contain. On a recursive backend
-- this matters a lot: FSEvents reports the whole subtree, so a `git` operation
-- delivers hundreds of paths under .git that the file list has never held and
-- must not be made to rescan for.
local function is_ignored(path)
  local rel = path
  for _, r in ipairs(project.roots) do
    if r.path ~= "." and path:sub(1, #r.path) == r.path then
      rel = path:sub(#r.path + 1)
      break
    end
  end
  for name in rel:gmatch("[^/\\]+") do
    if name ~= "." and common.match_pattern(name, config.ignore_files) then
      return true
    end
  end
  return false
end


local function nearest_node(path)
  local p = path
  while p and p ~= "" do
    local node = project.nodes[p]
    if node then return node end
    local up = p:match("^(.*)[/\\][^/\\]+$")
    if up == p then return nil end
    if not up then return project.nodes["."] end  -- a bare relative name
    p = up
  end
  return nil
end


local function refresh_paths(pending)
  local paths = {}
  for p in pairs(pending) do paths[#paths + 1] = p end
  -- Shortest first: refreshing a parent can create or destroy the very node a
  -- longer path names, and a file created in a brand new subdirectory is only
  -- reachable once the parent has been told the subdirectory exists.
  table.sort(paths, function(a, b) return #a < #b end)
  for i, p in ipairs(paths) do
    local node = project.nodes[p] or nearest_node(p)
    while node do node = refresh_dir(node) end
    -- Spread a burst over frames rather than dropping one; run_threads stops us
    -- at the frame budget anyway, this just gives it the chance.
    if i % 8 == 0 then coroutine.yield() end
  end
end


local function poll_all()
  local paths = {}
  for p in pairs(project.nodes) do paths[#paths + 1] = p end
  table.sort(paths, function(a, b) return #a < #b end)
  for i, p in ipairs(paths) do
    local node = project.nodes[p]   -- may have been dropped earlier in this pass
    while node do node = refresh_dir(node) end
    if i % 16 == 0 then coroutine.yield() end
  end
end


local function open_monitor()
  -- The escape hatch for the first question a stale file list raises. Running
  -- with this set forces the periodic scan, so "does it go away without the
  -- watcher" can be answered without a rebuild.
  if os.getenv("BOGGART_STUDIO_NO_WATCH") then
    core.log_quiet("BOGGART_STUDIO_NO_WATCH set; polling every %gs",
      config.project_scan_rate)
    return
  end
  if not system.dirmonitor_caps then return end
  local caps = system.dirmonitor_caps()
  if not caps.available then
    core.log_quiet("no filesystem watcher on this platform; polling every %gs",
      config.project_scan_rate)
    return
  end
  local m, err = system.dirmonitor()
  if not m then
    core.log_quiet("dirmonitor unavailable (%s); polling every %gs",
      tostring(err), config.project_scan_rate)
    return
  end
  project.monitor = m
  project.caps = caps
  project.recursive = caps.recursive and true or false
end


local function update_mode()
  local m = project.monitor
  core.project_watch_count = m and m:count() or 0
  core.project_scan_mode =
    (not m and "polling") or (project.exhausted and "partial") or "watching"
end


-- One line for the status bar and for `boggart doctor`: if someone reports a
-- file list that disagrees with the disk, this is the first thing to ask for.
function core.project_scan_status()
  local n = core.project_watch_count or 0
  local backend = project.caps and project.caps.backend or "none"
  if core.project_scan_mode == "watching" then
    return string.format("watching %d %s via %s",
      n, n == 1 and "directory" or "directories", backend)
  elseif core.project_scan_mode == "partial" then
    return string.format("watching %d via %s, polling the rest every %gs (%s)",
      n, backend, config.project_scan_rate, tostring(project.watch_error))
  end
  return string.format("polling every %gs, no watcher", config.project_scan_rate)
end


local function project_scan_thread()
  local pending, dirty_since, last_event, overflowed
  local next_poll = 0
  local function clear()
    pending, dirty_since, last_event, overflowed = {}, nil, 0, false
  end
  clear()

  while true do
    if core.project_files ~= project.owned or roots_changed() then
      -- Someone replaced the list or changed the roots underneath us --
      -- studio.work_in chdirs and resets both. Every path held here is relative
      -- to a directory we may no longer be in, so start again.
      rebuild()
      clear()
      next_poll = system.get_time() + config.project_scan_rate
    end

    local now = system.get_time()
    local wait = config.project_scan_rate

    if project.monitor then
      local dirs, of = project.monitor:check()
      local accepted = false
      if of then overflowed, accepted = true, true end
      for _, path in ipairs(dirs or {}) do
        local p = normalise(path)
        if not pending[p] and not is_ignored(p) then
          pending[p], accepted = true, true
        end
      end
      if accepted then
        last_event = now
        dirty_since = dirty_since or now
      end

      if dirty_since
      and (now - last_event >= config.project_settle_time
           or now - dirty_since >= config.project_settle_max) then
        if overflowed then
          -- More distinct directories changed than the coalescer will hold,
          -- which means a checkout or a build ran. One bounded full rescan
          -- cannot miss anything; an unbounded list of directory rescans is
          -- neither bounded nor obviously complete.
          rebuild()
        else
          refresh_paths(pending)
        end
        clear()
        next_poll = system.get_time() + config.project_scan_rate
      end

      -- Draining a burst is the only time this thread is worth waking often.
      -- Quiet, it runs at the same cadence the frame loop already idles at, so
      -- watching costs no more wakeups than not watching did.
      wait = dirty_since and (config.project_settle_time / 2)
        or config.project_watch_rate
    end

    -- Anything not covered by a watch still has to be noticed, so the periodic
    -- scan keeps running whenever the watcher is absent or incomplete.
    if (not project.monitor or project.exhausted) and now >= next_poll then
      poll_all()
      next_poll = system.get_time() + config.project_scan_rate
    end

    update_mode()
    coroutine.yield(wait)
  end
end


function core.init()
  command = require "core.command"
  keymap = require "core.keymap"
  RootView = require "core.rootview"
  StatusView = require "core.statusview"
  CommandView = require "core.commandview"
  Doc = require "core.doc"

  local project_dir = EXEDIR
  local files = {}
  for i = 2, #ARGS do
    local info = system.get_file_info(ARGS[i]) or {}
    if info.type == "file" then
      table.insert(files, system.absolute_path(ARGS[i]))
    elseif info.type == "dir" then
      project_dir = ARGS[i]
    end
  end

  system.chdir(project_dir)

  core.frame_start = 0
  core.clip_rect_stack = {{ 0,0,0,0 }}
  core.log_items = {}
  core.docs = {}
  core.threads = setmetatable({}, { __mode = "k" })
  core.project_files = {}
  core.project_files_version = 0
  core.project_roots = {}
  core.project_scan_mode = "polling"
  core.project_watch_count = 0
  core.project_rescans = 0
  core.redraw = true

  core.root_view = RootView()
  core.command_view = CommandView()
  core.status_view = StatusView()

  core.root_view.root_node:split("down", core.command_view, true)
  core.root_view.root_node.b:split("down", core.status_view, true)

  open_monitor()
  core.add_thread(project_scan_thread)
  command.add_defaults()

  -- boggart-studio: the agent panel, its commands and its configuration
  -- surfaces. Loaded before plugins and the user module so both can override
  -- anything it sets, which is the same courtesy lite extends to its own
  -- defaults. Failing to load must not stop the editor coming up -- an editor
  -- that cannot reach a model is still an editor.
  if bog then
    core.studio = core.try(require, "core.studio") and require "core.studio" or nil
    -- Build the window before plugins load, so the file tree docks beside the
    -- chat list rather than replacing it.
    if core.studio then core.try(core.studio.attach) end
  end
  local got_plugin_error = not core.load_plugins()
  local got_user_error = not core.try(require, "user")
  local got_project_error = not core.load_project_module()

  -- A scripted entry point, for driving the GUI without a human at the
  -- keyboard. The panel-attachment bug this exists to catch was invisible to
  -- every headless test of the view -- the view was fine; it was never added
  -- to the node tree -- and only a rendered frame showed it. Deliberately an
  -- environment variable rather than a flag: it must not clobber the user
  -- module, which is the file a person keeps their own config in.
  local script = os.getenv("BOGGART_STUDIO_SCRIPT")
  if script then core.try(dofile, script) end

  for _, filename in ipairs(files) do
    core.root_view:open_doc(core.open_doc(filename))
  end

  if got_plugin_error or got_user_error or got_project_error then
    command.perform("core:open-log")
  end
end


-- math.floor: Lua 5.3+ rejects a float for %d, where 5.2 truncated silently.
local temp_uid = math.floor((system.get_time() * 1000) % 0xffffffff)
local temp_file_prefix = string.format(".lite_temp_%08x", temp_uid)
local temp_file_counter = 0

local function delete_temp_files()
  for _, filename in ipairs(system.list_dir(EXEDIR)) do
    if filename:find(temp_file_prefix, 1, true) == 1 then
      os.remove(EXEDIR .. PATHSEP .. filename)
    end
  end
end

function core.temp_filename(ext)
  temp_file_counter = temp_file_counter + 1
  return EXEDIR .. PATHSEP .. temp_file_prefix
      .. string.format("%06x", temp_file_counter) .. (ext or "")
end


function core.quit(force)
  if force then
    delete_temp_files()
    os.exit()
  end
  local dirty_count = 0
  local dirty_name
  for _, doc in ipairs(core.docs) do
    if doc:is_dirty() then
      dirty_count = dirty_count + 1
      dirty_name = doc:get_name()
    end
  end
  if dirty_count > 0 then
    local text
    if dirty_count == 1 then
      text = string.format("\"%s\" has unsaved changes. Quit anyway?", dirty_name)
    else
      text = string.format("%d docs have unsaved changes. Quit anyway?", dirty_count)
    end
    local confirm = system.show_confirm_dialog("Unsaved Changes", text)
    if not confirm then return end
  end
  core.quit(true)
end


function core.load_plugins()
  local no_errors = true
  local files = system.list_dir(DATADIR .. "/plugins") or {}
  for _, filename in ipairs(files) do
    local modname = "plugins." .. filename:gsub(".lua$", "")
    local ok = core.try(require, modname)
    if ok then
      core.log_quiet("Loaded plugin %q", modname)
    else
      no_errors = false
    end
  end
  return no_errors
end


function core.load_project_module()
  local filename = ".lite_project.lua"
  if system.get_file_info(filename) then
    return core.try(function()
      local fn, err = loadfile(filename)
      if not fn then error("Error when loading project module:\n\t" .. err) end
      fn()
      core.log_quiet("Loaded project module")
    end)
  end
  return true
end


function core.reload_module(name)
  local old = package.loaded[name]
  package.loaded[name] = nil
  local new = require(name)
  if type(old) == "table" then
    for k, v in pairs(new) do old[k] = v end
    package.loaded[name] = old
  end
end


function core.set_active_view(view)
  assert(view, "Tried to set active view to nil")
  if view ~= core.active_view then
    core.last_active_view = core.active_view
    core.active_view = view
  end
end


-- Anonymous threads used to be keyed by #core.threads + 1 and removed with
-- table.remove, which renumbered every later thread -- so a thread finishing
-- silently handed its key, and its wake time, to the one after it. Keys are
-- handed out from a counter now and cleared by key, never shifted.
local thread_counter = 0

function core.add_thread(f, weak_ref)
  local key = weak_ref
  if not key then
    thread_counter = thread_counter + 1
    key = thread_counter
  end
  local fn = function() return core.try(f) end
  core.threads[key] = { cr = coroutine.create(fn), wake = 0 }
end


function core.push_clip_rect(x, y, w, h)
  local x2, y2, w2, h2 = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  local r, b, r2, b2 = x+w, y+h, x2+w2, y2+h2
  x, y = math.max(x, x2), math.max(y, y2)
  b, r = math.min(b, b2), math.min(r, r2)
  w, h = r-x, b-y
  table.insert(core.clip_rect_stack, { x, y, w, h })
  renderer.set_clip_rect(x, y, w, h)
end


function core.pop_clip_rect()
  table.remove(core.clip_rect_stack)
  local x, y, w, h = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  renderer.set_clip_rect(x, y, w, h)
end


function core.open_doc(filename)
  if filename then
    -- try to find existing doc for filename
    local abs_filename = system.absolute_path(filename)
    for _, doc in ipairs(core.docs) do
      if doc.filename
      and abs_filename == system.absolute_path(doc.filename) then
        return doc
      end
    end
  end
  -- no existing doc for filename; create new
  local doc = Doc(filename)
  table.insert(core.docs, doc)
  core.log_quiet(filename and "Opened doc \"%s\"" or "Opened new doc", filename)
  return doc
end


function core.get_views_referencing_doc(doc)
  local res = {}
  local views = core.root_view.root_node:get_children()
  for _, view in ipairs(views) do
    if view.doc == doc then table.insert(res, view) end
  end
  return res
end


local function log(icon, icon_color, fmt, ...)
  local text = string.format(fmt, ...)
  if icon then
    core.status_view:show_message(icon, icon_color, text)
  end

  local info = debug.getinfo(2, "Sl")
  local at = string.format("%s:%d", info.short_src, info.currentline)
  local item = { text = text, time = os.time(), at = at }
  table.insert(core.log_items, item)
  if #core.log_items > config.max_log_items then
    table.remove(core.log_items, 1)
  end
  return item
end


function core.log(...)
  return log("i", style.text, ...)
end


function core.log_quiet(...)
  return log(nil, nil, ...)
end


function core.error(...)
  return log("!", style.accent, ...)
end


function core.try(fn, ...)
  local err
  local ok, res = xpcall(fn, function(msg)
    local item = core.error("%s", msg)
    item.info = debug.traceback(nil, 2):gsub("\t", "")
    err = msg
  end, ...)
  if ok then
    return true, res
  end
  return false, err
end


function core.on_event(type, ...)
  local did_keymap = false
  if type == "textinput" then
    core.root_view:on_text_input(...)
  elseif type == "keypressed" then
    did_keymap = keymap.on_key_pressed(...)
  elseif type == "keyreleased" then
    keymap.on_key_released(...)
  elseif type == "mousemoved" then
    core.root_view:on_mouse_moved(...)
  elseif type == "mousepressed" then
    core.root_view:on_mouse_pressed(...)
  elseif type == "mousereleased" then
    core.root_view:on_mouse_released(...)
  elseif type == "mousewheel" then
    core.root_view:on_mouse_wheel(...)
  elseif type == "filedropped" then
    local filename, mx, my = ...
    local info = system.get_file_info(filename)
    if info and info.type == "dir" then
      system.exec(string.format("%q %q", EXEFILE, filename))
    else
      local ok, doc = core.try(core.open_doc, filename)
      if ok then
        local node = core.root_view.root_node:get_child_overlapping_point(mx, my)
        node:set_active_view(node.active_view)
        core.root_view:open_doc(doc)
      end
    end
  elseif type == "quit" then
    core.quit()
  end
  return did_keymap
end


function core.step()
  -- handle events
  local did_keymap = false
  local mouse_moved = false
  local mouse = { x = 0, y = 0, dx = 0, dy = 0 }

  for type, a,b,c,d in system.poll_event do
    if type == "mousemoved" then
      mouse_moved = true
      mouse.x, mouse.y = a, b
      mouse.dx, mouse.dy = mouse.dx + c, mouse.dy + d
    elseif type == "textinput" and did_keymap then
      did_keymap = false
    else
      local _, res = core.try(core.on_event, type, a, b, c, d)
      did_keymap = res or did_keymap
    end
    core.redraw = true
  end
  if mouse_moved then
    core.try(core.on_event, "mousemoved", mouse.x, mouse.y, mouse.dx, mouse.dy)
  end

  local width, height = renderer.get_size()

  -- update
  core.root_view.size.x, core.root_view.size.y = width, height
  core.root_view:update()
  if not core.redraw then return false end
  core.redraw = false

  -- close unreferenced docs
  for i = #core.docs, 1, -1 do
    local doc = core.docs[i]
    if #core.get_views_referencing_doc(doc) == 0 then
      table.remove(core.docs, i)
      core.log_quiet("Closed doc \"%s\"", doc:get_name())
    end
  end

  -- update window title
  local name = core.active_view:get_name()
  local title = (name ~= "---") and (name .. " - boggart") or "boggart studio"
  if title ~= core.window_title then
    system.set_window_title(title)
    core.window_title = title
  end

  -- draw
  renderer.begin_frame()
  core.clip_rect_stack[1] = { 0, 0, width, height }
  renderer.set_clip_rect(table.unpack(core.clip_rect_stack[1]))
  core.root_view:draw()
  renderer.end_frame()
  return true
end


-- Returns how long the frame loop may wait before some thread wants to run
-- again, which is lite-xl's scheduling and the reason an idle editor can be
-- idle: with nothing due, the loop blocks on an event instead of waking at the
-- frame rate to rediscover that there is nothing to do.
--
-- The table is snapshotted before iterating because a thread may add or remove
-- threads while it runs, and pairs() over a table being mutated during the
-- traversal is undefined.
local run_threads = coroutine.wrap(function()
  while true do
    local max_time = 1 / config.fps - 0.004
    local minimal_time_to_wake = math.huge

    local threads = {}
    for k, thread in pairs(core.threads) do threads[k] = thread end

    for k, thread in pairs(threads) do
      -- ...and re-checked here, since a thread run earlier in this same pass
      -- may have removed this one.
      if core.threads[k] and thread.wake < system.get_time() then
        local _, wait = assert(coroutine.resume(thread.cr))
        if coroutine.status(thread.cr) == "dead" then
          core.threads[k] = nil
        elseif wait then
          thread.wake = system.get_time() + wait
          minimal_time_to_wake = math.min(minimal_time_to_wake, wait)
        else
          minimal_time_to_wake = 0
        end
      else
        minimal_time_to_wake =
          math.min(minimal_time_to_wake, thread.wake - system.get_time())
      end

      -- stop running threads if we're about to hit the end of frame
      if system.get_time() - core.frame_start > max_time then
        coroutine.yield(0)
      end
    end

    coroutine.yield(minimal_time_to_wake)
  end
end)


function core.run()
  while true do
    core.frame_start = system.get_time()
    local did_redraw = core.step()
    local time_to_wake = run_threads()
    if not did_redraw and not system.window_has_focus() then
      -- Nothing changed and nobody is looking. Block until an event arrives or
      -- until the earliest thread is due, whichever is sooner, rather than
      -- waking on a fixed timer -- this is what lets the file watcher be
      -- drained promptly without adding wakeups of its own.
      system.wait_event(math.max(0, math.min(0.25, time_to_wake)))
    end
    local elapsed = system.get_time() - core.frame_start
    system.sleep(math.max(0, 1 / config.fps - elapsed))
  end
end


function core.on_error(err)
  -- write error to file
  local fp = io.open(EXEDIR .. "/error.txt", "wb")
  fp:write("Error: " .. tostring(err) .. "\n")
  fp:write(debug.traceback(nil, 4))
  fp:close()
  -- save copy of all unsaved documents
  for _, doc in ipairs(core.docs) do
    if doc:is_dirty() and doc.filename then
      doc:save(doc.filename .. "~")
    end
  end
end


return core
