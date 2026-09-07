-- stationcomplete.lua -- LLM Station completions in the editor popup.
--
-- Feeds the autocomplete popup with ranked candidates from the daemon over
-- ZMQ (lua/stationlink.lua), at query-channel latency (~1ms round trip).
--
-- Nothing here runs inside a keystroke. A studio thread watches the caret,
-- waits for the buffer to hold still, fires one query-channel request, and
-- polls the handle with done() so no frame waits on a socket. Results
-- publish only if prefix and caret still match the ask, via
-- autocomplete.add + autocomplete.refresh.
--
-- Additive: no daemon, or a mid-flight crash, and this thread publishes
-- nothing; the buffer-symbol provider works as before.
local core = require "core"
local config = require "core.config"
local autocomplete = require "plugins.autocomplete"
local translate = require "core.doc.translate"
local DocView = require "core.docview"
local command = require "core.command"

config.station_complete = true

local function active_docview()
  local av = core.active_view
  return (av and getmetatable(av) == DocView and av.doc) and av or nil
end

local function partial_at(doc)
  local line2, col2 = doc:get_selection()
  local line1, col1 = doc:position_offset(line2, col2, translate.start_of_word)
  return doc:get_text(line1, col1, line2, col2), line2, col2
end

-- Wire format: "completions: N\ncontext: c\n---\n" then label\tkind\tdetail rows.
local function parse(out)
  local items, n = {}, 0
  local body = out:match("%-%-%-\n(.*)$") or ""
  for row in body:gmatch("[^\n]+") do
    local label, kind = row:match("^([^\t]+)\t([^\t]*)")
    if label and label ~= "" then
      items[label] = (kind ~= "" and kind) or nil
      n = n + 1
    end
  end
  return items, n
end

core.add_thread(function()
  local last_key
  while true do
    coroutine.yield(0.1)
    local stn = rawget(_G, "bog") and bog.station
    local dv = config.station_complete and stn and active_docview()
    local doc = dv and dv.doc
    if doc and doc.filename then
      local prefix, line, col = partial_at(doc)
      local key = doc.filename .. ":" .. line .. ":" .. col .. ":" .. prefix
      if #prefix >= 3 and key ~= last_key then
        -- Debounce: fire only after the buffer holds still.
        coroutine.yield(0.12)
        local p2, l2, c2 = partial_at(doc)
        if p2 == prefix and l2 == line and c2 == col
           and (stn.up() or stn.ensure()) then
          last_key = key
          local okr, h = pcall(function()
            -- Column is 0-based on the wire; the live prefix covers unsaved edits.
            return stn.conn:request("query", "tool_exec", "smart_complete", {
              file = doc.filename, line = tostring(line),
              column = tostring(col - 1), prefix = prefix, limit = "8",
            }, 800)
          end)
          if okr and h then
            while not h:done() do coroutine.yield(0.02) end
            local p = h:wait()
            local out = p and p.ok ~= "false" and p.data or nil
            -- Publish only if the ask is still current.
            local p3, l3 = partial_at(doc)
            if p3 == prefix and l3 == line then
              local items = out and parse(out) or {}
              autocomplete.add { name = "station", files = ".*", items = items }
              autocomplete.refresh()
              core.redraw = true
            end
          end
        end
      end
    end
  end
end)

command.add(nil, {
  ["station-complete:toggle"] = function()
    config.station_complete = not config.station_complete
    if not config.station_complete then
      autocomplete.add { name = "station", files = ".*", items = {} }
    end
    core.log("station completions: %s", config.station_complete and "on" or "off")
  end,
})

return {}
