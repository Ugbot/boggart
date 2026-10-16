-- Attached pane policy; the daemon alone owns PTY/parser/negotiated encoders.
local uv=require 'uv'
local Client=require 'terminal.client'
local wire=require 'terminal.input'
local Remote={};Remote.__index=Remote
local MAX_ITEMS,MAX_BYTES=8192,32*1024*1024
local key_fields={key=true,action=true,modifiers=true,consumed_modifiers=true,right_modifiers=true,
  unshifted=true,base_layout=true,composing=true,option_as_alt=true,text=true,macos=true}
local function clock()return uv.hrtime()/1e9 end
local function issue(message)return {kind='state',message=message}end
function Remote:_changed()self.revision=self.revision+1;if self.changed then self.changed()end end
function Remote:_clear_queue()self.queue={};self.head=1;self.tail=0;self.queued_bytes=0 end
function Remote:_stop_renew()
  if self.timer then self.timer:stop();if not self.timer:is_closing()then self.timer:close()end;self.timer=nil end
  self.renew_due=false
end
function Remote:can_control()
  local s=self.session
  return not self.closed and s and s.status=='live' and (not s.pending or self.busy) and self.wants_control
    and s.controller and s.controller.expires>clock() or false
end
function Remote:_renew_later()
  self:_stop_renew()
  if not self:can_control()then return end
  local s=self.session;local timer=uv.new_timer();self.timer=timer
  local ms=math.max(1,math.floor((s.controller.expires-clock())*600))
  timer:start(ms,0,function()
    if self.timer~=timer then return end
    self.timer=nil;timer:close();self.renew_due=true;self:_pump()
  end);timer:unref()
end
function Remote:_publish(view)
  if self.image then self.image:apply(view) end -- publish native cells before pane state
  self.snapshot=view;self.error=nil;self:_changed()
end
function Remote:_disconnected(why)
  if self.closed then return end
  self.error=why or issue('Terminal observation disconnected')
  self.wants_control=false;self.conflict=false;self:_stop_renew();self:_clear_queue();self:_changed()
end
function Remote:_attach(tail)
  self.epoch=self.epoch+1;local epoch=self.epoch
  self.wants_control=false;self.conflict=false;self.error=nil;self:_stop_renew();self:_clear_queue()
  local requested=tail or self.tail_rows
  local session=self.client:attach(self.id,self.generation,{tail=requested,
    on_update=function(view)if not self.closed and self.epoch==epoch then self:_publish(view)end end,
    on_disconnect=function(why)if self.epoch==epoch then self:_disconnected(why)end end},function(why,s)
    if self.closed or self.epoch~=epoch then return end
    if why then
      -- A Studio-sized screen may fit while its requested history tail does
      -- not. This admission refusal creates no reader: retry observation once
      -- without history, retaining the exact runtime and read-only policy.
      if requested>0 and why.status==413 and type(why.response)=='table'
        and why.response.error=='attachment cell limit exceeded'then self:_attach(0);return end
      self:_disconnected(why);return
    end
    self.session=s;self:_publish(s:view())
  end)
  if self.closed or self.epoch~=epoch then session:close()else self.session=session end
  self:_changed()
end
function Remote.new(opts,changed,image)
  local self=setmetatable({id=opts.id,generation=opts.generation,tail_rows=opts.tail or 32,
    image=image,changed=changed,epoch=0,revision=0,cols=opts.cols or 80,rows=opts.rows or 24},Remote)
  self.client=Client.new(opts);self:_clear_queue();self:_attach();return self
end
function Remote:status()
  if self.closed then return 'closed'end
  if self.session and self.session.pending and not self.busy then return 'uncertain'end
  if not self.session or self.session.status~='live'then return self.session and self.session.status or 'disconnected'end
  return self:can_control() and 'controlling' or 'read-only'
end
function Remote:_finish(why)
  if self.closed then return end
  self.busy=false
  if why then
    self.error=why;self:_clear_queue()
    if self.session.pending or not self.session.controller then self.wants_control=false;self:_stop_renew()end
  else self.error=nil;self:_renew_later()end
  self:_changed()
  if not why then self:_pump()end
