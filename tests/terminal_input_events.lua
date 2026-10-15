if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local json=require 'json';local proc=require 'proc';local terminal=require 'terminal'
local C=require 'terminal.client';local T=require 'terminal.transport'
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-events-XXXXXX'));local socket=dir..'/sock'
assert(uv.fs_mkdir(dir..'/home',448))
local daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' '..q(uv.exepath())..' serve --socket '..q(socket),30)
local clients={}
local function await(check)
  local deadline=uv.hrtime()+6e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('semantic input deadline: '..daemon:result().out)
end
local function call(fn)
  local done,why,value=false;fn(function(e,v)why=e;value=v;done=true end);await(function()return done end);return why,value
end
local function good(fn)local why,value=call(fn);assert(not why,why and why.message);return value end
local function text(session)
  local out={};for _,row in ipairs(session:view().screen)do for _,cell in ipairs(row.cells)do out[#out+1]=cell.text end;out[#out+1]='\n'end
  return table.concat(out)
end
local success,failure=xpcall(function()
  await(function()local info=uv.fs_lstat(socket);return info and info.mode&63==0 end)
  local client=C.new{socket=socket};clients[#clients+1]=client
  local ready,probing=false,false
  await(function()
    if ready then return true end
    if not probing then
      probing=true;client:request('GET','/health',nil,function(why,value)probing=false;ready=not why and value.ok==true end)
    end
    return false
  end) -- private socket creation precedes listen(); wait for real readiness
  local expected='\27OA\27[200~🦊\n\27[201~\27[O\27[<35;3;3M'
  local script="stty raw -echo; printf '\\033[?1;2004;1004;1003;1006hREADY'; dd bs=1 count=3 of=/dev/null 2>/dev/null; printf 'RESULT_BEGIN'; dd bs=1 count="..#expected.." 2>/dev/null | od -An -tx1; printf 'RESULT_END'; exit 7"
  local rec=good(function(cb)client:request('POST','/terminals',{cmd='/bin/sh',args={'-c',script},cols=80,rows=12,history=0},cb)end)
  local a=good(function(cb)client:attach(rec.id,1,{tail=0},cb)end)
  await(function()return text(a):find('READY',1,true)end)
  assert(a:view().input_state.bracketed_paste and a:view().input_state.mouse_mode=='any' and a:view().input_state.focused)
  local b=good(function(cb)client:attach(rec.id,1,{tail=0},cb)end)
  local why=call(function(cb)b:events({{kind='focus',value=false}},cb)end);assert(why and why.kind=='state')
  good(function(cb)a:control(false,cb)end)
  -- A late invalid native key does not emit the earlier focus report or consume
  -- the sequence. This exercises C staging, beyond Lua wire shape checks.
  why=call(function(cb)a:events({{kind='focus',value=false},{kind='key',value={key='unknown-native-key'}}},cb)end)
  assert(why and why.status==400 and not a.pending and a.sequence==0)
  why=call(function(cb)a:events({{kind='key',value={text='x',injected=true}}},cb)end);assert(why and why.kind=='request')
  local cycle={};cycle.key=cycle
  why=call(function(cb)a:events({{kind='key',value=cycle}},cb)end);assert(why and why.kind=='request' and not a.pending)
  why=call(function(cb)a:events({{kind='paste',value=string.rep('x',65537)}},cb)end);assert(why and why.kind=='request')
  local credentials={generation=1,attachment_id=a.attachment_id,attachment_token=a.attachment_token,control_token=a.controller.token,command_seq=1,
    text='forbidden',events={{kind='focus',value=false}}}
  why=call(function(cb)client:request('POST','/terminals/'..rec.id..'/input',credentials,cb)end);assert(why and why.status==400)
  local events={{kind='key',value={key='up',macos=false}},{kind='paste',value='🦊\n'},
    {kind='focus',value=false},{kind='mouse',value={action='motion',x=16,y=32,cell_width=8,cell_height=16}}}
  local original=T.request;local dropped=false;local sent={}
  T.request=function(opts,callback)
    if opts.path=='/terminals/'..rec.id..'/input'then
      sent[#sent+1]=opts.body
      return original(opts,function(error,raw,status)
        if not dropped and not error and status==200 then dropped=true;callback({kind='transport',message='fixture dropped batch acknowledgement'})
        else callback(error,raw,status)end
      end)
    end
    return original(opts,callback)
  end
  why=call(function(cb)a:events(events,cb)end);assert(why and a.pending)
  why=call(function(cb)a:events(events,cb)end);assert(why and why.kind=='state')
  local accepted=good(function(cb)a:retry(cb)end);T.request=original
  assert(accepted.accepted_events==4 and accepted.accepted_bytes==#expected and a.sequence==1 and #sent==2 and sent[1]==sent[2],
    json.encode{accepted=accepted,expected_bytes=#expected,sequence=a.sequence,attempts=#sent,identical=sent[1]==sent[2]})
  await(function()return a:view().process.eof and b:view().process.eof end)
  local output=text(a):gsub('%s','') -- markers may wrap across native rows
  local actual=assert(output:match('RESULT_BEGIN(.-)RESULT_END'),output)
  local hex=expected:gsub('.',function(c)return string.format('%02x',c:byte())end)
  assert(actual==hex,'server-native negotiated bytes differ: '..actual..' vs '..hex)
  assert(a:view().process.exit_status==7 and json.encode(a:view().screen)==json.encode(b:view().screen),'both viewers receive the same final native grid')
  assert(not a:view().input_state.focused and not b:view().input_state.focused)
  -- Native binding also rejects sparse batches and parser-only owners.
  local parser=terminal.new(8,2,0)
  assert(not pcall(parser.send_events,parser,{{kind='focus',value=false}}));parser:close()
  local quiet=good(function(cb)client:request('POST','/terminals',{cmd='/bin/sh',args={'-c','IFS= read -r line'},cols=8,rows=2,history=0},cb)end)
  local passive=good(function(cb)client:attach(quiet.id,1,{tail=0},cb)end)
  good(function(cb)passive:control(false,cb)end)
  local old_cursor=passive:view().cursor
  local empty=good(function(cb)passive:events({{kind='focus',value=false}},cb)end)
  assert(empty.accepted_bytes==0 and empty.accepted_events==1)
  await(function()return passive:view().cursor>old_cursor and not passive:view().input_state.focused end)
  good(function(cb)client:request('POST','/terminals/'..quiet.id..'/close',{generation=1},cb)end)
  local step,pause=collectgarbage('param','stepsize'),collectgarbage('param','pause');local during=0
  for attempt=1,8 do
    collectgarbage('collect');collectgarbage('stop')
    local live=assert(terminal.open{cmd='/bin/cat',cols=8,rows=2,history=0});local inside=false
    local batch={{kind='key',value={text=10000000+attempt}},{kind='paste',value='rooted'}}
    do local garbage=setmetatable({},{__gc=function()if inside then during=during+1;live:close()end end})end
    collectgarbage('incremental');collectgarbage('param','stepsize',0);collectgarbage('param','pause',100);collectgarbage('restart')
    inside=true;local ok,result=pcall(live.send_events,live,batch);inside=false
    assert(ok or tostring(result):find('live PTY terminal required',1,true),'unexpected input staging error')
    live:close()
  end
  collectgarbage('param','stepsize',step);collectgarbage('param','pause',pause);collectgarbage('restart')
  assert(during>0,'argument staging exercises owner closure during finalization')
  for _,c in ipairs(clients)do c:close()end
  assert(uv.kill(daemon.pid,'sigterm'));assert(daemon:wait().code==0)
end,debug.traceback)
for _,c in ipairs(clients)do c:close()end
if not daemon.done then daemon:kill('sigkill');daemon:wait()end
if not success then error(failure)end
print('terminal_input_events: actual server modes, atomic late rejection, exact uncertain-batch retry, native bytes and independent replicas pass')
return 0
