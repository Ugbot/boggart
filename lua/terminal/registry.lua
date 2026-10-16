-- Server-owned PTYs. Client connections never own or release these objects.
local terminal=require 'terminal';local uv=require 'uv'
local M={};local Registry={};Registry.__index=Registry
local ended={exited=true,failed=true,stopped=true}
local function failure(status,message)return nil,{status=status,message=message}end
local function integer(n,low,high)return type(n)=='number' and n%1==0 and n>=low and n<=high end
local function string_value(s,limit,empty)return type(s)=='string' and (empty or #s>0) and #s<=limit and not s:find('\0',1,true)end
local function only(t,keys)
  for key in pairs(t)do if not keys[key]then return false end end;return true
end
local function value(t,key,fallback)if t[key]==nil then return fallback end;return t[key]end
local function strings(values,max_count,max_length)
  if values==nil then return {}end
  if type(values)~='table' or #values>max_count then return end
  local out,bytes={},0
  for key,value in pairs(values)do
    if not integer(key,1,#values) or not string_value(value,max_length,true)then return end
    bytes=bytes+#value;if bytes>65536 then return end;out[key]=value
  end
  for i=1,#values do if out[i]==nil then return end end
  return out
end
function M.new(opts)
  if opts==nil then opts={}end
  local count,cells=opts.max_records or 256,opts.max_cells or 32*1024*1024
  assert(integer(count,1,4096) and integer(cells,1,128*1024*1024),'invalid terminal registry limits')
  local registry=setmetatable({prefix=serve.token(12),serial=0,entries={},order={},used=0,
    max_records=count,max_cells=cells,closed=false,listeners={},listener_errors={}},Registry)
  registry.attachments=require('terminal.attachments').new(registry,opts.attachments)
  return registry
end
function Registry:watch(key,callback)
  assert(type(key)=='string'and #key>0 and #key<=64,'invalid terminal lifecycle observer')
  assert(callback==nil or type(callback)=='function','invalid terminal lifecycle callback')
  local n=0;for _ in pairs(self.listeners)do n=n+1 end
  assert(callback==nil or self.listeners[key]or n<8,'terminal lifecycle observer capacity reached')
  self.listeners[key]=callback;self.listener_errors[key]=nil
end
function Registry:_changed(entry,event)
  local listeners={};for key,callback in pairs(self.listeners)do listeners[#listeners+1]={key,callback}end
  for _,v in ipairs(listeners)do if self.listeners[v[1]]==v[2]then
    local ok,why=pcall(v[2],entry,event)
    if not ok then self.listeners[v[1]]=nil;self.listener_errors[v[1]]=tostring(why):sub(1,256)end
  end end
end
function Registry:status(entry)
  if entry.term and not entry.frozen then
    local p=entry.term:process_state()
    entry.pid=p.pid;entry.exit_status=p.exit_status;entry.term_signal=p.term_signal
    entry.bytes=p.bytes_read;entry.queued_bytes=p.queued_bytes;entry.error=p.error
    entry.state=p.exited and p.eof and (p.exit_status==0 and p.term_signal==0 and 'exited' or 'failed')
      or p.error and 'failed' or 'alive'
    entry.process_exited=p.exited;entry.eof=p.eof
    entry.revision=p.revision
  end
  return {id=entry.id,generation=entry.generation,state=entry.state,cmd=entry.cmd,cwd=entry.cwd,
    cols=entry.cols,rows=entry.rows,history=entry.history,pid=entry.pid,exit_status=entry.exit_status,
    term_signal=entry.term_signal,bytes=entry.bytes or 0,queued_bytes=entry.queued_bytes or 0,
    process_exited=entry.process_exited,eof=entry.eof,error=entry.error,closed=entry.closed or false,
    attachment_controlled=entry.controlled==true,push_error=entry.push_error,revision=entry.revision or 0}
end
function Registry:find(id,generation)
  if self.closed then return failure(503,'terminal registry stopped')end
  local entry=type(id)=='string' and self.entries[id]
  if not entry then return failure(404,'unknown terminal')end
  if generation~=nil and generation~=entry.generation then return failure(409,'stale terminal runtime')end
  return entry
end
-- Trusted in-process observers share a single native readiness callback.
function Registry:_notify(entry,event)
  local listeners={}
  for key,callback in pairs(entry.observers or {})do listeners[#listeners+1]={key,callback}end
  for _,listener in ipairs(listeners)do
    local key,callback=listener[1],listener[2]
    if entry.observers[key]==callback then
      local ok,why=pcall(callback,entry,event)
      if not ok then
        entry.observer_errors[key]=tostring(why):sub(1,256);entry.observers[key]=nil
      end
    end
  end
  if entry.term and not next(entry.observers)then entry.term:watch(nil)end
end
function Registry:observing(entry,key)return entry.observers and entry.observers[key]~=nil or false end
function Registry:observe(entry,key,callback)
  assert(self.entries[entry.id]==entry,'unknown terminal observer owner')
  assert(type(key)=='string' and #key>0 and #key<=64,'invalid terminal observer key')
  entry.observers=entry.observers or {};entry.observer_errors=entry.observer_errors or {}
  if callback==nil then
    entry.observers[key]=nil
    if entry.term and not next(entry.observers)then entry.term:watch(nil)end
    return true
  end
  assert(type(callback)=='function','invalid terminal observer callback')
  if self.closed or entry.closed or not entry.term then return failure(409,'terminal grid is closed')end
  local count=0;for _ in pairs(entry.observers)do count=count+1 end
  if not entry.observers[key] and count>=8 then return failure(503,'terminal observer capacity reached')end
  entry.observers[key]=callback;entry.observer_errors[key]=nil
  -- A new subscriber needs an initial coherent image even if the PTY is idle.
  entry.term:watch(function()self:_notify(entry,'changed')end)
  return true
end
function Registry:release(entry)
  if entry.closed then return end
  self.attachments:retire(entry)
  if entry.term then self:status(entry);entry.term:close();entry.term=nil end
  if not ended[entry.state]then entry.state='stopped'end
  entry.closed=true
  self.used=self.used-entry.cost;entry.cost=0
  if entry.observers then self:_notify(entry,'released');entry.observers={}end
  self:_changed(entry,'released')
end
function Registry:reserve(cost,exclude)
  if cost>self.max_cells then return false end
  local index=1
  while (self.used+cost>self.max_cells or not exclude and #self.order>=self.max_records) and index<=#self.order do
    local id=self.order[index];local entry=self.entries[id]
    if entry~=exclude and ended[self:status(entry).state] and (not entry.term or entry.process_exited and entry.eof)then
      self:release(entry);self.entries[id]=nil;table.remove(self.order,index)
    else index=index+1 end
  end
  return self.used+cost<=self.max_cells and (exclude~=nil or #self.order<self.max_records)
end
function Registry:open(opts,bootstrap)
  if self.closed then return failure(503,'terminal registry stopped')end
  assert(bootstrap==nil or type(bootstrap)=='table' and only(bootstrap,{control=true})
    and type(bootstrap.control)=='boolean','invalid trusted terminal bootstrap')
  if opts==nil then opts={}end
  if type(opts)~='table' or not only(opts,{cmd=true,args=true,cwd=true,env=true,cols=true,rows=true,history=true})then return failure(400,'invalid terminal options')end
  local cmd,cwd=value(opts,'cmd',os.getenv('SHELL') or '/bin/sh'),value(opts,'cwd',uv.cwd())
  local cols,rows,history=value(opts,'cols',80),value(opts,'rows',24),value(opts,'history',2000)
  local args,env=strings(opts.args,128,16384),strings(opts.env,64,65536)
  if not string_value(cmd,4096) or not string_value(cwd,4096) or not args or not env
    or not integer(cols,1,4096) or not integer(rows,1,4096) or not integer(history,0,100000)then return failure(400,'invalid terminal options')end
  if cwd:sub(1,1)~='/'and not cwd:match('^%a:[/\\]')and cwd:sub(1,2)~='\\\\'then cwd=uv.cwd()..'/'..cwd end
  if #cwd>4096 then return failure(400,'terminal working directory exceeds limit')end
  local names={}
  for _,value in ipairs(env)do
    local name=value:match('^([A-Za-z_][A-Za-z_0-9]*)=')
    if not name or #name>128 or names[name]then return failure(400,'invalid terminal environment')end;names[name]=true
  end
  local cost=cols*(rows+history)
  if not self:reserve(cost)then return failure(503,'terminal registry capacity reached')end
  self.serial=self.serial+1
  local entry={id='term-'..self.prefix..'-'..self.serial,generation=1,cmd=cmd,cwd=cwd,
    cols=cols,rows=rows,history=history,cost=cost,state='starting',
    restore_shell=opts.cmd==nil and #args==0 and #env==0 and not(bootstrap and bootstrap.control)}
  self.entries[entry.id]=entry;self.order[#self.order+1]=entry.id;self.used=self.used+cost
  local called,term,why=pcall(terminal.open,{cmd=cmd,cwd=cwd,args=args,env=env,cols=cols,rows=rows,history=history,
    control=bootstrap and bootstrap.control or false})
  if called and term then entry.term=term
  else entry.state='failed';entry.error=tostring(called and why or term);self.used=self.used-entry.cost;entry.cost=0 end
  local status=self:status(entry);self:_changed(entry,'opened');return status
end
-- Trusted restore-only constructor: a parser/image with no PTY or input owner.
function Registry:preview(saved,why,existing)
  if self.closed then return failure(503,'terminal registry stopped')end
  local cost=saved.cols*(saved.rows+saved.history)
  if not self:reserve(existing and math.max(0,cost-existing.cost)or cost,existing)then return failure(503,'terminal preview capacity reached')end
  local ok,term=pcall(terminal.new,saved.cols,saved.rows,saved.history)
  if not ok then return failure(503,'terminal preview allocation failed')end
  local entry=existing
  if entry then assert(self.entries[entry.id]==entry and not entry.term and not entry.closed,'preview cannot replace a process')
  else
    self.serial=self.serial+1;entry={id='term-'..self.prefix..'-'..self.serial,generation=1,cost=0}
    self.entries[entry.id]=entry;self.order[#self.order+1]=entry.id
  end
  self.used=self.used+cost-entry.cost;entry.cost=cost
  entry.term=term;entry.frozen=true;entry.cmd=saved.program or '';entry.cwd=saved.cwd
  entry.cols,entry.rows,entry.history=saved.cols,saved.rows,saved.history
  entry.state='stopped';entry.process_exited=true;entry.eof=true;entry.pid=nil;entry.exit_status=-1;entry.term_signal=0
  entry.bytes=0;entry.queued_bytes=0;entry.error=why or 'Saved terminal; process is inactive';entry.restore_shell=false
  self:_changed(entry,'opened');return self:status(entry)
end
function Registry:get(id)
  local entry,why=self:find(id);if not entry then return nil,why end;return self:status(entry)
end
function Registry:list(offset,limit)
  if self.closed then return failure(503,'terminal registry stopped')end
  offset,limit=offset or 0,limit or 64
  if not integer(offset,0,4096) or not integer(limit,1,64)then return failure(400,'invalid terminal page')end
  local out={}
  for i=offset+1,math.min(#self.order,offset+limit)do out[#out+1]=self:status(self.entries[self.order[i]])end
  return {terminals=#out>0 and out or require('json').array,total=#self.order,
    next_offset=offset+#out<#self.order and offset+#out or require('json').null}
end
function Registry:write(id,generation,text,credentials)
  local entry,why=self:find(id,generation);if not entry then return nil,why end
  if entry.frozen then return failure(409,'saved terminal has no running process')end
  if not integer(generation,1,9007199254740991) or type(text)~='string' or #text>65536 then return failure(400,'invalid terminal input')end
  return self.attachments:command(entry,credentials,'input',{text=text},function()
    if not entry.term or self:status(entry).process_exited then return failure(409,'terminal is not running')end
    local bytes,error=entry.term:write(text)
    if not bytes then return failure(409,error)end
    return {id=id,generation=generation,accepted_bytes=bytes}
  end)
end
function Registry:resize(id,generation,cols,rows,credentials)
  local entry,why=self:find(id,generation);if not entry then return nil,why end
  if entry.frozen then return failure(409,'saved terminal has no running process')end
  if not integer(generation,1,9007199254740991) or not integer(cols,1,4096) or not integer(rows,1,4096)then return failure(400,'invalid terminal geometry')end
  return self.attachments:command(entry,credentials,'resize',{cols=cols,rows=rows},function()
    if not entry.term then return failure(409,'terminal is closed')end
    if entry.controlled and not self.attachments:resize_allowed(entry,cols,rows)then return failure(413,'attachment cell limit exceeded')end
    local cost=cols*(rows+entry.history);local extra=math.max(0,cost-entry.cost)
    if not self:reserve(extra,entry)then return failure(503,'terminal registry capacity reached')end
    local ok,error=pcall(entry.term.resize,entry.term,cols,rows)
    if not ok then return failure(409,tostring(error))end
    self.used=self.used+cost-entry.cost;entry.cost=cost;entry.cols=cols;entry.rows=rows;self:_changed(entry,'resized')
    return self:status(entry)
  end)
end
function Registry:input_events(id,generation,events,credentials)
  local entry,why=self:find(id,generation);if not entry then return nil,why end
  if entry.frozen then return failure(409,'saved terminal has no running process')end
  if not integer(generation,1,9007199254740991)then return failure(400,'invalid terminal generation')end
  local valid,message=require('terminal.input').validate(events)
  if not valid then return failure(400,message)end
  return self.attachments:command(entry,credentials,'events',{events=events},function()
    if not entry.term or self:status(entry).process_exited then return failure(409,'terminal is not running')end
    local ok,bytes,error=pcall(entry.term.send_events,entry.term,events)
    if not ok then return failure(400,'invalid native input event')end
    if bytes==nil then return failure(409,error)end
    return {id=id,generation=generation,accepted_bytes=bytes,accepted_events=#events}
  end)
end
function Registry:screen(id,first,count)
  local entry,why=self:find(id);if not entry then return nil,why end
  if not entry.term then return failure(409,'terminal grid is closed')end
  first=first or 1;count=count or math.min(entry.rows,64,math.floor(32768/entry.cols))
  if not integer(first,1,entry.rows) or not integer(count,1,64) or count*entry.cols>32768 then return failure(400,'invalid terminal screen page')end
  local rows={}
  for y=first,math.min(entry.rows,first+count-1)do rows[#rows+1]=entry.term:row(y)end
  return {id=id,generation=entry.generation,cols=entry.cols,rows=entry.rows,first=first,
    screen=rows,state=entry.term:state(),process=self:status(entry)}
end
function Registry:close(id,generation)
  local entry,why=self:find(id,generation);if not entry then return nil,why end
  if not integer(generation,1,9007199254740991)then return failure(400,'invalid terminal generation')end
  if entry.closed then return self:status(entry)end
  self:status(entry);self:release(entry)
  if not ended[entry.state] then entry.state='stopped'end
  entry.closed=true;return self:status(entry)
end
function Registry:shutdown()
  if self.closed then return end
  self.closed=true
  for _,id in ipairs(self.order)do self:release(self.entries[id])end
end
return M
