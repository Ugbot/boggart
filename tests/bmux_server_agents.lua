if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local json=require 'json';local proc=require 'proc';local Native=require 'terminal.client';local control=require 'control'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-server-agents-XXXXXX'));local socket=dir..'/sock'
local clients={};local daemon;local streams={};local terminal_session
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local function await(check,label)
  local end_at=uv.hrtime()+8e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>end_at
  error((label or 'server agent deadline')..': '..(daemon and daemon:result().out or 'in-process'))
end
local function client(token)local c=Native.new{socket=socket,token=token};clients[#clients+1]=c;return c end
local function request(c,method,path,body,wanted)
  local done,why,value,status=false
  c:request(method,path,body,function(e,v,s)done=true;why=e;value=v;status=s end)
  await(function()return done end,path)
  assert(status==(wanted or 200),'HTTP '..tostring(status)..' wanted '..tostring(wanted or 200)..': '..tostring(why and why.message))
  if not wanted or wanted<300 then assert(not why,why and why.message)end
  return value
end
local function good(fn)
  local done,why,value=false
  fn(function(e,v)done=true;why=e;value=v end);await(function()return done end)
  assert(not why,why and why.message);return value
end
local function stream(c)
  local state={events={}}
  state.request=c:request('GET','/fleet/stream',nil,function(why)state.closed=true;state.error=why end,function(event,body)
    assert(event=='message');state.snapshot=json.decode(body);state.events[#state.events+1]=state.snapshot
  end)
  streams[#streams+1]=state;return state
end
local function stop()
  for _,c in ipairs(clients)do c:close()end;clients={};control.stop();uv.run('nowait')
end
local ok,why=xpcall(function()
  local roster=require('fleet').new();local notifications=0
  roster:watch('good',function()notifications=notifications+1 end)
  roster:watch('bad',function()error('LISTENER_FAILURE')end)
  local local_agent=roster:register{provider='custom',name='Metadata only'}
  assert(notifications==1 and roster.listener_errors.bad:find('LISTENER_FAILURE',1,true)and not roster.listeners.bad)
  roster:update(local_agent.id,1,{state='alive'});assert(notifications==2,'an observer failure preserves Fleet mutations and other subscribers')
  local gate=require('bmux.receipts').new(1);local calls=0
  local function apply()calls=calls+1;return {count=calls}end
  local value=assert(gate:run('a',1,'first',apply));value.count=999
  assert(gate:run('a',1,'first',apply).count==1 and calls==1,'exact retry returns a copied cached result')
  assert(not gate:run('a',1,'changed',apply)and not gate:run('a',3,'gap',apply))
  assert(not gate:run('b',1,'new',apply)and calls==1,'capacity never evicts a high-water mark')
  assert(gate:run('a',2,'second',apply).count==2)
  assert(not gate:run('a',1,'first',apply)and calls==2,'older requests cannot become fresh launches')
  local _,failure=gate:run('a',3,'throws',function()calls=calls+1;error('private diagnostic')end)
  assert(failure.status==500)
  gate:run('a',3,'throws',apply);assert(calls==3,'an uncertain internal outcome is not executed again')

  assert(control.start{socket=socket,capabilities={'control:GET:/fleet'}})
  local c=client();local page=request(c,'GET','/fleet');local old_host=page.host_id
  request(c,'GET','/fleet/stream',nil,403)
  request(c,'POST','/fleet/launch',{host_id=page.host_id,client_id='denied',command_seq=1,provider='custom',cmd='/bin/sh'},403)
  request(c,'POST','/fleet/commands',{},403)
  assert(#control.terminals.order==0 and control.fleet.receipts.count==0)
  stop()
  assert(control.start{socket=socket,capabilities={'control:GET:/fleet/stream'}})
  c=client();local observed=stream(c);await(function()return observed.snapshot end)
  request(c,'GET','/fleet',nil,403);control.revoke();await(function()return observed.closed end);stop()
  assert(control.start{socket=socket,token='fleet-token'})
  request(client(),'GET','/fleet',nil,401);request(client('fleet-token'),'GET','/fleet?extra=1',nil,400);stop()
  assert(control.start{socket=socket,terminal_limits={max_records=1}})
  c=client();page=request(c,'GET','/fleet')
  local old=request(c,'POST','/fleet/launch',{host_id=page.host_id,client_id='eviction',command_seq=1,provider='custom',cmd='/bin/sh',args={'-c','exit 0'},history=0})
  await(function()return control.fleet.registry.agents[old.agent_id].state=='exited'end)
  request(c,'POST','/fleet/launch',{host_id=page.host_id,client_id='eviction',command_seq=2,provider='custom',cmd='/bin/sh',args={'-c','IFS= read -r line'},history=0})
  assert(not control.terminals.entries[old.terminal_id],'frozen terminal grids can be evicted independently of Fleet history')
  stop() -- retained Fleet ownership must tolerate its evicted terminal entry

  assert(uv.fs_mkdir(dir..'/home',448))
  daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' '
    ..q(uv.exepath())..' serve --socket '..q(socket),90)
  await(function()local info=uv.fs_lstat(socket);return info and info.type=='socket'and info.mode&63==0 end)
  local a,b=client(),client();local ready,probing=false,false
  await(function()
    if not ready and not probing then probing=true;a:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end
    return ready
  end)
  page=request(a,'GET','/fleet');assert(page.host_id~=old_host and page.host_id==request(a,'GET','/layout').host_id)
  local host=page.host_id;local one,two=stream(a),stream(b);await(function()return one.snapshot and two.snapshot end)
  for _,raw in ipairs{'[]','null','false','{broken','{}',string.rep(' ',65536)..'{}'}do request(a,'POST','/fleet/launch',raw,400)end
  for _,bad in ipairs{
    {provider='custom',cmd=''}, {provider='custom',cmd='/bin/sh',args={false}},
    {provider='custom',cmd='/bin/sh',rows=4097}, {provider='custom',cmd='/bin/sh',history=-1},
    {provider='boggart',resume_id='old',args={'--tui'}}, {provider='custom',cmd='/bin/sh',control=true},
  }do
    bad.host_id=host;bad.client_id='invalid';bad.command_seq=1;request(a,'POST','/fleet/launch',bad,400)
  end
  assert(request(a,'GET','/terminals').total==0,'invalid launch shapes never allocate a terminal')
  local function find(state,id)
    if not state.snapshot then return end
    for _,r in ipairs(state.snapshot.agents)do if r.id==id then return r end end
  end
  local launch={host_id=host,client_id='owner',command_seq=1,provider='boggart',name='Server TUI 🦊',cmd=uv.exepath(),
    args={'--eval',uv.cwd()..'/tests/fixtures/agent_control_tui.lua'},cwd=uv.cwd(),cols=80,rows=24,history=128}
  local launched=request(a,'POST','/fleet/launch',launch)
  assert(json.encode(request(a,'POST','/fleet/launch',launch))==json.encode(launched))
  assert(request(a,'GET','/terminals').total==1,'retry never spawns a second execution owner')
  local changed=json.decode(json.encode(launch));changed.name='changed request';request(a,'POST','/fleet/launch',changed,409)
  changed.command_seq=3;request(a,'POST','/fleet/launch',changed,409)
  changed.command_seq=2;changed.host_id='stale-host';request(a,'POST','/fleet/launch',changed,409)
  await(function()local r=find(one,launched.agent_id);return r and r.state=='idle'and r.capabilities.prompt and r.session_id end,'real server-owned TUI handshake')
  local rec=find(one,launched.agent_id);local pid,sid=rec.pid,rec.session_id
  local inspected=good(function(cb)
    require('terminal.transport').request({socket=socket,method='POST',path='/fleet/commands',
      body=json.encode{host_id=host,client_id='inspect',command_seq=1,agent_id=rec.id,generation=rec.generation+1,action='stop'}},
      function(error,raw,status)cb(error,{body=json.decode(raw),status=status})end)
  end)
  assert(inspected.status==409 and inspected.body.receipt.client_id=='inspect'and inspected.body.receipt.command_seq==1,
    'a rejected operation reports that its command sequence was consumed')
  await(function()local other=find(two,rec.id);return other and other.session_id==sid and other.pid==pid end)
  assert(rec.terminal_id==launched.terminal_id and not rec.capabilities.focus)
  local encoded=json.encode(one.snapshot);assert(not encoded:find('attachment_token',1,true)and not encoded:find('control_token',1,true))
  terminal_session=good(function(cb)b:attach(launched.terminal_id,launched.terminal_generation,{tail=32},cb)end)
  assert(terminal_session:view().process.pid==pid)
  local function output()
    local out={};local view=terminal_session:view()
    for _,row in ipairs(view.screen)do for _,cell in ipairs(row.cells)do if cell.width>0 then out[#out+1]=cell.text end end;out[#out+1]='\n'end
    return table.concat(out)
  end
  good(function(cb)terminal_session:control(false,cb)end)
  local seq=1
  local function action(kind,fields,wanted)
    seq=seq+1
    local body={host_id=host,client_id='owner',command_seq=seq,agent_id=rec.id,generation=rec.generation,action=kind}
    for k,v in pairs(fields or {})do body[k]=v end
    return request(a,'POST','/fleet/commands',body,wanted),body
  end
  local function outcome(receipt,accepted)
    await(function()local r=find(one,receipt.agent_id);return r and r.control_result and r.control_result.id==receipt.command_id end,'owner acknowledgement')
    assert(find(one,receipt.agent_id).control_result.accepted==accepted)
  end
  local revision=rec.input_revision
  local sent,body=action('prompt',{text='hello',input_revision=revision});outcome(sent,true)
  await(function()return output():find('FIXTURE_ANSWER:hello',1,true)end,'actual original TUI publishes model output')
  assert(json.encode(request(a,'POST','/fleet/commands',body))==json.encode(sent),'exact command retry preserves its owner command ID')
  await(function()return find(one,rec.id).state=='idle'end)
  sent=action('prompt',{text='wait',input_revision=find(one,rec.id).input_revision});outcome(sent,true)
  await(function()return find(one,rec.id).state=='running'and find(one,rec.id).capabilities.interrupt end)
  sent=action('interrupt');outcome(sent,true)
  await(function()return find(one,rec.id).state=='idle'end)
  assert(find(one,rec.id).pid==pid and find(one,rec.id).session_id==sid,'interrupt preserves the original runtime')
  good(function(cb)terminal_session:input('human draft',cb)end)
  await(function()return find(one,rec.id).draft_bytes==11 end)
  assert(not json.encode(request(b,'GET','/fleet')):find('human draft',1,true),'Fleet metadata never exports human draft contents')
  action('prompt',{text='stale',input_revision=revision},409)
  sent=action('prompt',{text='must not overwrite',input_revision=find(one,rec.id).input_revision});outcome(sent,false)
  assert(find(one,rec.id).draft_bytes==11)
  good(function(cb)terminal_session:input('\21',cb)end)
  await(function()return find(one,rec.id).draft_bytes==0 end)
  sent=action('prompt',{text='approval',input_revision=find(one,rec.id).input_revision});outcome(sent,true)
  await(function()return find(one,rec.id).state=='waiting_for_approval'and find(one,rec.id).request end)
  local approval=find(one,rec.id).request.id
  action('approve',{request_id='stale-request',decision='approve'},409)
  sent=action('approve',{request_id=approval,decision='reject'});outcome(sent,true)
  await(function()return find(one,rec.id).state=='idle'and not find(one,rec.id).request end)
  await(function()return output():find('FIXTURE_REJECTED',1,true)end,'actual permission rejection reaches the original TUI')
  sent=action('prompt',{text='workers',input_revision=find(one,rec.id).input_revision});outcome(sent,true)
  local children
  await(function()
    children={};local live,done,failed=0,0,0
    for _,r in ipairs(one.snapshot.agents)do if r.parent==rec.id then
      children[#children+1]=r
      if r.state=='running'then live=live+1 elseif r.state=='exited'then done=done+1 elseif r.state=='failed'then failed=failed+1 end
    end end
    return #children==5 and live==2 and done==2 and failed==1
  end)
  for _,r in ipairs(children)do
    assert(r.terminal_id==launched.terminal_id and r.terminal_generation==launched.terminal_generation)
    if r.state=='running'then
      seq=seq+1
      local result=request(a,'POST','/fleet/commands',{host_id=host,client_id='owner',command_seq=seq,agent_id=r.id,generation=r.generation,action='stop'})
      outcome(result,true);await(function()return find(one,r.id).state=='stopped'end)
    end
  end
  await(function()return find(one,rec.id).state=='idle'end)
  good(function(cb)terminal_session:detach(cb)end);terminal_session=nil
  a:close();b:close();await(function()return one.closed and two.closed end)
  assert(uv.kill(pid,0),'all clients may detach without terminating their agent')
  a=client();b=client();one=stream(a);two=stream(b)
  await(function()local r=find(one,rec.id);return r and r.pid==pid and r.session_id==sid and r.capabilities.prompt end,'detach retains original agent')
  await(function()return find(two,rec.id)end)
  local resumed=request(a,'POST','/fleet/launch',{host_id=host,client_id='resume',command_seq=1,provider='boggart',resume_id=sid})
  assert(resumed.reused and resumed.agent_id==rec.id and resumed.terminal_id==launched.terminal_id and request(a,'GET','/terminals').total==1)
  seq=seq+1;request(a,'POST','/fleet/commands',{host_id=host,client_id='owner',command_seq=seq,agent_id=rec.id,generation=rec.generation+1,action='stop'},409)
  seq=seq+1;local stopped=request(a,'POST','/fleet/commands',{host_id=host,client_id='owner',command_seq=seq,agent_id=rec.id,generation=rec.generation,action='stop'})
  await(function()return find(two,rec.id).state=='stopped'end)
  assert(request(a,'GET','/terminals/'..launched.terminal_id).closed and stopped.accepted)
  local foreign=request(b,'POST','/fleet/launch',{host_id=host,client_id='foreign',command_seq=1,provider='custom',name='Foreign agent',cmd='/bin/sh',args={'-c','printf FOREIGN; IFS= read -r line'},history=0})
  await(function()local r=find(two,foreign.agent_id);return r and r.state=='alive'and r.capabilities.stop end)
  assert(not find(two,foreign.agent_id).capabilities.prompt and not find(two,foreign.agent_id).session_id)
  request(b,'POST','/fleet/commands',{host_id=host,client_id='foreign',command_seq=2,agent_id=foreign.agent_id,generation=foreign.generation,action='prompt',text='unsupported',input_revision=0},409)
  request(b,'POST','/fleet/commands',{host_id=host,client_id='foreign',command_seq=3,agent_id=foreign.agent_id,generation=foreign.generation,action='stop'})
  local remaining=request(b,'POST','/fleet/launch',{host_id=host,client_id='foreign',command_seq=4,provider='custom',cmd='/bin/sh',args={'-c','sleep 30'},history=0})
  await(function()return find(two,remaining.agent_id)and find(two,remaining.agent_id).pid end)
  local remaining_pid=find(two,remaining.agent_id).pid
  assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0)
  await(function()return not uv.kill(remaining_pid,0)end,'server shutdown retires its owned process')
end,debug.traceback)
if terminal_session then terminal_session:close()end
stop()
if daemon and not daemon.done then daemon:kill('sigkill');daemon:wait()end
assert(ok,why)
print('server agents: scoped Fleet stream, native Boggart/foreign owners, dedup, drafts, requests, workers, resume, detach and shutdown pass')
return 0
