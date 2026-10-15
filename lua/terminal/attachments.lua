-- Independent readers and one explicit, renewable input/resize controller.
local uv=require 'uv';local json=require 'json'
local M={};local Host={};Host.__index=Host
local function fail(status,message)return nil,{status=status,message=message}end
local function integer(n,low,high)return type(n)=='number' and n%1==0 and n>=low and n<=high end
local function token(expected,provided)return type(provided)=='string' and #provided<=128 and serve.verify_token(expected,provided)end
local function array(t)return #t>0 and t or json.array end
function M.new(registry,opts)
  opts=opts or {}
  local host=setmetatable({registry=registry,readers={},count=0,bytes=0,
    clock=opts.clock or function()return uv.hrtime()/1e9 end,max_readers=opts.max_readers or 128,
    ttl=opts.ttl or 30,lease_ttl=opts.lease_ttl or 10,max_frame=opts.max_frame or 4*1024*1024,
    max_bytes=opts.max_bytes or 32*1024*1024},Host)
  assert(integer(host.max_readers,1,4096) and host.ttl>0 and host.lease_ttl>0 and host.lease_ttl<=host.ttl
    and integer(host.max_frame,1,64*1024*1024) and integer(host.max_bytes,1,256*1024*1024),'invalid attachment limits')
  return host
end
function Host:drop(reader)
  self.readers[reader.id]=nil;self.count=self.count-1;self.bytes=self.bytes-#reader.frame
  if reader.entry.controller and reader.entry.controller.reader==reader.id then reader.entry.controller=nil end
end
function Host:expire()
  local now=self.clock()
  for _,reader in pairs(self.readers)do
    if reader.expires<=now or self.registry.entries[reader.entry.id]~=reader.entry then self:drop(reader)end
  end
end
function Host:retire(entry)
  for _,reader in pairs(self.readers)do if reader.entry==entry then self:drop(reader)end end
  entry.controller=nil
end
function Host:lookup(entry,id,secret)
  self:expire();local reader=type(id)=='string' and self.readers[id]
  if not reader or reader.entry~=entry or reader.generation~=entry.generation or not token(reader.token,secret)then return fail(403,'invalid or expired attachment')end
  return reader
end
local function stamp(host,entry,tail)
  local versions=entry.term:row_versions(tail);local state=entry.term:state();local process=host.registry:status(entry)
  return json.encode{versions,state,process},versions,state,process
