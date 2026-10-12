-- tracker_view.lua -- how tickets LOOK: one view model, two renderers.
--
-- The TUI and the studio both show tickets, and two separately-written views
-- drift: a status that reads one way in the terminal and another in the
-- window, a field one of them forgot. So the shape is computed here once --
-- sections, rows, cards, board columns -- and each surface only draws it: the
-- text renderers below for the TUI, studio/data/core/trackerview.lua for the
-- window.
--
-- The TUI renderers aim at READABILITY, not decoration (the ask): plain
-- aligned text that survives scrollback, copy/paste and a monochrome
-- terminal. Status is always a glyph PLUS its position or its word, never
-- colour alone. Keys lead every row so they can be copied. Long titles wrap
-- under themselves instead of being cut off. One screen answers one question:
--   /tracker              projects, with open/done counts
--   /tracker BRAIN        what's next: in progress, review, ready, blocked
--   /tracker BRAIN done   what's finished
--   /tracker BRAIN tree   the hierarchy
--   /tracker BRAIN-35     one ticket, as a sectioned card
local tc = require("tracker_core")
local M = {}

M.GLYPH = { open = "○", in_progress = "◐", blocked = "⊘", in_review = "◑", done = "✓", cancelled = "×" }
M.LABEL = { open = "open", in_progress = "in progress", blocked = "blocked", in_review = "in review",
            done = "done", cancelled = "cancelled" }

local function q(sql, p) return bog.db:query(sql, p or {}) or {} end

-- ---- width-aware wrapping -----------------------------------------------------
local function dw(s) return (sys and sys.width and sys.width(s)) or #s end
M.display_width = dw

