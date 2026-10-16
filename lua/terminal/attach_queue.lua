-- Initial snapshot + stream handshakes only. Owners cancel transport before
-- finishing an active ticket. No timers; established streams/controls bypass it.
local M={};local Queue={};Queue.__index=Queue;local Ticket={};Ticket.__index=Ticket
function M.new(limit,capacity)
  limit=limit or 4;capacity=capacity or 256
  assert(math.type(limit)=='integer'and limit>=1 and limit<=256)
  assert(math.type(capacity)=='integer'and capacity>=limit and capacity<=4096)
  return setmetatable({limit=limit,capacity=capacity,active=0,count=0,pending={},tickets={}},Queue)
end
function Ticket:finish()
  if self.state=='done'then return end
  local q=self.queue
  if self.state=='active'then q.active=q.active-1
  else for i,t in ipairs(q.pending)do if t==self then table.remove(q.pending,i);break end end end
  self.state='done';q.count=q.count-1;q.tickets[self]=nil
  self.start=nil;self.reject=nil;q:_pump()
end
function Queue:_pump()
  if self.closed or self.pumping then return end
  self.pumping=true;local thrown
  while self.active<self.limit and #self.pending>0 do
    local t=table.remove(self.pending,1);t.state='active';self.active=self.active+1
    local reject=t.reject;local ok=pcall(t.start,t)
    if not ok then
      t:finish()
      local reported,why=pcall(reject,{kind='state',message='attachment initialization failed'},t)
      if not reported then thrown=why end
    end
  end
  self.pumping=false;if thrown then error(thrown,0)end
end
function Queue:submit(start,reject)
  assert(type(start)=='function'and type(reject)=='function')
  local t=setmetatable({queue=self,state='done'},Ticket)
  if self.closed or self.count>=self.capacity then
    reject({kind=self.closed and 'closed'or 'capacity',message=self.closed and 'attachment queue closed'or 'attachment queue capacity reached'},t)
    return t
  end
  t.state='queued';t.start=start;t.reject=reject
  self.pending[#self.pending+1]=t;self.tickets[t]=true;self.count=self.count+1;self:_pump();return t
end
function Queue:close()
  if self.closed then return end;self.closed=true
  local pending={table.unpack(self.pending)};local thrown
  for _,t in ipairs(pending)do
    local reject=t.reject;t:finish()
    local ok,why=pcall(reject,{kind='closed',message='attachment queue closed'},t)
    if not ok then thrown=why end
  end
  if thrown then error(thrown,0)end
end
return M
