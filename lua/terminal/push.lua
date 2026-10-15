-- Deferred native readiness -> authorized attachment channels, without timers.
local M={};local Push={};Push.__index=Push
function M.new(registry,server)
  local push=setmetatable({registry=registry,host=registry.attachments,server=server},Push)
  registry.attachments.streams=push;return push
end
function Push:connected(reader)
  return reader.channel~=nil and self.server:clients(reader.channel)>0
end
function Push:unwatch_if_idle(entry)
  for _,reader in pairs(self.host.readers)do if reader.entry==entry and reader.channel then return end end
  if entry.push_watch and entry.term then entry.term:watch(nil)end
  entry.push_watch=false
end
function Push:remove(reader)
  if reader.channel then self.server:close_streams(reader.channel);reader.channel=nil end
  self:unwatch_if_idle(reader.entry)
end
function Push:send(reader,frame)
  if not reader.channel then return end
  if not self:connected(reader) or self.server:broadcast('message',frame,reader.channel)==0 then
    reader.channel=nil;self:unwatch_if_idle(reader.entry)
  end
end
function Push:changed(entry)
  self.host:expire()
  for _,reader in pairs(self.host.readers)do if reader.entry==entry and reader.channel then
    if not self:connected(reader)then reader.channel=nil
    else
      local frame,why=self.host:capture(reader)
      if frame then self:send(reader,frame)
      elseif frame~=false then
        entry.push_error=why.message;self.host:drop(reader)
      end
    end
  end end
  self:unwatch_if_idle(entry)
end
function Push:open(entry,opts)
  local reader,why=self.host:lookup(entry,opts.attachment_id,opts.attachment_token)
  if not reader then return nil,why end
  local frame,error=self.host:updates(entry,opts);if not frame then return nil,error end
  reader.channel='terminal:'..reader.id
  if not entry.term then return nil,{status=409,message='terminal grid is closed'}end
  if not entry.push_watch or not entry.term:watch_state().active then
    entry.push_watch=true;entry.push_error=nil
    entry.term:watch(function()
      local ok,err=pcall(self.changed,self,entry)
      if not ok then
        entry.push_error='terminal push failed; reattach'
        for _,other in pairs(self.host.readers)do if other.entry==entry then self:remove(other)end end
        error(err)
      end
    end)
  end
  return 'stream',reader.channel,frame
end
return M