end
function Remote:_pump()
  if self.closed or self.busy or not self:can_control()then return end
  local s=self.session;self.busy=true
  local function done(why)self:_finish(why)end
  if self.desired and (not self.requested or self.desired.cols~=self.requested.cols or self.desired.rows~=self.requested.rows)then
    local size=self.desired;self.requested=size
    s:resize(size.cols,size.rows,done);return
  end
  if self.renew_due then
    self.renew_due=false
    s:control(false,done);return
  end
  local item=self.queue[self.head]
  if not item then self.busy=false;return end
  local events,estimate={},0
  repeat
    self.queue[self.head]=nil;self.head=self.head+1;self.queued_bytes=self.queued_bytes-item.bytes
    if item.raw then s:input(item.raw,done);return end
    events[#events+1]=item.event;estimate=estimate+item.estimate
    item=self.queue[self.head]
  until not item or item.raw or #events==64 or estimate+item.estimate>65536
  s:events(events,done)
end
function Remote:_enqueue(items,bytes)
  if not self:can_control()then return false end
  if self.tail-self.head+1+#items>MAX_ITEMS or self.queued_bytes+bytes>MAX_BYTES then
    self.error=issue('Terminal input queue is full');self:_changed();return false
  end
  if self.head>self.tail then self:_clear_queue()end
  for _,item in ipairs(items)do self.tail=self.tail+1;self.queue[self.tail]=item end
  self.queued_bytes=self.queued_bytes+bytes;self:_pump();return true
end
function Remote:event(kind,value)
  if not self:can_control()then return false end
  if kind=='key'then
    local normalized={};for k,v in pairs(value)do if key_fields[k]then normalized[k]=v end end
    normalized.macos=sys and sys.caps and sys.caps().name=='macos' or false;value=normalized
  end
  local valid,message
  if kind=='paste'then valid=type(value)=='string' and #value<=MAX_BYTES;message='Paste exceeds terminal queue limit'
  else valid,message=wire.validate{{kind=kind,value=value}}end
  if not valid then self.error=issue(message);self:_changed();return false end
  local items,bytes={},0
  local function add(v)
    local n=kind=='paste' and #v or kind=='key' and #(v.text or '') or 0
    local estimate=kind=='paste' and n+12 or kind=='key' and n*8+96 or kind=='mouse' and 64 or 3
    items[#items+1]={event={kind=kind,value=v},bytes=n,estimate=estimate};bytes=bytes+n
  end
  if kind=='paste'then
    local valid_utf8=utf8.len(value)~=nil;local at=1
    while at<=#value do
      local limit=math.min(#value+1,at+16384)
      if valid_utf8 and limit<=#value then limit=utf8.offset(value,0,limit)end
      add(value:sub(at,limit-1));at=limit
    end
    if #value==0 then add('')end
  else add(value)end
  return self:_enqueue(items,bytes)
end
function Remote:write(bytes)
  if type(bytes)~='string' or #bytes>MAX_BYTES then return nil,'Terminal input exceeds queue limit'end
  local items={};for at=1,#bytes,65536 do local part=bytes:sub(at,at+65535);items[#items+1]={raw=part,bytes=#part}end
  if not self:_enqueue(items,#bytes)then return nil,self.error and self.error.message or 'Read-only terminal'end
  return #bytes
end
function Remote:resize(cols,rows)
  self.desired={cols=cols,rows=rows};self:_pump()
end
function Remote:control(takeover)
  local s=self.session
  if self.closed or self.busy or not s or s.status~='live' or s.pending then return false end
  self.busy=true;self.conflict=false
  s:control(takeover==true,function(why)
    if self.closed then return end
    self.wants_control=not why;self.conflict=why and why.status==409 or false
    if not why then self.requested=nil end
    self:_finish(why)
  end);return true
end
function Remote:retry()
  local s=self.session
  if self.closed or self.busy or not s or not s.pending then return false end
  self.busy=true;s:retry(function(why)self:_finish(why)end);return true
end
function Remote:view_only()
  if self.closed or self.busy or self.session and self.session.pending then return false end
  self.wants_control=false;self:_stop_renew();self:_clear_queue();self.epoch=self.epoch+1
  local old=self.session;self.session=nil;self.busy=true;self:_changed()
  local function attached()
    if self.closed then return end;self.busy=false;self:_attach()
  end
  if old then old:detach(attached)else attached()end;return true
end
function Remote:reconnect()
  local s=self.session
  if self.closed or self.busy then return false end
  if not s or s.closed then self:_attach();return true end
  if s.status~='disconnected'then return false end
  self.busy=true;self.wants_control=false;self:_stop_renew();self:_clear_queue()
  s:reconnect(function(why)
    if self.closed then return end;self.busy=false
    if why and not s.pending and (why.status==403 or why.status==409)then
      s:detach(function()if not self.closed then self:_attach()end end)
    elseif why then self:_disconnected(why)
    else self:_publish(s:view())end
  end);return true
end
function Remote:close()
  if self.closed then return end
  self.closed=true;self.epoch=self.epoch+1;self:_stop_renew();self:_clear_queue();if self.image then self.image:close()end
  if self.session then self.session:detach(function()self.client:close()end)else self.client:close()end
end
function Remote:geometry()
  local v=self.snapshot;if v then return v.cols,v.rows,#v.scrollback.rows end
  return self.cols,self.rows,0
end
function Remote:state()return self.snapshot and self.snapshot.state end
function Remote:row(index,history)
  local v=self.snapshot;if v then return history and v.scrollback.rows[index] or v.screen[index]end
end
function Remote:process_revision()return self.revision end
function Remote:process_state()
  local p=self.snapshot and self.snapshot.process
  if p then return {pid=p.pid,exited=p.process_exited,eof=p.eof,error=p.error,exit_status=p.exit_status,term_signal=p.term_signal}end
end
function Remote:damage()return {}end
function Remote:ack_damage()end
function Remote:events()return {},0 end
function Remote:focus()return ''end -- real focus is dispatched as a semantic event
function Remote:input_state()return self.snapshot and self.snapshot.input_state or {mouse_mode='none'}end
return Remote
