if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local terminal=require 'terminal';local proc=require 'proc'
local Native=require 'terminal.client';local Fleet=require 'bmux.fleetclient';local Layout=require 'bmux.client'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-ctui-fleet-XXXXXX'));local socket=dir..'/sock'
assert(uv.fs_mkdir(dir..'/home',448))
local child,admin,fleet,layout,probe,daemon,observed_id;local stopped=false
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local function screen()
  if not child then return ''end
  local out={};local _,rows=child:geometry()
  for y=1,rows do for _,c in ipairs(child:row(y).cells)do if c.width>0 then out[#out+1]=c.text end end;out[#out+1]='\n'end
  return table.concat(out)
end
local function await(check,label)
  local deadline=uv.hrtime()+10e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error((label or 'cTUI Fleet deadline')..'\n'..screen()..'\n'..
    (observed_id and require('json').encode(fleet:find(observed_id))or ''))
end
local function good(fn)
  local done,why,result=false
  fn(function(e,v)done=true;why=e;result=v end);await(function()return done end)
  assert(not why,why and (why.message..' '..require('json').encode(why.response or {})));return result
end
local function request(method,path,body)return good(function(cb)admin:request(method,path,body,cb)end)end
local function write(text)assert(child:write(text)==#text)end
local function prefix(key)write('\2'..key)end
local function esc()write('\27')end
local function paste(text)write('\27[200~'..text..'\27[201~')end
local function open_fleet()
  prefix('f');await(function()return screen():find('Bmux | Fleet | live',1,true)end)
end
local function select_agent(id)
  local next_at=0
  await(function()
    local marker
    for i,r in ipairs(fleet:view().agents)do if r.id==id then marker='> R'..i..' '..r.name..' |';break end end
    if marker and screen():find(marker,1,true)then return true end
    if uv.hrtime()>next_at then write('\27[B');next_at=uv.hrtime()+50e6 end
  end,'select Fleet runtime '..id)
end
local function start()
  local command='before=$(stty -g); '..q(uv.exepath())..' bmux --socket '..q(socket)
    ..'; status=$?; after=$(stty -g); [ "$before" = "$after" ] || exit 91; exit "$status"'
  child=assert(terminal.open{cmd='/bin/sh',args={'-c',command},cols=110,rows=32,history=32,
    env={'HOME='..dir..'/home','BOGGART_HOME='..dir..'/home/.boggart'}})
  await(function()return screen():find('Bmux |',1,true)and screen():find('live',1,true)end)
end
local function prompt(text)
  open_fleet();await(function()return screen():find('p Send prompt',1,true)end)
  write('p');await(function()return screen():find('Prompt ',1,true)end)
  paste(text);write('\r')
end
local function detach()
  prefix('q');await(function()local p=child:process_state();return p.exited and p.eof end)
  assert(child:process_state().exit_status==0,'clean exit restores exact termios')
  child:close();child=nil
end
local ok,why=xpcall(function()
  -- Keep the model fixture's persisted manual-approval setting in a fresh
  -- daemon home, independent of this test runner and repeated CTest runs.
  assert(uv.fs_mkdir(dir..'/server',448))
  daemon=proc.start('exec env HOME='..q(dir..'/server')..' BOGGART_HOME='..q(dir..'/server/.boggart')..' '
    ..q(uv.exepath())..' serve --socket '..q(socket),90)
  await(function()local info=uv.fs_lstat(socket);return info and info.type=='socket'and info.mode&63==0 end)
  admin=Native.new{socket=socket};fleet=Fleet.new{socket=socket};layout=Layout.new{socket=socket}
  local ready,probing=false,false
  await(function()
    if not ready and not probing then probing=true;admin:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok end)end
    return ready
  end)
  good(function(cb)fleet:start(cb)end);good(function(cb)layout:start(cb)end)
  start();prefix('a');await(function()return screen():find('New server agent | live',1,true)and screen():find('Boggart TUI',1,true)end)
  write('\r')
  local launched
  await(function()for _,r in ipairs(fleet:view().agents)do if r.provider=='boggart'and r.capabilities.prompt then launched=r;return true end end end,'default Boggart profile launches actual TUI')
  local first_id=launched.id
  await(function()return screen():find('[read-only]',1,true)end)
  open_fleet();write('x');await(function()return screen():find('? (y confirms',1,true)end)
  write('y');await(function()return fleet:find(first_id).state=='stopped'end)
  esc();await(function()return not screen():find('Bmux | Fleet',1,true)end)

  -- This second actual TUI uses only the deterministic model fixture; server,
  -- channel, session, terminal and native CLI inputs remain real.
  local result=good(function(cb)fleet:launch({provider='boggart',name='Fixture 🦊',cmd=uv.exepath(),
    args={'--eval',uv.cwd()..'/tests/fixtures/agent_control_tui.lua'},cols=300,rows=80,history=128},cb)end)
  local id=result.agent_id;observed_id=id
  await(function()return fleet:find(id)and fleet:find(id).capabilities.prompt end)
  local rejected,attach_error=false
  admin:attach(result.terminal_id,result.terminal_generation,{tail=256,stream=false},function(e)
    rejected=true;attach_error=e
  end)
  await(function()return rejected end)
  assert(attach_error and attach_error.status==413 and attach_error.response.error=='attachment cell limit exceeded')
  local pid,sid=fleet:find(id).pid,fleet:find(id).session_id
  open_fleet();write('\27[B');await(function()return screen():find('> R2 Fixture 🦊',1,true)end)
  write('\r');await(function()return screen():find('Fixture 🦊 [read-only]',1,true)end)
  prefix('c');await(function()return screen():find('Fixture 🦊 [controlling]',1,true)end)
  assert(request('GET','/terminals').total==2)
  prompt('A👩‍💻')
  await(function()return fleet:find(id).state=='idle'and fleet:find(id).control_result and fleet:find(id).control_result.accepted end)
  esc();await(function()return screen():find('FIXTURE_ANSWER:A👩‍💻',1,true)end,'structured prompt reaches native agent view')
  open_fleet();write('p');await(function()return screen():find('Prompt Fixture',1,true)end)
  paste('é👩‍💻🇬🇧');write('\27[D')
  await(function()return screen():find('> é👩‍💻🇬🇧',1,true)end,'caret preserves the complete flag under it')
  write('\27[C\127\r')
  await(function()return fleet:find(id).state=='idle'and fleet:find(id).control_result and fleet:find(id).control_result.id~='none'end)
  esc();await(function()return screen():find('FIXTURE_ANSWER:é👩‍💻',1,true)end,'backspace removes one complete flag grapheme')
  prefix('c');await(function()return screen():find('[controlling]',1,true)end)
  write('human draft');await(function()return fleet:find(id).draft_bytes==11 end)
  prompt('must not overwrite')
  await(function()return screen():find('human input',1,true)or screen():find('draft',1,true)end)
  assert(fleet:find(id).draft_bytes==11)
  esc();await(function()return screen():find('Bmux | Fleet',1,true)end)
  paste('MODAL_MUST_NOT_TYPE\r');esc()
  await(function()return screen():find('[controlling]',1,true)end)
  assert(fleet:find(id).draft_bytes==11,'Fleet and editor paste never reaches controlled terminal')
  write('\21');await(function()return fleet:find(id).draft_bytes==0 end)
  prompt('approval');await(function()return fleet:find(id).request and screen():find('a Approve',1,true)end)
  write('r');await(function()return fleet:find(id).state=='idle'and not fleet:find(id).request end)
  esc();await(function()return screen():find('FIXTURE_REJECTED',1,true)end)
  prompt('approval');await(function()return fleet:find(id).request and screen():find('a Approve',1,true)end)
  write('a');await(function()return fleet:find(id).state=='idle'and not fleet:find(id).request end)
  esc();await(function()return screen():find('FIXTURE_APPROVED',1,true)end)
  prompt('wait');await(function()return fleet:find(id).state=='running'and screen():find('i Interrupt',1,true)end)
  write('i');await(function()return fleet:find(id).state=='idle'end);esc()
  await(function()return screen():find('[controlling]',1,true)end)
  prompt('workers')
  local worker
  await(function()for _,r in ipairs(fleet:view().agents)do if r.parent==id and r.capabilities.stop then worker=r;return true end end end)
  -- Worker focus must reveal the original parent terminal, not create a TUI.
  await(function()return screen():find('R3 coder | running',1,true)end,'terminal observer has worker roster')
  select_agent(worker.id);await(function()return screen():find('x Cancel worker',1,true)end)
  write('\r');await(function()return screen():find('Fixture 🦊 [controlling]',1,true)end)
  assert(request('GET','/terminals').total==2)
  open_fleet();write('x');await(function()return screen():find('Cancel worker',1,true)and screen():find('y confirms',1,true)end)
  write('y');await(function()return fleet:find(worker.id).state=='stopped'end)
  local second_worker
  for _,r in ipairs(fleet:view().agents)do if r.parent==id and r.capabilities.stop then second_worker=r;break end end
  assert(second_worker);select_agent(second_worker.id);write('x')
  await(function()return screen():find('y confirms',1,true)end);write('y')
  await(function()return fleet:find(second_worker.id).state=='stopped'and fleet:find(id).state=='idle'end)
  esc();await(function()return not screen():find('Bmux | Fleet',1,true)end)

  -- Exercise literal argv launcher and process-only capability display.
  prefix('a');await(function()return screen():find('New server agent',1,true)end)
  write('\27[<0;3;6M\27[<0;3;6m') -- actual mouse chooses Custom
  await(function()return screen():find('Server agent command',1,true)end)
  paste('/bin/sh -c "printf FOREIGN; IFS= read -r line"');write('\r')
  await(function()return screen():find('FOREIGN',1,true)and screen():find('[read-only]',1,true)end)
  local foreign
  await(function()for _,r in ipairs(fleet:view().agents)do if r.provider=='custom'then foreign=r;return true end end end)
  open_fleet()
  -- Select newest row with Up from the retained worker selection.
  select_agent(foreign.id)
  assert(not screen():find('p Send prompt',1,true),'foreign executable has no inferred semantic controls')
  child:resize(26,12);await(function()return screen():find('Fleet',1,true)and screen():find('x Stop',1,true)end,'narrow Fleet keeps actions available')
  write('x');await(function()return screen():find('y confirms',1,true)end);write('y')
  await(function()return fleet:find(foreign.id).state=='stopped'end)
  esc();child:resize(110,32);await(function()return not screen():find('Bmux | Fleet',1,true)end)

  -- Reopen after removing a reference and rejoin after every native reader closes.
  local count=request('GET','/terminals').total
  open_fleet();select_agent(id);write('\r')
  await(function()return screen():find('Fixture 🦊 [read-only]',1,true)end)
  prefix('x')
  await(function()
    for _,view in pairs(layout.refs)do if view.kind=='agent'and view.agent_id==id then return false end end
    return true
  end,'closing the parent reference removes its view')
  assert(uv.kill(pid,0))
  open_fleet();write('\r')
  await(function()return screen():find('Fixture 🦊 [read-only]',1,true)end,'Fleet reopens the same runtime')
  assert(request('GET','/terminals').total==count)
  detach()
  assert(uv.kill(pid,0)and fleet:find(id).session_id==sid)
  start();open_fleet();select_agent(id)
  write('\r');await(function()return screen():find('Fixture 🦊 [read-only]',1,true)end)
  assert(request('GET','/terminals').total==count and request('GET','/terminals/'..result.terminal_id).pid==pid)
  detach()

  -- Saved modal actions and prompt composers reject replacement state locally.
  probe=require('bmux.tui').new{socket=socket};probe:start();probe:arrange(80,24)
  await(function()return probe.fleet.client and probe.fleet.client.live end);probe:arrange(80,24)
  local ui=probe.fleet;local row=ui.source:find(id)
  local saved
  for _,item in ipairs(ui:actions(row))do if item.key=='p'then saved=item.run end end
  assert(saved);saved();assert(ui.editor)
  row.session_id=sid+1;local seq=ui.client.sequence
  ui.editor.submit('stale conversation')
  assert(ui.client.sequence==seq and ui.message:find('conversation changed',1,true))
  row.session_id=sid
  await(function()return fleet:find(id).state=='idle'end)
  good(function(cb)fleet:command(id,row.generation,'prompt',{text='approval'},cb)end)
  await(function()return row.request end)
  local first_request=row.request.id;local approve
  for _,item in ipairs(ui:actions(row))do if item.key=='a'then approve=item.run end end
  assert(approve)
  good(function(cb)fleet:command(id,row.generation,'approve',{request_id=first_request,decision='reject'},cb)end)
  await(function()return fleet:find(id).state=='idle'end)
  good(function(cb)fleet:command(id,row.generation,'prompt',{text='approval'},cb)end)
  await(function()return row.request and row.request.id~=first_request end)
  seq=ui.client.sequence;approve()
  assert(ui.client.sequence==seq and ui.message=='Approval request expired','saved approval cannot transfer to a new request')
  good(function(cb)fleet:command(id,row.generation,'approve',{request_id=row.request.id,decision='approve'},cb)end)
  await(function()return fleet:find(id).state=='idle'end)
  -- Lose one real launch acknowledgement, then activate the launcher's actual
  -- Retry key. The shared client must retain identical bytes and one process.
  local original=ui.client.transport.request;local sent={};local lost=false
  ui.client.transport.request=function(self,method,path,body,cb,stream)
    if path=='/fleet/launch'then
      sent[#sent+1]=body
      return original(self,method,path,body,function(e,v,status)
        if not e and not lost then lost=true;cb({kind='timeout',message='fixture lost launch acknowledgement'})else cb(e,v,status)end
      end,stream)
    end
    return original(self,method,path,body,cb,stream)
  end
  ui:open('launch');ui:launch{provider='custom',name='Retry fixture',cmd='/bin/sh',args={'-c','IFS= read -r line'}}
  await(function()return ui.client.uncertain and ui.client.pending end)
  local retained=request('GET','/terminals').total
  ui:input{type='key',key='char',char='u'}
  await(function()return not ui.client.pending and not probe.client.busy end)
  assert(#sent==2 and sent[1]==sent[2]and request('GET','/terminals').total==retained)
  probe:close();probe=nil
  stopped=true
end,debug.traceback)
if probe then probe:close()end
if child then child:close()end
if layout then layout:close()end
if fleet then fleet:close()end
if admin then admin:close()end
if daemon and not daemon.done then
  assert(uv.kill(daemon.pid,ok and 'sigterm'or 'sigkill'));local exit=daemon:wait()
  if ok then assert(exit.code==0,'clean daemon shutdown')end
end
uv.run('nowait');assert(ok,why);assert(stopped)
print('native cTUI Fleet: actual launch, agent views, emoji composer, controls/workers, foreign Stop, modal isolation and same-runtime rejoin pass')
return 0
