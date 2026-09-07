-- stationdiag.lua -- squiggles + gutter dots from lsp_query, computed
-- against the unsaved buffer.
--
-- A studio thread watches the active document. When it changes and holds
-- still, the buffer rides the query channel as a `text` overlay with
-- format=json, so severities and column ranges come back as data. Results
-- land as one marks group per doc: kind colours the gutter dot and the
-- squiggle spans. Never inside a keystroke, never a blocked frame, stale
-- results dropped, no station means no publish.
local core = require "core"
local config = require "core.config"
local marks = require "core.marks"
local DocView = require "core.docview"
local command = require "core.command"
local json = require "json"

config.station_diagnostics = true

local GROUP = "stationdiag"

-- severity -> marks kind
local KIND = { error = "error", warning = "changed", info = "info", hint = "info" }

local state = setmetatable({}, { __mode = "k" }) -- [doc] = last change_id published

local function active_doc()
  local av = core.active_view
  return av and getmetatable(av) == DocView and av.doc or nil
end

local function publish(doc, rows)
  marks.clear_group(doc, GROUP)
  local by_line = {}
  for _, d in ipairs(rows) do
    local line = (tonumber(d.line) or 0) + 1
    local kind = KIND[d.severity] or "info"
    local col1 = (tonumber(d.col) or 0) + 1
    local col2 = (tonumber(d.end_col) or 0) + 1
    if col2 <= col1 then col2 = col1 + 1 end
    local at = by_line[line]
    if not at then
      at = { kind = kind, spans = {}, msgs = {} }
      by_line[line] = at
    end
    at.spans[#at.spans + 1] = { col1, col2 }
    at.msgs[#at.msgs + 1] = d.message
    if kind == "error" then at.kind = "error" end
  end
  for line, d in pairs(by_line) do
    marks.set(doc, line, {
      kind = d.kind, group = GROUP,
      -- Transparent wash: the squiggle carries the signal, the sign the kind.
      hl = { 0, 0, 0, 0 },
      data = { spans = d.spans, message = table.concat(d.msgs, "; ") },
    })
  end
  core.redraw = true
end

core.add_thread(function()
  while true do
    coroutine.yield(0.5)
    local stn = rawget(_G, "bog") and bog.station
    local doc = config.station_diagnostics and stn and active_doc()
    if doc and doc.filename and doc.get_change_id then
      local rev = doc:get_change_id()
      if state[doc] ~= rev and (stn.up() or stn.ensure()) then
        -- Debounce: fire only after the buffer holds still.
        coroutine.yield(0.6)
        if doc:get_change_id() == rev then
          state[doc] = rev
          local abs = system.absolute_path(doc.filename) or doc.filename
          local okr, h = pcall(function()
            return stn.conn:request("query", "tool_exec", "lsp_query", {
              operation = "diagnostics",
              uri = "file://" .. abs,
              text = table.concat(doc.lines),
              format = "json",
            }, 4000)
          end)
          if okr and h then
            while not h:done() do coroutine.yield(0.03) end
            local p = h:wait()
            if doc:get_change_id() == rev then -- drop stale results
              local rows = {}
              if p and p.ok ~= "false" and p.data then
                local okj, decoded = pcall(json.decode, p.data)
                if okj and type(decoded) == "table" then rows = decoded end
              end
              publish(doc, rows)
            else
              state[doc] = nil -- buffer moved: ask again next round
            end
          end
        end
      end
    end
  end
end)

command.add(nil, {
  ["station-diagnostics:toggle"] = function()
    config.station_diagnostics = not config.station_diagnostics
    if not config.station_diagnostics then
      local doc = active_doc()
      if doc then marks.clear_group(doc, GROUP) end
    end
    core.log("station diagnostics: %s", config.station_diagnostics and "on" or "off")
  end,
})

return {}
