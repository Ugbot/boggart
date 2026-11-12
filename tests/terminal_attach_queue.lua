local Queue=require 'terminal.attach_queue'
local function reject()error('unexpected rejection')end
local q=Queue.new(2,4);local order={}
local function start(t)order[#order+1]=t end
local a=q:submit(start,reject);local b=q:submit(start,reject)
local c=q:submit(start,reject);local d=q:submit(start,reject)
local full
q:submit(start,function(why)full=why end)
assert(full.kind=='capacity'and q.active==2 and q.count==4 and #order==2)
c:finish();a:finish();a:finish()
assert(#order==3 and order[3]==d and q.count==2 and q.active==2,'FIFO skips cancellation; completion is idempotent')
local closed
local e=q:submit(start,function(why)closed=why end)
q:close();q:close()
assert(closed.kind=='closed'and e.state=='done'and q.active==2 and q.count==2)
b:finish();d:finish();assert(q.count==0 and q.active==0)
q:submit(start,function(why)assert(why.kind=='closed')end)
local synchronous=Queue.new(1,4);local n=0
local function again(t)
  n=n+1
  if n<1000 then synchronous:submit(again,reject)end
  t:finish()
end
synchronous:submit(again,reject)
assert(n==1000 and synchronous.count==0 and synchronous.active==0,'synchronous completion is iterative')
local throws=Queue.new(1,3);local errors=0
throws:submit(function()error('start failure')end,function(why)assert(why.kind=='state');errors=errors+1 end)
assert(errors==1 and throws.count==0)
local held=throws:submit(function()end,reject)
local t1=throws:submit(start,function()error('reject failure')end)
local t2=throws:submit(start,function()errors=errors+1 end)
assert(not pcall(throws.close,throws)and t1.state=='done'and t2.state=='done'and errors==2)
held:finish();assert(throws.count==0)

-- The real Remote policy with a controlled asynchronous Client boundary.
local client_module=package.loaded['terminal.client']
local old_remote=package.loaded['terminal.remote'];package.loaded['terminal.remote']=nil
local operations={};local sync_error=false;local gate=Queue.new()
package.loaded['terminal.client']={new=function()
  local client={sessions={}}
  function client:attach(id,generation,opts,callback)
    assert(gate.active<=4,'initial handshakes must stay bounded')
    local s={status='attaching',callback=callback}
    function s:close()self.closed=true;self.status='closed'end
    function s:detach(cb)self:close();cb()end
    function s:view()return {cols=80,rows=24,screen={},scrollback={rows={}}}end
    function s:complete(why)
      if why then self:close()else self.status='live'end
      callback(why,why and nil or self)
    end
    self.sessions[#self.sessions+1]=s;operations[#operations+1]=s
    if sync_error then s:complete{kind='state',message='fixture refusal'}end
    return s
  end
  function client:close()self.closed=true;for _,s in ipairs(self.sessions)do s:close()end end
  return client
end}
local Remote=require 'terminal.remote';local remotes={}
for i=1,100 do remotes[i]=Remote.new{socket='/unused',id='term-'..i,generation=1,admission=gate}end
assert(#operations==4 and gate.count==100 and remotes[100]:status()=='queued')
assert(not remotes[100]:reconnect(),'queued reconnect must not duplicate admission')
remotes[100]:close();assert(#operations==4 and gate.count==99)
local i=1
while i<=#operations do operations[i]:complete(i%10==0 and {kind='timeout',message='fixture timeout'}or nil);i=i+1 end
assert(#operations==99 and gate.count==0 and gate.active==0,'all released slots progress after success and failure')
for _,r in ipairs(remotes)do r:close()end
-- Close before completion, then force a stale callback. It must not publish or
-- release a replacement's slot twice.
local stale=Remote.new{socket='/unused',id='stale',generation=1,admission=gate}
local late=operations[#operations];stale:close();late.callback(nil,late)
assert(stale.closed and not stale.snapshot and gate.count==0)
gate=Queue.new(1,8)
local cancelled=Remote.new{socket='/unused',id='cancel-active',generation=1,admission=gate}
local old_operation=operations[#operations]
local successor=Remote.new{socket='/unused',id='successor',generation=1,admission=gate}
cancelled:close();assert(gate.active==1 and gate.count==1 and successor:status()=='attaching')
old_operation.callback(nil,old_operation)
assert(gate.active==1 and gate.count==1,'stale callback must not release successor admission')
operations[#operations]:complete();successor:close();assert(gate.count==0)
sync_error=true
for j=1,300 do local r=Remote.new{socket='/unused',id='sync',generation=1,admission=gate};assert(r.error and not r.attach_ticket);r:close()end
assert(gate.count==0 and gate.active==0)
sync_error=false
local broken=Remote.new({socket='/unused',id='broken',generation=1,admission=gate},nil,
  {apply=function()error('image publication failure')end,close=function()end})
assert(not pcall(operations[#operations].complete,operations[#operations]))
assert(gate.count==0 and gate.active==0,'image publication failure releases admission')
broken:close();gate:close()
package.loaded['terminal.client']=client_module;package.loaded['terminal.remote']=old_remote
print('Attachment queue: bounded FIFO, cancellation, close, synchronous completion, failed/stale callbacks and Remote publication cleanup pass')
