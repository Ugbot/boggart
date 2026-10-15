if package.config:sub(1,1)=='\\'then return end
local uv=require 'uv';local json=require 'json';local clock=0
local registry=require('terminal.registry').new{attachments={clock=function()return clock end,max_readers=2}}
local host=registry.attachments
local rec=assert(registry:open{cmd='/bin/sh',args={'-c',[[stty -echo; printf READY; n=0; while IFS= read -r line; do n=$((n+1)); printf '\r\nINPUT:%s:%s\r\n' "$n" "$line"; done]]},cols=40,rows=6,history=32})
local entry=registry.entries[rec.id];local term=entry.term
local function all_text()
  local snapshot=term:snapshot(true);local out={}
  for _,rows in ipairs{snapshot.scrollback,snapshot.screen}do for _,row in ipairs(rows)do
    for _,cell in ipairs(row.cells)do out[#out+1]=cell.text end;out[#out+1]='\n'
  end end
  return table.concat(out)
end
local function await(check)
  local deadline=uv.hrtime()+5e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('terminal attachment deadline')
end
await(function()return all_text():find('READY',1,true)end)
term:feed(('history\r\n'):rep(12)..'\27[31mRED\27[0m 🦊 é \27]8;id=fixture;https://example.test\27\\LINK\27]8;;\27\\')
local initial=assert(host:attach(entry,{generation=1,tail=4}));local a=json.decode(initial)
assert(a.v==1 and a.kind=='snapshot' and a.cursor==1 and a.attachment_token)
assert(json.encode(a.screen)==json.encode(term:snapshot().screen),'full visible cells/styles/links are identical')
assert(initial:find('🦊',1,true) and initial:find('https://example.test',1,true))
assert(#a.scrollback.rows==4 and a.scrollback.total>4,'bounded history tail included')
local full=term:snapshot(true)
for i,row in ipairs(a.scrollback.rows)do assert(json.encode(row)==json.encode(full.scrollback[a.scrollback.first+i-1]))end
local b=json.decode(assert(host:attach(entry,{generation=1,tail=4})))
assert(not host:attach(entry,{generation=1}),'attachment count is bounded')
local function options(reader,after)
  return {generation=1,attachment_id=reader.attachment_id,attachment_token=reader.attachment_token,after=after}
end
assert(not registry:write(rec.id,1,'unleased\n'),'legacy input cannot bypass attachment ownership')
assert(not registry:resize(rec.id,1,20,6),'legacy resize cannot bypass attachment ownership')
term:feed('\27[HNEW')
assert(host:updates(entry,options(a,0))==initial,'initial snapshot retry is frozen even after output')
local delta=assert(host:updates(entry,options(a,1)));local da=json.decode(delta)
assert(da.kind=='delta' and da.cursor==2 and #da.changes>0 and not da.screen)
term:ack_damage()
local db=json.decode(assert(host:updates(entry,options(b,1))))
assert(json.encode(da.changes)==json.encode(db.changes),'damage acknowledgement cannot consume another reader baseline')
assert(host:updates(entry,options(a,1))==delta,'last delta retry is byte-identical')
assert(json.decode(assert(host:updates(entry,options(a,2)))).kind=='unchanged')
term:feed('\27[2;1HMORE');assert(json.decode(assert(host:updates(entry,options(a,2)))).cursor==3)
local _,why=host:updates(entry,options(a,0));assert(why.status==409,'old cursor requires explicit resync')
local ca=json.decode(assert(host:control(entry,options(a))))
local _,busy=host:control(entry,options(b));assert(busy.status==409)
local take=options(b);take.takeover=true;local cb=json.decode(assert(host:control(entry,take)))
local function credentials(reader,controller,sequence)
  local out=options(reader);out.control_token=controller.control_token;out.command_seq=sequence;return out
end
assert(not registry:write(rec.id,1,'stale\n',credentials(a,ca,1)),'takeover revokes the old controller')
local resize=assert(registry:resize(rec.id,1,30,6,credentials(b,cb,1)));local revision=term:process_revision()
assert(json.encode(resize)==json.encode(registry:resize(rec.id,1,30,6,credentials(b,cb,1))) and term:process_revision()==revision,'resize retry does not repeat its side effect')
assert(not registry:resize(rec.id,1,31,6,credentials(b,cb,1)),'same sequence cannot name another command')
local resized=json.decode(assert(host:updates(entry,options(a,3))));assert(resized.kind=='snapshot' and resized.cols==30)
local accepted=assert(registry:write(rec.id,1,'once\n',credentials(b,cb,2)))
assert(json.encode(accepted)==json.encode(registry:write(rec.id,1,'once\n',credentials(b,cb,2))))
assert(registry:write(rec.id,1,'twice\n',credentials(b,cb,3)))
await(function()return all_text():find('INPUT:2:twice',1,true)end)
assert(not all_text():find('INPUT:3:',1,true),'input retry executes once on the real child')
term:feed('\27[?1049hALT 🦊')
local alt=json.decode(assert(host:updates(entry,options(a,resized.cursor))));assert(alt.kind=='snapshot' and alt.state.alternate)
term:feed('\27[?1049l')
local primary=json.decode(assert(host:updates(entry,options(a,alt.cursor))));assert(primary.kind=='snapshot' and not primary.state.alternate)
clock=11;assert(not registry:write(rec.id,1,'expired\n',credentials(b,cb,4)),'lease expiry rejects input')
local renewed=json.decode(assert(host:control(entry,options(b))))
assert(renewed.control_token~=cb.control_token and not registry:write(rec.id,1,'old token\n',credentials(b,cb,4)))
assert(host:detach(entry,options(b)));assert(host.count==1 and registry:get(rec.id).state=='alive')
assert(not registry:write(rec.id,1,'bypass\n'),'detaching every controller does not reopen the unleased path')
clock=42;host:expire();assert(host.count==0 and host.bytes==0 and registry:get(rec.id).state=='alive')
local again=json.decode(assert(host:attach(entry,{generation=1,tail=4})))
assert(again.process.pid==rec.pid and json.encode(again.screen)==json.encode(term:snapshot().screen),'reattach returns current exact grid on the same PID')
registry:close(rec.id,1);assert(host.count==0 and host.bytes==0,'close retires attachment caches and capabilities')
registry:shutdown();uv.run('nowait')
local tiny=require('terminal.registry').new{attachments={max_frame=1}}
local small=assert(tiny:open{cmd='/bin/sh',args={'-c','IFS= read -r line'},cols=8,rows=2,history=0})
local _,capacity=tiny.attachments:attach(tiny.entries[small.id],{generation=1,tail=0})
assert(capacity.status==503 and tiny.attachments.count==0 and tiny.attachments.bytes==0 and not tiny.entries[small.id].controlled,'failed capture has no partial attachment or authority change')
tiny:shutdown();uv.run('nowait')
local bounded=require('terminal.registry').new()
local held=assert(bounded:open{cmd='/bin/sh',args={'-c','IFS= read -r line'},cols=8,rows=2,history=0})
local cache=bounded.attachments;local held_entry=bounded.entries[held.id]
local first=json.decode(assert(cache:attach(held_entry,{generation=1,tail=0})))
cache.max_bytes=cache.bytes
local _,full_cache=cache:attach(held_entry,{generation=1,tail=0})
assert(full_cache.status==503 and cache.count==1,'aggregate cached frames are bounded without retiring an existing reader')
assert(cache:detach(held_entry,options(first)) and cache.bytes==0)
bounded:shutdown();uv.run('nowait')
-- GC may close a terminal while result tables allocate. Revision vectors are
-- copied before those allocations, so no borrowed native row survives them.
local native=require 'terminal';local finalized=0
local old_pause=collectgarbage('param','pause',100);local old_step=collectgarbage('param','stepsize',0)
for _=1,8 do
  collectgarbage('collect');collectgarbage('stop')
  local t=native.new(4,1024,0);local expected=t:row_versions(0)
  local inside=false
  do local garbage=setmetatable({}, {__gc=function()if inside then finalized=finalized+1;t:close()end end});garbage=nil end
  collectgarbage('incremental');collectgarbage('restart');inside=true
  local called,versions=pcall(t.row_versions,t,0);inside=false
  if called then assert(json.encode(versions)==json.encode(expected))else assert(tostring(versions):find('closed terminal',1,true))end
  t:close();collectgarbage('collect')
end
collectgarbage('param','pause',old_pause);collectgarbage('param','stepsize',old_step)
assert(finalized>0,'revision-vector finalizer overlap must be exercised')
print('terminal_attachments: exact frozen snapshots/history, independent deltas, retry cursors, controller takeover/expiry/dedup, resize/alt and reattach pass')
return 0
