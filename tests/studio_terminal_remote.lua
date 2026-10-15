-- Real daemon and Studio's central loop, without a local pane PTY/parser.
local application=require 'core'
application.add_thread(function()
  local uv=require 'uv';local proc=require 'proc';local C=require 'terminal.client'
  local T=require 'terminal.transport';local Remote=require 'core.terminalremote'
  local original=T.request;local clients,remotes={},{};local daemon,held
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local function read(path)local f=io.open(path,'rb');if not f then return ''end;local s=f:read('a');f:close();return s end
  local function await(check,seconds)
    local deadline=system.get_time()+(seconds or 6)
    repeat coroutine.yield(0);if check()then return end until system.get_time()>deadline
    error('remote pane deadline: '..(daemon and daemon:result().out or 'no daemon'))
  end
  local function call(fn)
    local done,why,value,status=false
    fn(function(e,v,s)done=true;why=e;value=v;status=s end);await(function()return done end)
    return why,value,status
  end
  local function good(fn)local why,value=call(fn);assert(not why,why and why.message);return value end
  local ok,err=xpcall(function()
    local dir=assert(uv.fs_mkdtemp('/tmp/bmux-remote-XXXXXX'));local socket=dir..'/sock';local input=dir..'/input'
    for _,part in ipairs{'/home','/home/.boggart','/home/.boggart/lua'}do assert(uv.fs_mkdir(dir..part,448))end
    -- Only the real host's lease duration is shortened, to exercise renewal.
    local f=assert(io.open(dir..'/home/.boggart/lua/control.lua','w'))
    f:write("local r=require 'terminal.registry';local make=r.new;r.new=function(opts)opts=opts or {};opts.attachments={lease_ttl=3};return make(opts)end\n",
      'return assert(loadfile(',string.format('%q',uv.cwd()..'/lua/control.lua'),'))()\n');f:close()
    daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' BOGGART_SERVE_TOKEN=fixture-token '
      ..q(require('core.agentlauncher').boggart_command())..' serve --socket '..q(socket),30)
    await(function()local s=uv.fs_lstat(socket);return s and s.mode&63==0 end)
    local client=C.new{socket=socket,token='fixture-token'};clients[#clients+1]=client
    local ready,probing=false,false
    await(function()
      if ready then return true end
      if not probing then probing=true;client:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok==true end)end
    end)
    local bad=C.new{socket=socket,token='wrong-token'};clients[#clients+1]=bad
    local refused,_,status=call(function(cb)bad:request('GET','/health',nil,cb)end)
    assert(refused.kind=='http' and refused.status==401 and status==401,'plaintext auth refusal keeps HTTP identity')
    local modes='\27[?1;2004;1004;1000;1006h'
    local script="stty raw -echo; i=0; while [ $i -lt 20 ]; do printf 'history-🦊\\r\\n'; i=$((i+1)); done; printf "
      ..q(modes..'READY')..'; cat >'..q(input)
    local record=good(function(cb)client:request('POST','/terminals',{cmd='/bin/sh',args={'-c',script},cols=40,rows=8,history=64},cb)end)
    local function make()
      local r=Remote.new{socket=socket,token='fixture-token',id=record.id,generation=record.generation,tail=16}
      remotes[#remotes+1]=r;await(function()return r:status()=='read-only'end);return r
    end
    local a,b=make(),make()
    await(function()return a.snapshot.scrollback.total>0 and a:input_state().mouse_mode=='normal'end)
    local pid=a:process_state().pid;local baseline=#read(input)
    a:resize(37,7);assert(not a:event('key',{key='text',text='FORBIDDEN'}));assert(not a:write('FORBIDDEN'))
    assert(not a.timer and a:geometry()==40,'passive view cannot resize or renew control')
    assert(a:control(false));await(function()return a:can_control() and not a.busy and a.snapshot.cols==37 end)
    assert(b:control(false));await(function()return not b.busy end);assert(b.conflict and b.error.status==409)
    local t <close> =require('terminal').new(37,7,0);t:feed(modes)
    local expected={};local function event(kind,value)
      local oracle={};if type(value)=='table'then for k,v in pairs(value)do if k~='scancode'then oracle[k]=v end end else oracle=value end
      expected[#expected+1]=t[kind](t,oracle);assert(a:event(kind,value))
    end
    event('key',{key='up',action='press',scancode=82})
    event('key',{key='text',action='press',text='é👩‍💻'})
    event('paste','paste\n');event('focus',false);event('focus',true)
    event('mouse',{action='press',button=1,x=17,y=33,cell_width=8,cell_height=16,modifiers=0,any_button_pressed=true})
    expected[#expected+1]='RAW';assert(a:write('RAW')==3)
    local paste=('P'):rep(70000)
    for at=1,#paste,16384 do expected[#expected+1]=t:paste(paste:sub(at,at+16383))end
    assert(a:event('paste',paste))
    local wanted=table.concat(expected)
    await(function()return not a.busy and a.head>a.tail and #read(input)>=baseline+#wanted end)
    assert(read(input):sub(baseline+1)==wanted,'ordered semantic batches match native negotiated bytes')
    baseline=#read(input)
    local unicode_paste=('p'):rep(16383)..'🦊'..('日'):rep(20000)
    assert(a:event('paste',unicode_paste))
    await(function()return not a.busy and a.head>a.tail and #read(input)>baseline+#unicode_paste end)
    local parts={}
    for part in read(input):sub(baseline+1):gmatch('\27%[200~(.-)\27%[201~')do assert(utf8.len(part));parts[#parts+1]=part end
    assert(table.concat(parts)==unicode_paste,'chunked paste preserves UTF-8 boundaries')
    local expires=a.session.controller.expires
    await(function()return a.session.controller and a.session.controller.expires>expires+0.5 and a:can_control() and not a.busy end)
    assert(b:control(false));await(function()return not b.busy end);assert(b.error.status==409)
    -- Lose one actual accepted command's acknowledgement; never replay unsent text.
    local drop=true;T.request=function(opts,cb)
      return original(opts,function(why,raw,http)
        if drop and opts.path:match('/input$') and http==200 then drop=false;cb({kind='timeout',message='fixture lost acknowledgement'})
        else cb(why,raw,http)end
      end)
    end
    baseline=#read(input);assert(a:write('ONCE'));assert(a:write('UNSENT'))
    await(function()return a:status()=='uncertain'end)
    assert(a.head>a.tail and not a.timer and read(input):sub(baseline+1)=='ONCE')
    T.request=original;assert(a:retry());await(function()return not a.busy and not a.session.pending end)
    assert(read(input):sub(baseline+1)=='ONCE' and a:status()=='read-only','exact retry does not duplicate effects or reacquire control')
    assert(a:control(false));await(function()return a:can_control() and not a.busy end)
    assert(b:control(true));await(function()return b:can_control() and not b.busy end)
    assert(a:write('REVOKED'));await(function()return not a.busy end)
    assert(not a:can_control() and not a.timer and a.error.status==403)
    assert(b:view_only());await(function()return b:status()=='read-only' and not b.busy end);assert(not b.timer)
    local old_reader=b.session.attachment_id
    b.session.stream:cancel();await(function()return b:status()=='disconnected'end)
    good(function(cb)client:request('POST',b.session.path..'/detach',b.session:_credentials(),cb)end)
    assert(b:reconnect());await(function()return b:status()=='read-only' and b.session.attachment_id~=old_reader end)
    assert(b:process_state().pid==pid,'fresh reader rejoin preserves server PID')
    -- Hold a real ACK while testing all-or-nothing admission at the byte quota.
    assert(b:control(false));await(function()return b:can_control() and not b.busy end)
    T.request=function(opts,cb)
      return original(opts,function(...)
        if opts.path:match('/input$')then local args=table.pack(...);held=function()cb(table.unpack(args,1,args.n))end
        else cb(...)end
      end)
    end
    assert(b:write('HOLD'));await(function()return held end)
    assert(b:event('paste',('Q'):rep(32*1024*1024)),'entire byte quota admitted under held ACK')
    local queued=b.queued_bytes;local tail=b.tail
    assert(not b:event('paste','overflow') and b.queued_bytes==queued and b.tail==tail,'overflow rejects whole input')
    b:close();held();held=nil;T.request=original
    await(function()return b.client.closed end)
    local status_record=good(function(cb)client:request('GET','/terminals/'..record.id,nil,cb)end)
    assert(status_record.pid==pid and not status_record.closed,'closing attached pane leaves server PTY alive')
    a:close();await(function()return a.client.closed end)
    print('studio_terminal_remote: actual host, passive image, ordered native events, >64KiB paste, renewal/takeover, uncertainty/retry, rejoin, quota and detach pass')
  end,debug.traceback)
  T.request=original
  for _,r in ipairs(remotes)do r:close()end
  if held then held();held=nil end
  for _,c in ipairs(clients)do c:close()end
  if daemon and not daemon.done then uv.kill(daemon.pid,'sigterm');await(function()return daemon.done end)end
  if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
  application.quit(true)
end)
