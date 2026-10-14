-- Provider-neutral roster. Runtime adapters own execution; this owns metadata.
local M = {}; local Registry = {}; Registry.__index = Registry
local ended = { exited = true, failed = true, stopped = true }
local states = { starting=true, alive=true, unknown=true, running=true, idle=true,
  waiting_for_approval=true, waiting_for_answer=true, unreachable=true,
  exited=true, failed=true, stopped=true }
local function label(value, fallback)
  value = value or fallback
  assert(type(value) == "string" and #value > 0 and #value <= 1024 and not value:find("\0", 1, true), "invalid fleet metadata")
  return value
end
function M.new(opts)
  opts = opts or {}
  local limit=opts.max_records or 512
  assert(type(limit)=='number' and limit%1==0 and limit>=1 and limit<=4096,'invalid Fleet capacity')
  return setmetatable({ prefix=opts.prefix or serve.token(8), serial=0,
    max_records=limit, order={}, agents={}, owners={}, sources={} }, Registry)
end
function Registry:set_source(name, source)
  assert(type(name)=="string" and type(source)=="function", "invalid fleet source")
  self.sources[name] = source
end
function Registry:register(opts)
  opts = opts or {}
  local provider, name = label(opts.provider, "custom"), label(opts.name, "agent")
  if #self.order >= self.max_records then
    for i,id in ipairs(self.order) do
      if ended[self.agents[id].state] and not self.owners[id] then
        table.remove(self.order,i); self.agents[id]=nil; break
      end
    end
    assert(#self.order < self.max_records, "Fleet capacity reached")
  end
  self.serial = self.serial + 1
  local id = "external:" .. self.prefix .. ":" .. self.serial
  local rec = { id=id, short_id="E"..self.serial, generation=1, fleet_origin="external",
    provider=provider, name=name, kind=name, cwd=opts.cwd,
    session_id=opts.session_id, parent=opts.parent, state="starting",
    activity="starting process", capabilities={}, bytes=0, tools=0,
    t0=os.time(), lines={}, partial="" }
  self.agents[id]=rec; self.order[#self.order+1]=id
  return rec
end
function Registry:bind(id, generation, owner)
  local rec = assert(self.agents[id], "unknown agent")
  assert(rec.generation==generation and not ended[rec.state], "stale agent runtime")
  assert(not self.owners[id], "agent runtime already has an adapter")
  assert(type(owner)=="table", "invalid agent adapter")
  for _,action in ipairs{"poll","focus","stop"} do
    assert(owner[action]==nil or type(owner[action])=="function", "invalid adapter capability")
  end
  self.owners[id]=owner
  rec.capabilities={ focus=owner.focus~=nil, stop=owner.stop~=nil }
end
function Registry:update(id, generation, fields)
  local rec=self.agents[id]
  if not rec or rec.generation~=generation then return nil,"stale agent runtime" end
  if fields.state then assert(states[fields.state], "invalid agent state") end
  for _,key in ipairs{"state","pid","exit_status","term_signal","bytes","activity","error"} do
    if fields[key]~=nil then rec[key]=fields[key] end
  end
  if ended[rec.state] then rec.t_end=rec.t_end or os.time(); rec.capabilities.stop=false end
  return rec
end
function Registry:retire(id, generation, state, error)
  assert(ended[state or "stopped"], "retirement requires a terminal state")
  local rec,err=self:update(id,generation,{state=state or "stopped",error=error})
  if not rec then return nil,err end
  self.owners[id]=nil; rec.capabilities={}
  return rec
end
function Registry:control(id, generation, action)
  local rec=self.agents[id]; local owner=self.owners[id]
  if not rec or rec.generation~=generation then return nil,"stale agent runtime" end
  if not owner or not rec.capabilities[action] or type(owner[action])~="function" then
    return nil,"agent does not support "..tostring(action)
  end
  return owner[action](rec)
end
function Registry:poll()
  for _,id in ipairs(self.order) do
    local rec,owner=self.agents[id],self.owners[id]
    if owner and owner.poll and not ended[rec.state] then
      local ok,fields=pcall(owner.poll,rec)
      if ok and fields then self:update(id,rec.generation,fields)
      elseif not ok then self:update(id,rec.generation,{state="unreachable",error=tostring(fields):sub(1,1024)}) end
    end
  end
end
function Registry:records()
  local out,seen={},{}
  local names={};for name in pairs(self.sources) do names[#names+1]=name end;table.sort(names)
  for _,name in ipairs(names) do
    for _,rec in ipairs(self.sources[name]()) do
      assert(rec.id~=nil and not seen[rec.id], "duplicate fleet identity")
      out[#out+1]=rec;seen[rec.id]=true
    end
  end
  for _,id in ipairs(self.order) do
    assert(not seen[id],"duplicate fleet identity");out[#out+1]=self.agents[id]
  end
  return out
end
M.default=M.new()
return M