-- Words into lines of at most `width` display columns. A word longer than the
-- line is split rather than overflowing.
function M.wrap(text, width)
  width = math.max(8, width or 80)
  local lines, cur = {}, ""
  for w0 in tostring(text or ""):gmatch("%S+") do
    local word = w0
    while dw(word) > width do
      if cur ~= "" then lines[#lines + 1] = cur; cur = "" end
      local cut, n = "", 0
      for ch in word:gmatch(utf8.charpattern) do
        if n + dw(ch) > width then break end
        cut = cut .. ch; n = n + dw(ch)
      end
      lines[#lines + 1] = cut
      word = word:sub(#cut + 1)
    end
    if cur == "" then cur = word
    elseif dw(cur) + 1 + dw(word) <= width then cur = cur .. " " .. word
    else lines[#lines + 1] = cur; cur = word end
  end
  if cur ~= "" or #lines == 0 then lines[#lines + 1] = cur end
  return lines
end

local function pad(s, n) return s .. string.rep(" ", math.max(0, n - dw(s))) end

-- ---- models ----------------------------------------------------------------------
local function row(t, note)
  return { key = t.key, status = t.status, glyph = M.GLYPH[t.status] or "?", priority = t.priority,
           kind = t.kind, title = t.title, note = note }
end

function M.projects_model()
  tc.ensure_schema()
  local out = {}
  for _, p in ipairs(q([[SELECT p.key, p.name, p.next_seq,
      (SELECT count(*) FROM trk_tasks t WHERE t.project = p.key AND t.status NOT IN ('done','cancelled')) AS open,
      (SELECT count(*) FROM trk_tasks t WHERE t.project = p.key AND t.status IN ('done','cancelled')) AS done
      FROM trk_projects p ORDER BY p.key]])) do
    out[#out + 1] = { key = p.key, name = p.name, open = p.open, done = p.done, next = p.key .. "-" .. p.next_seq }
  end
  return { projects = out }
end

-- "What's next": the resolver's view, grouped by what you would do about it.
function M.next_model(project)
  tc.ensure_schema()
  local p = tc.project_row(project)
  if not p then return nil, "no such project '" .. tostring(project) .. "'" end
  local ok, plan = pcall(tc.resolve_plan, p.key)
  if not ok then return nil, tostring(plan) end
  local status = {}
  for _, t in ipairs(q("SELECT * FROM trk_tasks WHERE project = ? AND status NOT IN ('done','cancelled')", { p.key })) do
    status[t.key] = t
  end
  local blockers = {}
  for _, b in ipairs(plan.blocked) do blockers[b.key] = b.blockers end
  local waiting = {}
  for _, w in ipairs(plan.waiting) do waiting[w.key] = true end

  local groups = { in_progress = {}, in_review = {}, ready = {}, blocked = {}, waiting = {} }
  -- resolver order is priority, then key -- keep it
  local order = {}
  for _, x in ipairs(plan.ready) do order[#order + 1] = x.key end
  for _, x in ipairs(plan.blocked) do order[#order + 1] = x.key end
  for _, x in ipairs(plan.waiting) do order[#order + 1] = x.key end
  table.sort(order, function(a, b)
    local ta, tb = status[a], status[b]
    if ta.priority ~= tb.priority then return ta.priority < tb.priority end
    return ta.seq < tb.seq
  end)
  for _, key in ipairs(order) do
    local t = status[key]
    local note = blockers[key] and ("waits on " .. table.concat(blockers[key], ", ")) or nil
    if t.status == "in_progress" then groups.in_progress[#groups.in_progress + 1] = row(t, note)
    elseif t.status == "in_review" then groups.in_review[#groups.in_review + 1] = row(t, note)
    elseif t.status == "blocked" or blockers[key] then
      -- stored "open" but waiting on a dependency: it IS blocked, so it reads as one
      local r = row(t, note); r.glyph = M.GLYPH.blocked
      groups.blocked[#groups.blocked + 1] = r
    elseif waiting[key] then groups.waiting[#groups.waiting + 1] = row(t, "waiting on its subtasks")
    else groups.ready[#groups.ready + 1] = row(t) end
  end
  local done = q("SELECT count(*) AS n FROM trk_tasks WHERE project = ? AND status IN ('done','cancelled')", { p.key })[1].n
  local sections = {}
  for _, s in ipairs{ { "In progress", "in_progress" }, { "In review", "in_review" }, { "Ready", "ready" },
                      { "Blocked", "blocked" }, { "Waiting on subtasks", "waiting" } } do
    if #groups[s[2]] > 0 then sections[#sections + 1] = { title = s[1], rows = groups[s[2]] } end
  end
  return { project = p.key, name = p.name, open = #order, done = done, next = p.key .. "-" .. p.next_seq,
           sections = sections }
end

function M.done_model(project, limit)
  tc.ensure_schema()
  local p = tc.project_row(project)
  if not p then return nil, "no such project '" .. tostring(project) .. "'" end
  local rows = {}
  for _, t in ipairs(q([[SELECT * FROM trk_tasks WHERE project = ? AND status IN ('done','cancelled')
                         ORDER BY closed_ts DESC, seq DESC LIMIT ?]], { p.key, limit or 50 })) do
    rows[#rows + 1] = row(t)
  end
  return { project = p.key, name = p.name, sections = { { title = "Done", rows = rows } } }
end

function M.tree_model(project)
  tc.ensure_schema()
  local p = tc.project_row(project)
  if not p then return nil, "no such project '" .. tostring(project) .. "'" end
  local rows, budget = {}, 400
  local function walk(parent_id, depth)
    local kids = parent_id and q("SELECT * FROM trk_tasks WHERE parent_id = ? ORDER BY sort_order", { parent_id })
      or q("SELECT * FROM trk_tasks WHERE project = ? AND parent_id IS NULL ORDER BY sort_order", { p.key })
    for _, t in ipairs(kids) do
      if budget <= 0 then return end
      budget = budget - 1
      local r = row(t); r.depth = depth
      rows[#rows + 1] = r
      walk(t.id, depth + 1)
    end
  end
  walk(nil, 0)
  return { project = p.key, name = p.name, rows = rows, truncated = budget <= 0 }
end

function M.card_model(key)
  tc.ensure_schema()
  local t = tc.task_row(key)
  if not t then return nil, "no such ticket '" .. tostring(key) .. "'" end
  local card = { key = t.key, title = t.title, status = t.status, glyph = M.GLYPH[t.status],
                 label = M.LABEL[t.status], kind = t.kind, priority = t.priority, description = t.description,
                 recipe = t.recipe ~= "" and t.recipe or nil, criteria = {}, waits = {}, blocks = {}, children = {},
                 tags = {}, commits = {} }
  if t.parent_id then
    local pt = q("SELECT key FROM trk_tasks WHERE id = ?", { t.parent_id })[1]
    card.parent = pt and pt.key
  end
  local pass = 0
  for _, c in ipairs(q("SELECT * FROM trk_criteria WHERE task_id = ? ORDER BY id", { t.id })) do
    local mark = c.last_result == "pass" and "✓" or (c.last_result == "fail" and "✗" or "·")
    if c.last_result == "pass" then pass = pass + 1 end
    card.criteria[#card.criteria + 1] = { id = c.id, mark = mark, result = c.last_result, text = c.text, test_ref = c.test_ref }
  end
  card.criteria_pass = pass
  for _, x in ipairs(q([[SELECT t.key, t.status FROM trk_deps d JOIN trk_tasks t ON t.id = d.depends_on
                         WHERE d.task_id = ? ORDER BY t.seq]], { t.id })) do
    card.waits[#card.waits + 1] = { key = x.key, status = x.status, glyph = M.GLYPH[x.status] }
  end
  for _, x in ipairs(q([[SELECT t.key, t.status FROM trk_deps d JOIN trk_tasks t ON t.id = d.task_id
                         WHERE d.depends_on = ? ORDER BY t.seq]], { t.id })) do
    card.blocks[#card.blocks + 1] = { key = x.key, status = x.status, glyph = M.GLYPH[x.status] }
  end
  for _, k in ipairs(q("SELECT * FROM trk_tasks WHERE parent_id = ? ORDER BY sort_order", { t.id })) do
    card.children[#card.children + 1] = row(k)
  end
  for _, g in ipairs(q("SELECT tag FROM trk_tags WHERE task_id = ? ORDER BY tag", { t.id })) do card.tags[#card.tags + 1] = g.tag end
  for _, c in ipairs(q("SELECT * FROM trk_commits WHERE task_id = ? ORDER BY linked_at DESC", { t.id })) do
    card.commits[#card.commits + 1] = { hash = c.commit_hash, message = c.message or "" }
  end
  return card
end

-- Board: one column per status, in workflow order.
function M.board_model(project)
  tc.ensure_schema()
  local p = tc.project_row(project)
  if not p then return nil, "no such project '" .. tostring(project) .. "'" end
  local cols = {}
  for _, s in ipairs(tc.STATUS_ORDER) do cols[#cols + 1] = { status = s, title = M.LABEL[s], glyph = M.GLYPH[s], rows = {} } end
  local idx = {}; for i, c in ipairs(cols) do idx[c.status] = i end
  -- Columns are the STORED status, but a ticket waiting on a dependency says
  -- so on its card, exactly as the list's Blocked section does -- the two
  -- views must not tell different stories about the same ticket.
  local waits = {}
  local okp, plan = pcall(tc.resolve_plan, p.key)
  if okp and plan then for _, b in ipairs(plan.blocked) do waits[b.key] = b.blockers end end
  for _, t in ipairs(q("SELECT * FROM trk_tasks WHERE project = ? ORDER BY priority, seq", { p.key })) do
    local c = cols[idx[t.status]]
    if c then
      local r = row(t, waits[t.key] and ("waits on " .. table.concat(waits[t.key], ", ")) or nil)
      if waits[t.key] then r.glyph = M.GLYPH.blocked end
      c.rows[#c.rows + 1] = r
    end
  end
  return { project = p.key, name = p.name, columns = cols }
end

-- ---- text renderers (the TUI) -------------------------------------------------------
local function key_width(rows)
  local w = 0
  for _, r in ipairs(rows) do w = math.max(w, dw(r.key)) end
  return w
end

-- "  ◐ BRAIN-35  P2 task    Expose named runs, buttons and"
-- "                          scheduled execution"
-- "                          waits on BRAIN-35"
local function render_rows(out, rows, width, kw, indent)
  indent = indent or "  "
  kw = kw or key_width(rows)
  for _, r in ipairs(rows) do
    local lead = indent .. r.glyph .. " " .. pad(r.key, kw) .. "  P" .. r.priority .. " " .. pad(r.kind, 7) .. " "
    local hang = string.rep(" ", dw(lead))
    local lines = M.wrap(r.title, width - dw(lead))
    out[#out + 1] = lead .. lines[1]
    for i = 2, #lines do out[#out + 1] = hang .. lines[i] end
    if r.note then
      for _, l in ipairs(M.wrap(r.note, width - dw(hang))) do out[#out + 1] = hang .. l end
    end
  end
end

-- Title left, counts right; when both do not fit, the counts get their own
-- line rather than running past the edge (and the title wraps if it must).
local function header(left, right, width)
  if not right or right == "" then
    return dw(left) <= width and left or table.concat(M.wrap(left, width), "\n")
  end
  local gap = width - dw(left) - dw(right)
  if gap >= 2 then return left .. string.rep(" ", gap) .. right end
  local l = dw(left) <= width and left or table.concat(M.wrap(left, width), "\n")
  return l .. "\n" .. right
end

function M.render_projects(model, width)
  width = width or 80
  if #model.projects == 0 then
    return "No projects yet. `/tracker import` brings in ai-grind's, or ask the agent to create one."
  end
  local kw = 0
  for _, p in ipairs(model.projects) do kw = math.max(kw, dw(p.key)) end
  local out = { "Projects" .. string.rep(" ", math.max(2, width - 8 - 18)) .. "open  done", "" }
  for _, p in ipairs(model.projects) do
    local counts = string.format("%4d  %4d", p.open, p.done)
    local lead = "  " .. pad(p.key, kw) .. "  "
    local room = width - dw(lead) - dw(counts) - 2
    local name = M.wrap(p.name, room)[1]
    if dw(p.name) > room then name = name:gsub("%s*%S*$", "") .. "…" end
    out[#out + 1] = lead .. pad(name, room) .. "  " .. counts
  end
  out[#out + 1] = ""
  for _, l in ipairs(M.wrap("/tracker <KEY> for what's next in a project", width)) do out[#out + 1] = l end
  return table.concat(out, "\n")
end

function M.render_next(model, width)
  width = width or 80
  local out = { header(model.project .. "  " .. model.name,
    string.format("open %d · done %d · next %s", model.open, model.done, model.next), width) }
  if #model.sections == 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Nothing open."
  end
  local all = {}
  for _, s in ipairs(model.sections) do for _, r in ipairs(s.rows) do all[#all + 1] = r end end
  local kw = key_width(all)
  for _, s in ipairs(model.sections) do
    out[#out + 1] = ""
    out[#out + 1] = s.title
    render_rows(out, s.rows, width, kw)
  end
  if model.done > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Done  " .. model.done .. "  (/tracker " .. model.project .. " done)"
  end
  return table.concat(out, "\n")
end

function M.render_done(model, width)
  width = width or 80
  local out = { header(model.project .. "  " .. model.name, "finished, most recent first", width), "" }
  local rows = model.sections[1].rows
  if #rows == 0 then out[#out + 1] = "Nothing finished yet." end
  render_rows(out, rows, width)
  return table.concat(out, "\n")
end

function M.render_tree(model, width)
  width = width or 80
  local out = { header(model.project .. "  " .. model.name, nil, width), "" }
  local kw = key_width(model.rows)
  for _, r in ipairs(model.rows) do render_rows(out, { r }, width, kw, "  " .. string.rep("  ", r.depth)) end
  if model.truncated then out[#out + 1] = "  … (first 400 shown)" end
  return table.concat(out, "\n")
end

-- Descriptions imported from ai-grind are whole planning documents in
-- markdown. For reading in a terminal: drop the markup that shows as noise
-- (heading hashes, bold stars), drop a first heading that only repeats the
-- key/title, and show the opening lines -- `/tracker KEY full` shows all.
M.CARD_DESC_LINES = 12
function M.plain_description(text, key, title)
  local lines = {}
  for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    local l = raw:gsub("^%s*#+%s*", ""):gsub("%*%*(.-)%*%*", "%1"):gsub("%s+$", "")
    lines[#lines + 1] = l
  end
  while lines[1] == "" do table.remove(lines, 1) end
  if lines[1] and ((key and lines[1]:find(key, 1, true)) or (title and lines[1]:find(title, 1, true))) then
    table.remove(lines, 1)
    while lines[1] == "" do table.remove(lines, 1) end
  end
  while lines[#lines] == "" do lines[#lines] = nil end
  return table.concat(lines, "\n")
end

-- The sectioned card: a header, then labelled sections that exist only when
-- they have content. Reads top to bottom like a document.
function M.render_card(c, width, full)
  width = width or 80
  local out = {}
  local head = c.key .. "  "
  for i, l in ipairs(M.wrap(c.title, width - dw(head))) do
    out[#out + 1] = (i == 1 and head or string.rep(" ", dw(head))) .. l
  end
  local meta = { c.glyph .. " " .. c.label, c.kind, "P" .. c.priority }
  if c.parent then meta[#meta + 1] = "parent " .. c.parent end
  out[#out + 1] = table.concat(meta, " · ")
  local desc = M.plain_description(c.description, c.key, c.title)
  if desc ~= "" then
    out[#out + 1] = ""
    local body = {}
    for para in (desc .. "\n"):gmatch("(.-)\n") do
      if para == "" then body[#body + 1] = ""
      else for _, l in ipairs(M.wrap(para, width - 2)) do body[#body + 1] = "  " .. l end end
    end
    local shown = full and #body or math.min(#body, M.CARD_DESC_LINES)
    for i = 1, shown do out[#out + 1] = body[i] end
    if shown < #body then
      for _, l in ipairs(M.wrap("… " .. (#body - shown) .. " more lines  (/tracker " .. c.key .. " full)", width - 2)) do
        out[#out + 1] = "  " .. l
      end
    end
  end
  if #c.criteria > 0 then
    out[#out + 1] = ""
    out[#out + 1] = string.format("Acceptance  %d of %d passing", c.criteria_pass, #c.criteria)
    -- Short criteria line their test refs up in a column; long ones (real
    -- criteria are often sentences) get the full width, with the ref beneath.
    local tw, rw = 0, 0
    for _, k in ipairs(c.criteria) do
      tw = math.max(tw, dw(k.text))
      rw = math.max(rw, dw(k.test_ref ~= "" and k.test_ref or "(no test linked)"))
    end
    local aligned = 4 + tw + 2 + rw <= width
    for _, k in ipairs(c.criteria) do
      local ref = (k.test_ref ~= "" and k.test_ref) or "(no test linked)"
      if aligned then
        out[#out + 1] = "  " .. k.mark .. " " .. pad(k.text, tw) .. "  " .. ref
      else
        for i, l in ipairs(M.wrap(k.text, width - 4)) do out[#out + 1] = (i == 1 and ("  " .. k.mark .. " ") or "    ") .. l end
        out[#out + 1] = "    ↳ " .. ref
      end
    end
  end
  local function refs(list)
    local t = {}
    for _, x in ipairs(list) do t[#t + 1] = x.key .. (x.status == "done" and " ✓" or (x.status == "cancelled" and " ×" or "")) end
    return table.concat(t, ", ")
  end
  local fields = {}
  if #c.waits > 0 then fields[#fields + 1] = { "Waits on", refs(c.waits) } end
  if #c.blocks > 0 then fields[#fields + 1] = { "Blocks", refs(c.blocks) } end
  if #c.tags > 0 then fields[#fields + 1] = { "Tags", table.concat(c.tags, ", ") } end
  if c.recipe then fields[#fields + 1] = { "Recipe", c.recipe } end
  if #c.commits > 0 then
    local first = c.commits[1]
    local more = #c.commits > 1 and ("  (+" .. (#c.commits - 1) .. " more)") or ""
    fields[#fields + 1] = { "Commits", first.hash:sub(1, 7) .. " " .. first.message .. more }
  end
  if #fields > 0 then
    out[#out + 1] = ""
    for _, f in ipairs(fields) do
      local lead = pad(f[1], 12)
      for i, l in ipairs(M.wrap(f[2], width - 12)) do
        out[#out + 1] = (i == 1 and lead or string.rep(" ", 12)) .. l
      end
    end
  end
  if #c.children > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Subtasks  " .. #c.children
    render_rows(out, c.children, width)
  end
  return table.concat(out, "\n")
end

-- ---- the /tracker command --------------------------------------------------------------
-- -> text for the TUI. `args` is everything after "/tracker".
function M.command(args, width)
  args = args or ""
  width = width or 80
  local a, b = args:match("^(%S*)%s*(.*)$")
  if a == "backend" then
    if b == "" then return "tracker backend: " .. tc.backend() end
    local v, e = tc.set_backend(b)
    return v and ("tracker backend = " .. v) or ("tracker: " .. e)
  elseif a == "import" then
    return tc.native{ noun = "import", path = b ~= "" and b or nil }
  elseif a == "help" then
    return "/tracker                 projects\n/tracker <PROJECT>       what's next\n"
      .. "/tracker <PROJECT> done  finished tickets\n/tracker <PROJECT> tree  the hierarchy\n"
      .. "/tracker <KEY-123>       one ticket (add `full` for the whole description)\n"
      .. "/tracker backend native|station\n/tracker import [path]"
  end
  -- The station backend holds its own store; its tool's own rendering is the
  -- honest view of it (these models read the native store).
  if tc.backend() == "station" then
    if a == "" then return tc.call{ noun = "project", action = "list" } end
    if a:match("%-%d+$") then return tc.call{ noun = "task", action = "get", key = a } end
    return tc.call{ noun = "query", view = (b == "tree" and "tree" or "tasks"), project = a }
  end
  if a == "" then return M.render_projects(M.projects_model(), width) end
  local up = a:upper()
  if up:match("^[A-Z][A-Z0-9]*%-%d+$") then
    local c, e = M.card_model(up)
    return c and M.render_card(c, width, b == "full") or ("tracker: " .. e)
  end
  local model, e
  if b == "done" then model, e = M.done_model(up); return model and M.render_done(model, width) or ("tracker: " .. e) end
  if b == "tree" then model, e = M.tree_model(up); return model and M.render_tree(model, width) or ("tracker: " .. e) end
  model, e = M.next_model(up)
  return model and M.render_next(model, width) or ("tracker: " .. e)
end

return M
