-- Shared state for Studio and cTUI session controls; no rendering or polling.
local Client=require 'bmux.sessionclient';local Files=require 'bmux.sessionfiles';local Codec=require 'bmux.checkpoint'
local M={};local Actions={};Actions.__index=Actions
function M.new(opts,changed)return setmetatable({client=Client.new(opts),changed=changed},Actions)end
function Actions:_notify()if self.changed then self.changed(self)end end
function Actions:_begin()
  if self.closed or self.busy then return false end
  self.busy=true;self.error=nil;self.message='Working…';self:_notify();return true
end
function Actions:_finish(why,message)
  if self.closed then return end
  self.busy=false;self.error=why;self.message=why and why.message or message;self:_notify()
end
function Actions:refresh()
  if not self:_begin()then return end
  self.client:status(function(why,value)
    if self.closed then return end
    if not why then self.info=value end
    self:_finish(why,not why and self:summary())
  end)
end
function Actions:summary()
  local info=self.info
  if not info then return 'Session status not loaded'end
  if not info.persistent then return 'This server is not saving a named session'end
  return info.name..' · '..(info.blocked and('Recovery needed: '..(info.error or 'checkpoint unavailable'))
    or info.dirty and 'Save pending'or info.restored and 'Restored; saved'or 'Saved')
end
function Actions:export(path)
  if not self:_begin()then return end
  self.client:export(function(why,raw)
    if self.closed then return end
    if not why then local saved;saved,why=Files.write(path,raw)end
    self:_finish(why,not why and('Exported to '..path))
  end)
end
function Actions:import(path,name)
  if not self:_begin()then return end
  local raw,why=Files.read(path)
  if not raw then self:_finish(why);return end
  self.import_name=name
  self.client:import(name,raw,function(error,value)
    if self.closed then return end
    if not error then self.saved_name=value.name end
    self:_finish(error,not error and('Saved inactive session '..name..'; open it explicitly to view saved output'))
  end)
end
function Actions:inspect(name)
  if not self:_begin()then return end
  self.client:saved(name,function(why,raw)
    if self.closed then return end
    if why then self:_finish(why);return end
    local doc=assert(Codec.decode(raw));local inactive=true
    for _,t in ipairs(doc.terminals)do if t.launch~='saved'then inactive=false end end
    for _,a in ipairs(doc.agents)do if a.launch~='saved'then inactive=false end end
    self.saved_name=name
    self:_finish(nil,name..': '..#doc.layout.workspaces..' workspaces, '..#doc.terminals..' terminals, '..#doc.agents
      ..' agents'..(inactive and '; all inactive'or '; local restart recipes present'))
  end)
end
function Actions:close()
  if self.closed then return end;self.closed=true;self.client:close()
end
return M