end
function Host:capture(reader,initial)
  local entry=reader.entry
  if not entry.term then return fail(409,'terminal grid is closed')end
  local signature,versions,state,process=stamp(self,entry,reader.tail)
  if signature==reader.signature then return false end
  if versions.cols*(versions.rows+#versions.scrollback)>32768 then return fail(413,'attachment cell limit exceeded')end
  local previous=reader.versions
  local full=not previous or previous.cols~=versions.cols or previous.rows~=versions.rows or reader.alternate~=state.alternate
  local screen,changes={},{}
  for y,revision in ipairs(versions.screen)do
    if full then screen[#screen+1]=entry.term:row(y)
    elseif revision~=previous.screen[y]then changes[#changes+1]={index=y,row=entry.term:row(y)}end
  end
  local history=false
  if full or previous.history~=versions.history or json.encode(previous.scrollback)~=json.encode(versions.scrollback)then
    local rows={};local first=versions.history-#versions.scrollback+1
    for i=1,#versions.scrollback do rows[#rows+1]=entry.term:row(first+i-1,true)end
    history={first=first,total=versions.history,rows=array(rows)}
  end
  if stamp(self,entry,reader.tail)~=signature then return fail(409,'terminal changed during capture; retry')end
  local frame={v=1,id=entry.id,generation=entry.generation,attachment_id=reader.id,
    after=reader.cursor,cursor=reader.cursor+1,kind=full and 'snapshot' or 'delta',
    cols=versions.cols,rows=versions.rows,state=state,process=process,scrollback=history}
  if full then frame.screen=array(screen)else frame.changes=array(changes)end
  if initial then frame.attachment_token=reader.token;frame.reader_seconds=self.ttl end
  local encoded=json.encode(frame)
  if #encoded>self.max_frame or self.bytes+#encoded-#reader.frame>self.max_bytes then return fail(503,'attachment frame capacity reached')end
  self.bytes=self.bytes+#encoded-#reader.frame
  reader.frame=encoded;reader.cursor=frame.cursor;reader.signature=signature;reader.versions=versions;reader.alternate=state.alternate
  return encoded
end
function Host:attach(entry,opts)
  self:expire()
  local tail=opts.tail==nil and 32 or opts.tail
  if not integer(opts.generation,1,9007199254740991) or opts.generation~=entry.generation or not integer(tail,0,256)then return fail(400,'invalid attachment options')end
  if not entry.term or entry.closed then return fail(409,'terminal grid is closed')end
  if self.count>=self.max_readers then return fail(503,'attachment capacity reached')end
  if entry.cols*(entry.rows+math.min(tail,entry.history))>32768 then return fail(413,'attachment cell limit exceeded')end
  local reader={entry=entry,generation=entry.generation,id=serve.token(12),token=serve.token(24),tail=tail,
    expires=self.clock()+self.ttl,cursor=0,frame=''}
  local controlled=entry.controlled;entry.controlled=true
  local frame,why=self:capture(reader,true);if not frame then entry.controlled=controlled;return nil,why end
  self.readers[reader.id]=reader;self.count=self.count+1
  return frame
end
function Host:updates(entry,opts)
  local reader,why=self:lookup(entry,opts.attachment_id,opts.attachment_token);if not reader then return nil,why end
  if not integer(opts.after,0,9007199254740991) or opts.after>reader.cursor or opts.after<reader.cursor-1 then return fail(409,'attachment cursor unavailable; reattach')end
  reader.expires=self.clock()+self.ttl
  local owner=entry.controller
  if opts.control_token~=nil then
    if not owner or owner.reader~=reader.id or owner.expires<=self.clock() or not token(owner.token,opts.control_token)then return fail(403,'invalid or expired controller')end
    owner.expires=self.clock()+self.lease_ttl
  end
  if opts.after==reader.cursor-1 then return reader.frame end
  local frame,error=self:capture(reader)
  if frame~=false then return frame,error end
  return json.encode{v=1,id=entry.id,generation=entry.generation,attachment_id=reader.id,after=reader.cursor,cursor=reader.cursor,kind='unchanged'}
end
function Host:control(entry,opts)
  local reader,why=self:lookup(entry,opts.attachment_id,opts.attachment_token);if not reader then return nil,why end
  if opts.takeover~=nil and type(opts.takeover)~='boolean'then return fail(400,'invalid controller request')end
  local owner=entry.controller;local now=self.clock()
  if owner and owner.expires>now and owner.reader~=reader.id and not opts.takeover then return fail(409,'terminal already has a controller')end
  if owner and owner.expires>now and owner.reader==reader.id then
    if not token(owner.token,opts.control_token)then return fail(403,'controller token required to renew')end
    owner.expires=now+self.lease_ttl
  else owner={reader=reader.id,token=serve.token(24),expires=now+self.lease_ttl,sequence=0};entry.controller=owner end
  reader.expires=now+self.ttl
  return json.encode{v=1,id=entry.id,generation=entry.generation,attachment_id=reader.id,
    control_token=owner.token,lease_seconds=self.lease_ttl}
end
function Host:detach(entry,opts)
  local reader,why=self:lookup(entry,opts.attachment_id,opts.attachment_token);if not reader then return nil,why end
  self:drop(reader);return json.encode{v=1,detached=true}
end
function Host:command(entry,credentials,kind,payload,execute)
  if not entry.controlled then return execute()end
  if type(credentials)~='table'then return fail(403,'terminal controller required')end
  local reader,why=self:lookup(entry,credentials.attachment_id,credentials.attachment_token);if not reader then return nil,why end
  local owner=entry.controller;local sequence=credentials.command_seq
  if not owner or owner.reader~=reader.id or owner.expires<=self.clock() or not token(owner.token,credentials.control_token)then return fail(403,'invalid or expired controller')end
  if not integer(sequence,1,9007199254740991)then return fail(400,'invalid controller command sequence')end
  local key=json.encode{kind,payload}
  if sequence==owner.sequence and key==owner.command then return json.decode(owner.result)end
  if sequence<=owner.sequence then return fail(409,'stale controller command')end
  local result,error=execute();if not result then return nil,error end
  owner.sequence=sequence;owner.command=key;owner.result=json.encode(result)
  owner.expires=self.clock()+self.lease_ttl;reader.expires=self.clock()+self.ttl
  return result
end
function Host:resize_allowed(entry,cols,rows)
  self:expire();local tail=0
  for _,reader in pairs(self.readers)do if reader.entry==entry then tail=math.max(tail,reader.tail)end end
  return cols*(rows+math.min(tail,entry.history))<=32768
end
return M
