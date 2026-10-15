if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local proc=require 'proc';local json=require 'json';local C=require 'terminal.client';local T=require 'terminal.transport'
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-client-XXXXXX'));local socket=dir..'/sock';local ready=dir..'/ready.json'
assert(uv.fs_mkdir(dir..'/home',448))
local tracing=os.getenv('BMUX_RECONNECT_TRACE')=='1'
if tracing then
  assert(uv.fs_mkdir(dir..'/home/.boggart',448));assert(uv.fs_mkdir(dir..'/home/.boggart/lua',448))
  assert(uv.fs_copyfile('tests/fixtures/terminal_server_probe.lua',dir..'/home/.boggart/lua/control.lua'))
end
local daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' '
  ..q(uv.exepath())..' serve --socket '..q(socket),60)
local viewer;local clients={}
local function await(check)
  local deadline=uv.hrtime()+8e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('client deadline; daemon: '..daemon:result().out..(viewer and '; viewer: '..viewer:result().out or ''))
end
local function new_client(opts)
  opts=opts or {};opts.socket=socket;local client=C.new(opts);clients[#clients+1]=client;return client
end
local function call(fn)
  local done,why,result,status=false
  fn(function(e,v,s)done=true;why=e;result=v;status=s end);await(function()return done end)
  return why,result,status
end
local function good(fn)local why,result,status=call(fn);assert(not why,why and why.message..' '..tostring(status));return result,status end
local function image(session)local v=session:view();return json.encode{screen=v.screen,scrollback=v.scrollback}end
local ok,failure=xpcall(function()
  await(function()local info=uv.fs_lstat(socket);return info and info.mode&63==0 end)
  local client=new_client()
  local cycle={};cycle.self=cycle
  local bad_body=call(function(cb)client:request('POST','/terminals',cycle,cb)end)
  assert(bad_body and bad_body.kind=='request' and client.request_count==0,'encoding failure does not leak a request')
  local record=good(function(cb)client:request('POST','/terminals',{cmd='/bin/sh',args={'-c',[[stty -echo; i=0; while [ "$i" -lt 64 ]; do printf '\033[32mline-%02d 🦊 é\033[0m\r\n' "$i"; i=$((i+1)); done; printf 'READY\r\n'; while IFS= read -r line; do printf 'ECHO:%s\r\n' "$line"; [ "$line" = EXIT ] && exit 7; done]]},cols=80,rows=24,history=128},cb)end)
  local function attach(c,opts)
    local session=good(function(cb)c:attach(record.id,1,opts or {tail=32},cb)end);return session
  end
  local cancelled=client:attach(record.id,1,{tail=32},function()error('cancelled attach callback ran')end)
  cancelled:disconnect();cancelled:close();assert(cancelled.closed)
  local a=attach(client)
  local function contents(session)
    local out={};for _,row in ipairs(session:view().screen)do for _,cell in ipairs(row.cells)do out[#out+1]=cell.text end end
    return table.concat(out)
  end
  await(function()return contents(a):find('READY',1,true)end)
  assert(#a:view().scrollback.rows==32 and a:view().scrollback.total>32,'fixture has a full nonempty history tail')
  local second=new_client();local b=attach(second)
  await(function()return image(a)==image(b)end)
  assert(a.attachment_id~=b.attachment_id and a:view().process.pid==record.pid)
  local e=call(function(cb)a:input('FORBIDDEN\n',cb)end);assert(e and e.kind=='state')
  local original_transport=T.request;local broken_attach
  T.request=function(opts,callback)
    if opts.stream then
      local receive=opts.on_event
      opts.on_event=function(event,raw)
        local frame=json.decode(raw);frame.after=frame.after+5;frame.cursor=frame.after+1;frame.kind='delta'
        receive(event,json.encode(frame))
      end
    end
    return original_transport(opts,callback)
  end
  e=call(function(cb)broken_attach=client:attach(record.id,1,{tail=32},cb)end)
  T.request=original_transport
  assert(e and e.kind=='protocol' and e.message:find('gap in terminal cursors',1,true),'malformed streamed cursor reports the validation diagnostic')
  assert(broken_attach:view().cursor==1 and broken_attach.status=='disconnected');broken_attach:close()
  local admitted=0;local capacity=64-client.request_count -- live SSE uses a slot
  for _=1,capacity do client:request('GET','/terminals',nil,function(why)assert(not why);admitted=admitted+1 end)end
  e=call(function(cb)a:control(false,cb)end)
  assert(e and e.kind=='closed' and not a.control_request,'synchronous admission failure clears the operation slot')
  await(function()return admitted==capacity end)
  good(function(cb)a:control(false,cb)end)
  e=call(function(cb)b:control(false,cb)end);assert(e and e.status==409)
  good(function(cb)b:control(true,cb)end)
  e=call(function(cb)a:input('OLD_OWNER\n',cb)end);assert(e and e.status==403)
  -- Discard a successful native input response, then retry identical bytes.
  local original=T.request;local lost=false;local sent={}
  T.request=function(opts,callback)
    if opts.path=='/terminals/'..record.id..'/input'then
      sent[#sent+1]=opts.body
      return original(opts,function(why,raw,status)
        if not lost and not why and status==200 then lost=true;callback({kind='transport',message='fixture dropped response'})
        else callback(why,raw,status)end
      end)
    end
    return original(opts,callback)
  end
  e=call(function(cb)b:input('ONCE\n',cb)end);assert(e and b.pending)
  e=call(function(cb)b:input('BLOCKED\n',cb)end);assert(e and e.kind=='state')
  good(function(cb)b:retry(cb)end);T.request=original
  assert(#sent==2 and sent[1]==sent[2] and not b.pending,'uncertain command retry uses exact bytes')
  await(function()return contents(a):find('ECHO:ONCE',1,true) and image(a)==image(b)end)
  local _,count=contents(a):gsub('ECHO:ONCE','');assert(count==1,'retry did not duplicate accepted input')
  local corrupted=false
  T.request=function(opts,callback)
    return original(opts,function(why,raw,status)
      if not corrupted and not why and status==200 and opts.path=='/terminals/'..record.id..'/input'then
        corrupted=true;callback(nil,'{}',status)
      else callback(why,raw,status)end
    end)
  end
  e=call(function(cb)b:input('ACK_TEST\n',cb)end);assert(e and e.kind=='protocol' and b.pending,'malformed success acknowledgement keeps command uncertain')
  T.request=original;good(function(cb)b:retry(cb)end)
  await(function()return contents(a):find('ECHO:ACK_TEST',1,true) and image(a)==image(b)end)
  local failed_after_effect=false
  T.request=function(opts,callback)
    return original(opts,function(why,raw,status)
      if not failed_after_effect and not why and status==200 and opts.path=='/terminals/'..record.id..'/input'then
        failed_after_effect=true;callback(nil,'{"error":"fixture failed after effect"}',500)
      else callback(why,raw,status)end
    end)
  end
  e=call(function(cb)b:input('SERVER_ERROR\n',cb)end);assert(e and e.status==500 and b.pending,'a server failure can occur after an accepted effect')
  T.request=original;good(function(cb)b:retry(cb)end)
  await(function()return contents(a):find('ECHO:SERVER_ERROR',1,true) and image(a)==image(b)end)
  -- Client-process death must leave the same daemon-owned native PTY alive.
  local cold_started=uv.hrtime()
  viewer=proc.start('exec env BMUX_ATTACH_SOCKET='..q(socket)..' BMUX_ATTACH_ID='..q(record.id)..' BMUX_ATTACH_READY='..q(ready)
    ..' BOGGART_HOME='..q(dir..'/viewer-home')..' '..q(uv.exepath())..' --eval tests/fixtures/terminal_attach_process.lua',30)
  await(function()return uv.fs_stat(ready)end)
  local cold_ms=(uv.hrtime()-cold_started)/1e6
  local file=assert(io.open(ready,'rb'));local saved=json.decode(file:read('a'));file:close()
  assert(saved.pid==record.pid and json.encode(saved.screen)==json.encode(a:view().screen)
    and json.encode(saved.scrollback)==json.encode(a:view().scrollback))
  local killed_at=uv.hrtime();viewer:kill('sigkill');local killed=viewer:wait();assert(killed.code~=0)
  local R=require 'terminal.replica';local decoded_ms,applied_ms,request_ms=0,0,0;local traces={}
  local original_decode,original_new=R.decode,R.new
  R.decode=function(raw)local tick=uv.hrtime();local result,why=original_decode(raw);decoded_ms=decoded_ms+(uv.hrtime()-tick)/1e6;return result,why end
  R.new=function(...)
    local r=original_new(...);local apply=r.apply
    r.apply=function(self,f)local tick=uv.hrtime();local value,why=apply(self,f);applied_ms=applied_ms+(uv.hrtime()-tick)/1e6;return value,why end
    return r
  end
  T.request=function(opts,callback)
    local tick=uv.hrtime()
    local op=original(opts,function(...)request_ms=request_ms+(uv.hrtime()-tick)/1e6;callback(...)end)
    if tracing then
      local trace={stage=opts.stream and 'stream' or 'snapshot',chunks=0,bytes=0,sizes={},held_ms=0}
      traces[#traces+1]=trace;local feed=op.parser.feed
      op.parser.feed=function(parser,data)
        local before=uv.hrtime();trace.chunks=trace.chunks+1;trace.bytes=trace.bytes+#data
        trace.first_ms=trace.first_ms or (before-tick)/1e6;trace.last_ms=(before-tick)/1e6
        trace.sizes[tostring(#data)]=true
        trace.send_buffer=op.pipe:send_buffer_size();trace.receive_buffer=op.pipe:recv_buffer_size()
        feed(parser,data);trace.held_ms=trace.held_ms+(uv.hrtime()-before)/1e6
      end
    end
    return op
  end
  local fresh_client=new_client();local started=uv.hrtime();local fresh=attach(fresh_client)
  R.decode=original_decode;R.new=original_new;T.request=original
  local reconnect_ms=(uv.hrtime()-started)/1e6;local kill_rejoin_ms=(uv.hrtime()-killed_at)/1e6
  assert(fresh:view().process.pid==record.pid and fresh:view().process.state=='alive')
  assert(json.encode(fresh:view().screen)==json.encode(saved.screen) and json.encode(fresh:view().scrollback)==json.encode(saved.scrollback),'rejoin restores byte-identical cells and history tail')
  print(string.format('terminal_client timing: attach+validated-replay=%.3fms kill+rejoin=%.3fms cold-process+file=%.3fms child-protocol=%.3fms cells=%d history=%d',
    reconnect_ms,kill_rejoin_ms,cold_ms,saved.elapsed_ms,80*(24+32),saved.scrollback.total))
  print(string.format('terminal_client phases: HTTP-to-body=%.3fms decode=%.3fms apply=%.3fms',request_ms,decoded_ms,applied_ms))
  if tracing then print('BMUX_CLIENT_TRACE '..json.encode(traces))end
  if os.getenv('BMUX_RECONNECT_GATE')=='1' then
    assert(reconnect_ms<50 and kill_rejoin_ms<50,'BMUX-32 actual client-death/rejoin exceeds 50ms')
  end
  -- Same-reader replay and explicit stale-cursor failure (no hidden takeover).
  fresh:disconnect();assert(fresh.status=='disconnected');good(function(cb)fresh:reconnect(cb)end)
  good(function(cb)b:resize(72,12,cb)end)
  await(function()return a:view().rows==12 and fresh:view().rows==12 and image(a)==image(fresh)end)
  good(function(cb)b:input('SECOND\n',cb)end)
  await(function()return contents(fresh):find('ECHO:SECOND',1,true) and image(a)==image(b) and image(b)==image(fresh)end)
  local reference=attach(new_client());assert(image(reference)==image(a),'replicas match independent native snapshot including reflowed history')
  local cursor=fresh:view().cursor;fresh:disconnect()
  for i=1,3 do
    good(function(cb)b:input('MISSED'..i..'\n',cb)end)
    -- This disconnected reader does not advance on its own; force retained
    -- HTTP frames to prove a cursor older than one retained frame is refused.
    good(function(cb)client:request('POST',fresh.path..'/updates',{generation=1,attachment_token=fresh.attachment_token,after=cursor+i-1},cb)end)
  end
  e=call(function(cb)fresh:reconnect(cb)end);assert(e and e.status==409 and fresh.status=='disconnected')
  fresh:close()
  good(function(cb)b:input('EXIT\n',cb)end)
  await(function()return a:view().process.exit_status==7 and a:view().process.eof end)
  good(function(cb)a:detach(cb)end);assert(a.closed)
  local final=attach(new_client());assert(final:view().process.exit_status==7,'detach leaves completed grid available')
  -- A throwing consumer cannot leave a native stream or request alive.
  local bad=attach(new_client(),{tail=32,on_update=function()error('consumer failed')end})
  local admin=good(function(cb)client:request('POST',bad.path..'/control',{generation=1,attachment_token=bad.attachment_token,takeover=true},cb)end)
  good(function(cb)client:request('POST','/terminals/'..record.id..'/resize',{generation=1,attachment_id=bad.attachment_id,
    attachment_token=bad.attachment_token,control_token=admin.control_token,command_seq=1,cols=71,rows=12},cb)end)
  await(function()return bad.status=='disconnected'end);assert(bad.error.kind=='protocol')
  for _,c in ipairs(clients)do c:close();assert(c.request_count==0 and c.session_count==0)end
  assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0)
end,debug.traceback)
for _,c in ipairs(clients)do c:close()end
if viewer and not viewer.done then viewer:kill('sigkill');viewer:wait()end
if not daemon.done then daemon:kill('sigkill');daemon:wait()end
if tracing then for line in daemon:result().out:gmatch('[^\r\n]+')do if line:match('^BMUX_PROBE ')then print(line)end end end
if not ok then error(failure)end
print('terminal_client: actual daemon, independent process death/rejoin, exact screen/history, controller takeover, uncertain command retry, resize/exit and lifecycle pass')
return 0
