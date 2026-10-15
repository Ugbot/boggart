if package.config:sub(1,1)=='\\'then return end
local uv=require 'uv';local json=require 'json';local control=require 'control'
local Stream=dofile('tests/fixtures/terminal_stream_client.lua')
local directory=assert(uv.fs_mkdtemp('/tmp/bmux-push-XXXXXX'));local path=directory..'/control.sock';local clock=0
local server=assert(control.start{socket=path,terminal_limits={attachments={clock=function()return clock end,ttl=2,lease_ttl=1}}})
local registry=control.terminals;local host=registry.attachments
local function await(check)
  local deadline=uv.hrtime()+5e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('terminal push deadline')
end
local function create()
  local rec=assert(registry:open{cmd='/bin/sh',args={'-c','stty -echo; printf READY; IFS= read -r line'},cols=20,rows=4,history=4})
  local entry=registry.entries[rec.id]
  await(function()return entry.term:process_state().bytes_read>0 end)
  local snapshot=json.decode(assert(host:attach(entry,{generation=1,tail=2})))
  return rec,entry,snapshot
end
local function options(snapshot)
  return {generation=1,attachment_id=snapshot.attachment_id,attachment_token=snapshot.attachment_token,after=snapshot.cursor}
end
local function stream_options(snapshot)
  local body=options(snapshot);body.attachment_id=nil;return body
end
local one,entry,a=create()
entry.term:feed('\27[HCAUGHT') -- output between snapshot and stream subscription
local client=Stream.connect(path,'/terminals/'..one.id..'/attachments/'..a.attachment_id..'/stream',stream_options(a),a)
local broad=Stream.connect(path,'/events')
await(function()return client.status==200 and client.view.cursor>1 and broad.status==200 end)
assert(client.view.screen[1].cells[1].text=='C','snapshot-to-stream gap is replayed before live delivery')
local two,other,b=create()
local second=Stream.connect(path,'/terminals/'..two.id..'/attachments/'..b.attachment_id..'/stream',stream_options(b),b)
await(function()return second.status==200 end)
uv.run('nowait');local callbacks=entry.term:watch_state().callbacks;local events=#second.events
for _=1,100 do uv.run('nowait')end
assert(entry.term:watch_state().callbacks==callbacks,'idle push emits no periodic callback')
entry.term:feed('\27[2;1HPRIVATE_ONE')
await(function()return client.view.screen[2].cells[1].text=='P'end)
assert(#second.events==events,'another terminal receives no update')
for _,event in ipairs(broad.events)do assert(not(event.data.v==1 and event.data.cursor))end
local owner=json.decode(assert(host:control(entry,options(a))))
clock=100;host:expire();assert(host.count==2,'connected streams retain read lifetime while idle')
local credentials=options(a);credentials.control_token=owner.control_token;credentials.command_seq=1
assert(not registry:write(one.id,1,'expired\n',credentials),'passive streaming never renews execution authority')
assert(host:detach(other,options(b)));await(function()return second.closed end)
assert(not other.term:watch_state().active and registry:get(two.id).state=='alive')
host.max_frame=1;entry.term:feed('\27[3;1HOVERSIZED')
await(function()return client.closed end)
assert(host.count==0 and host.bytes==0 and registry:get(one.id).state=='alive','capture failure closes/resyncs viewer without killing PTY')
host.max_frame=4*1024*1024
local c=json.decode(assert(host:attach(entry,{generation=1,tail=0})))
local final=Stream.connect(path,'/terminals/'..one.id..'/attachments/'..c.attachment_id..'/stream',stream_options(c),c)
await(function()return final.status==200 end)
control.revoke();await(function()return final.closed and broad.closed end)
assert(server:clients()==0,'revocation closes already-authorized streams')
control.stop();uv.run('nowait');assert(uv.fs_rmdir(directory))
print('terminal_push: gap replay, isolated native updates, no idle callbacks, read/controller lifetime, detach, resync and revocation pass')
return 0
