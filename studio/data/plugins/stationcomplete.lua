-- stationcomplete.lua -- LLM Station completions in the editor popup.
--
-- Feeds the existing autocomplete popup (plugins/autocomplete.lua) with
-- ranked, index-backed candidates from a running LLM Station daemon over the
-- native ZMQ transport (lua/stationlink.lua): member/scope/import context
-- detection and same-file > same-scope > imported > global ranking, at
-- query-channel latency (~1ms round trip).
--
-- The keystroke rule is absolute -- nothing here runs inside one. A studio
-- thread watches the caret, waits for the buffer to hold still for a beat,
-- fires ONE query-channel request, and polls the handle with done() (a
-- non-blocking drain) so no frame ever waits on a socket. Results are
-- published only if the prefix and caret still match what was asked
-- (request staleness, the CompletionManager rule), and land in the popup via
-- autocomplete.add + autocomplete.refresh.
--
-- Strictly additive: no station binary, no daemon, or a mid-flight crash
-- mean this thread finds stationlink down and publishes nothing -- the
-- buffer-symbol provider keeps working exactly as before.
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

-- smart_complete's wire format: "completions: N\ncontext: c\n---\n" then one
-- "label\tkind\tdetail" row per candidate. The popup wants {text = info}.
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
        -- Debounce: fire only when the buffer held still for a beat.
        coroutine.yield(0.12)
        local p2, l2, c2 = partial_at(doc)
        if p2 == prefix and l2 == line and c2 == col
           and (stn.up() or stn.ensure()) then
          last_key = key
          local okr, h = pcall(function()
            -- column is 0-based on the wire; the live prefix compensates for
            -- unsaved edits the daemon's index has not seen.
            return stn.conn:request("query", "tool_exec", "smart_complete", {
              file = doc.filename, line = tostring(line),
              column = tostring(col - 1), prefix = prefix, limit = "8",
            }, 800)
          end)
          if okr and h then
            while not h:done() do coroutine.yield(0.02) end
            local p = h:wait()
            local out = p and p.ok ~= "false" and p.data or nil
            -- Publish only if the ask is still current (staleness rule).
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
