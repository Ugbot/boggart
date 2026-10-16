if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local control=require 'control';local J=require 'bmux.journal';local C=require 'bmux.checkpoint'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-journal-XXXXXX'));local socket=dir..'/sock'
local name='journal-test-'..serve.token(8);local store=bog.store
local fault_name=name..'-fault'
local key='bmux.session.v1:'..name;local owner='bmux.owner.v1:'..name
local function await(fn)
  local end_at=uv.hrtime()+5e9
  repeat uv.run('nowait');if fn()then return end;uv.sleep(1)until uv.hrtime()>end_at
  error('journal deadline')
end
local ok,why=xpcall(function()
  assert(not pcall(control.start,{socket=socket,session=true})and not control.server)
  assert(control.start{socket=socket});assert(not control.journal);control.stop()
  assert(control.start{socket=socket,session=name})
  local journal=control.journal;assert(not journal.blocked)
  local other=J.new(control,name);assert(other.blocked and other.error:find('live process',1,true));other:close()
  local record=assert(control.terminals:open{cmd='/bin/sh',args={'-c','printf HIST; IFS= read -r line'},cwd='.',history=8,rows=4})
  assert(record.cwd:sub(1,1)=='/','relative launch cwd is anchored before checkpointing')
  local host=control.layout
  local function command(op,fields)
    local b={host_id=host.host_id,revision=host.revision,op=op};for k,v in pairs(fields)do b[k]=v end
    local value,e=host:command(b);assert(value,e and e.message);return value
  end
  local w=command('workspace_create',{title='Saved 🦊'}).workspaces[1];local s=w.surfaces[1]
  command('view_add',{workspace_id=w.id,surface_id=s.id,pane_id=s.tree.id,view={kind='terminal',terminal_id=record.id,generation=1}})
  await(function()return journal.writes>0 and journal.last:find('HIST',1,true)end)
  assert(journal.writes==1,'one-shot changes coalesce before initial SQLite write')
  local n=journal.writes;assert(journal:flush()and journal.writes==n,'unchanged checkpoint skips SQLite update')
  local saved=C.decode(store.kv_get(key));assert(saved.terminals[1].launch=='saved','explicit commands never get shell restart permission')
  local pid=record.pid
  local close=journal.close
  journal.close=function(self)
    self.close=close;close(self)
    -- Native allocation/finalization can turn the loop during teardown. A
    -- command arriving after the final save must not become an unsaved edit.
    local client=require('terminal.client').new{socket=socket};local done,status=false
    client:request('POST','/layout/commands',{host_id=host.host_id,revision=host.revision,op='workspace_create',title='Late unsaved edit'},
      function(_,_,code)done=true;status=code end)
    await(function()return done end);client:close()
    assert(status==503,'shutdown refuses mutations after its final checkpoint')
  end
  control.stop();assert(not store.kv_get(owner))
  await(function()return not uv.kill(pid,0)end)
  assert(control.start{socket=socket,session=name})
  journal=control.journal;assert(journal.restored and not journal.blocked)
  local entry=control.terminals.entries[control.terminals.order[1]]
  assert(entry.frozen and not entry.pid and entry.term:plain_tail()[1]=='HIST')
  local Native=require 'terminal.client';local client=Native.new{socket=socket};local done,session,e=false
  client:attach(entry.id,1,{tail=8,stream=false},function(why,value)done=true;e=why;session=value end)
  await(function()return done end);assert(not e and session:view().process.state=='stopped')
  done=false;session:control(false,function(why)done=true;e=why end)
  await(function()return done end);assert(e and e.status==409,'inactive previews cannot acquire input authority')
  client:close()
  assert(not control.terminals:write(entry.id,1,'touch marker\n'))
  assert(not control.terminals:input_events(entry.id,1,{{kind='paste',value='unsafe'}}))
  assert(not control.terminals:resize(entry.id,1,80,24))
  local before=store.kv_get(key);store.kv_set(key,'externally changed checkpoint')
  assert(not journal:flush()and journal.blocked and store.kv_get(key)=='externally changed checkpoint')
  control.stop();store.kv_set(key,before)
  -- A corrupt checkpoint is retained, never replaced by a new empty server.
  store.kv_set(key,'{broken')
  assert(control.start{socket=socket,session=name});assert(control.journal.blocked and #control.terminals.order==0)
  control.stop();assert(store.kv_get(key)=='{broken')
  store.kv_set(key,before)
  assert(control.start{socket=socket,session=name});journal=control.journal
  local replacement='different owner';store.kv_set(owner,replacement)
  assert(not journal:flush()and journal.blocked)
  control.stop();assert(store.kv_get(owner)==replacement,'close cannot remove a replacement owner')
  store.kv_del(owner)
  -- Corrupt owner metadata fails closed before restoring a single process.
  store.kv_set(owner,'invalid owner')
  assert(control.start{socket=socket,session=name});assert(control.journal.blocked and #control.terminals.order==0)
  control.stop();assert(store.kv_get(owner)=='invalid owner')
  store.kv_del(owner)
  local missing=assert(C.decode(before));missing.terminals[1].launch='shell';missing.terminals[1].cwd=dir..'/missing'
  store.kv_set(key,assert(C.encode(missing)))
  assert(control.start{socket=socket,session=name})
  entry=control.terminals.entries[control.terminals.order[1]]
  assert(entry.frozen and entry.error:find('directory',1,true),'missing cwd stays visible without process fallback')
  control.stop()
  local unavailable=assert(C.decode(before))
  local resume_id=store.thread_create{title='Unavailable CLI fixture',model='fixture',status='idle'}
  unavailable.agents={{id='saved-cli',generation=1,provider='boggart',name='Unavailable CLI',launch='boggart',resume_id=resume_id,
    terminal_id=unavailable.terminals[1].id,terminal_generation=unavailable.terminals[1].generation}}
  store.kv_set(key,assert(C.encode(unavailable)))
  assert(control.start{socket=socket,session=name,agent_executable='/not/a/boggart-studio'})
  assert(control.journal.restored and not control.journal.blocked)
  entry=control.terminals.entries[control.terminals.order[1]]
  assert(entry.frozen and entry.error:find('CLI path',1,true),'unavailable Boggart executable remains an inactive preview')
  control.stop()
  -- A hard restore limit cannot publish a partial tree or erase the saved data.
  missing=assert(C.decode(before))
  missing.terminals[2]={id='extra-saved',generation=1,cwd=uv.cwd(),cols=80,rows=4,history=0,launch='saved',lines={}}
  local limited=assert(C.encode(missing));store.kv_set(key,limited)
  assert(control.start{socket=socket,session=name,terminal_limits={max_records=1}})
  assert(control.journal.blocked and #control.layout.workspaces==0 and store.kv_get(key)==limited)
  for _,id in ipairs(control.terminals.order)do assert(control.terminals.entries[id].closed)end
  control.stop()
  -- An actual storage error is observable; an unrelated journal cannot remove
  -- the first one's ownership or lifecycle subscriptions.
  assert(control.start{socket=socket})
  local fault={};for _,method in ipairs{'is_open','kv_get','kv_compare_set'}do fault[method]=store[method]end
  fault.kv_compare_set=function(k,expected,value)
    if k=='bmux.session.v1:'..fault_name then return nil,'fixture disk full'end
    return store.kv_compare_set(k,expected,value)
  end
  local broken=J.new(control,fault_name,fault)
  assert(not broken:flush()and broken.blocked and broken.error:find('disk full',1,true))
  broken:close();assert(not store.kv_get('bmux.owner.v1:'..fault_name))
end,debug.traceback)
control.stop();store.kv_del(key);store.kv_del(owner);store.kv_del('bmux.session.v1:'..fault_name);store.kv_del('bmux.owner.v1:'..fault_name);uv.run('nowait');assert(uv.fs_rmdir(dir));assert(ok,why)
print('SQLite journal: coalescing, owner/CAS conflicts, immutable corrupt checkpoints, inactive previews and no input/process replay pass')
return 0
