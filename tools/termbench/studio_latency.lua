-- Run with BOGGART_STUDIO_SCRIPT, in an isolated HOME. Requires real PTY/UDS.
local core=require 'core'
package.path='tools/?.lua;'..package.path
core.add_thread(function()
  local uv=require 'uv';local json=require 'json';local hash=require 'hash_c'
  local Proc=require 'proc';local Client=require 'terminal.client';local measure=require 'termbench.measure'
  local config=require 'core.config';local daemon,admin,joined,view
  local function number(name,default,lo,hi)
    local v=tonumber(os.getenv(name)or default)
    assert(v and v%1==0 and v>=lo and v<=hi,'invalid '..name);return v
  end
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local function digest(path)
    local f=assert(io.open(path,'rb'));local bytes=f:read('a');f:close();return hash.sha256(bytes)
  end
  local function await(fn,label,seconds)
    local deadline=uv.hrtime()+(seconds or 15)*1e9
    repeat
      local v=fn();if v then return v end
      if daemon and daemon.done then error('benchmark server exited: '..daemon:result().out)end
      coroutine.yield(0)
    until uv.hrtime()>deadline
    error('deadline: '..label..'; remote='..tostring(view and view.remote:status())
      ..'; error='..tostring(view and view.remote.error and view.remote.error.message)
      ..'; probe='..json.encode(system._test_present_probe())
      ..'; first_cell='..json.encode(view and view.remote.snapshot and view.remote.snapshot.screen[1].cells[1]or {})
      ..'; view='..json.encode(view and {position=view.position,size=view.size,scroll=view.scroll,header=view:header_height(),
        history=view.history_rows,cols=view.cols,rows=view.rows,cw=view.cw,lh=view.lh}or {}))
  end
  local function good(fn)
    local done,why,value=false
    fn(function(e,v)why=e;value=v;done=true end)
    await(function()return done end,'native request')
    assert(not why,why and why.message);return value
  end
  local function request(method,path,body)return good(function(cb)admin:request(method,path,body,cb)end)end
  local ok,why=xpcall(function()
    assert(package.config:sub(1,1)~='\\','POSIX fixture required')
    local fixture=assert(os.getenv('BMUX_BENCH_FIXTURE'),'BMUX_BENCH_FIXTURE required')
    local output=assert(os.getenv('BMUX_LATENCY_REPORT'),'BMUX_LATENCY_REPORT required')
    local samples=number('BMUX_LATENCY_SAMPLES',200,1,10000)
    local warmups=number('BMUX_LATENCY_WARMUPS',20,1,1000)
    -- Keep production frame pacing unless explicitly requested and recorded.
    config.fps=number('BMUX_LATENCY_FPS',config.fps,1,240)
    assert(collectgarbage('isrunning'),'normal GC required')
    local dir=assert(uv.fs_mkdtemp('/tmp/bmux-latency-XXXXXX'))
    local socket=dir..'/sock';assert(uv.fs_mkdir(dir..'/home',448))
    local executable=require('core.agentlauncher').boggart_command()
    daemon=Proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')
      ..' SHELL=/bin/sh '..q(executable)..' serve --socket '..q(socket),60+(samples+warmups)*math.max(.2,5/config.fps))
    await(function()local st=uv.fs_lstat(socket);return st and st.type=='socket'and st.mode&63==0 end,'private socket')
    admin=Client.new{socket=socket}
    local health=request('GET','/health');assert(health.ok)
    local layout=request('GET','/layout')
    layout=request('POST','/layout/commands',{op='workspace_create',host_id=layout.host_id,revision=layout.revision,title='Latency benchmark'})
    local w=layout.workspaces[1];local surface=w.surfaces[1]
    local record=request('POST','/terminals',{cmd=fixture,cols=80,rows=24,history=2000})
    layout=request('POST','/layout/commands',{op='view_add',host_id=layout.host_id,revision=layout.revision,
      workspace_id=w.id,surface_id=surface.id,pane_id=surface.tree.id,
      view={kind='terminal',terminal_id=record.id,generation=record.generation,title='Raw PTY fixture'}})
    good(function(cb)require('core.bmuxlayout').join(socket,nil,function(e,s)joined=s;cb(e,s)end)end)
    await(function()
      for _,v in pairs(joined.pool)do if v.remote and v.remote.id==record.id then view=v;return v.remote:status()=='read-only'end end
    end,'attached terminal')
    assert(core.active_view==view and view.remote:control(false))
    await(function()return view.remote:can_control()and not view.remote.busy and view.size.x>0 end,'controller lease')
    -- Controller acquisition resizes the initial 80x24 image to the viewport.
    -- Its old bottom scroll offset animates toward zero: a fixed frame count
    -- can arm a header pixel instead of cell 1,1. Wait for actual geometry and
    -- scrolling to settle, then require the same origin over three frames.
    local stable,last_origin=0,nil
    await(function()
      local ox,oy=view:get_content_offset()
      local origin=table.concat({ox,oy,view:header_height(),view.cols,view.rows},':')
      local desired=view.remote.desired
      local settled=not view.remote.busy and desired and desired.cols==view.cols and desired.rows==view.rows
        and math.abs(view.scroll.y-view.scroll.to.y)<.01 and view.history_rows==0
      stable=settled and origin==last_origin and stable+1 or 0;last_origin=origin
      return stable>=3
    end,'stable viewport geometry and scroll')
    local x,y=view:get_content_offset();y=y+view:header_height()
    x,y=math.floor(x+view.cw/2),math.floor(y+view.lh/2)
    system._test_present_probe(x,y)
    -- The initial marker may already be cached and need no new present. Cause
    -- a distinct real PTY update to validate the armed coordinates.
    system._test_event{type='keypressed',key='A'}
    system._test_event{type='textinput',text='@'}
    system._test_event{type='keyreleased',key='A'}
    await(function()local p=system._test_present_probe();return measure.matches(p,-1,0,64)end,'fixture initial presented RGB')
    local report={schema=1,scope='synthetic SDL key -> controller -> server PTY/parser -> attachment stream -> Studio present',
      boundary='uv_hrtime before SDL_PushEvent to uv_hrtime immediately after successful SDL_RenderPresent; retained scene RGB validated afterward',
      limitations={'application presentation proxy, not physical display scanout','injection from core coroutine after a frame; frame-boundary phase',
        'one-pixel GPU readback follows presentation; excluded from current sample, may perturb subsequent frames',
        'isolated home, warm process, one server-owned PTY; no cmux/Ghostty comparison'},
      samples=samples,warmups=warmups,fps=config.fps,gc='enabled',socket_policy='full control serve, named SQLite session enabled',
      build_label=os.getenv('BMUX_BENCH_BUILD_LABEL')or 'unspecified; see binary hashes',project_dir=core.project_dir,
      renderer=system._test_present_probe().backend,pixel={x=x,y=y},geometry={cols=view.cols,rows=view.rows,history_capacity=2000},
      environment={uname=uv.os_uname(),libuv=uv.version_string(),lua=_VERSION,boggart=bog.version,
        cpu=uv.cpu_info()[1].model,total_memory=uv.get_total_memory(),video_driver=os.getenv('SDL_VIDEODRIVER'),
        utc=os.date('!%Y-%m-%dT%H:%M:%SZ')},
      native_sources=require('terminal').source(),renderer_sources=renderer.terminal_sources(),files={},raw={}}
    for _,path in ipairs{'tools/termbench/studio_latency.lua','tools/termbench/measure.lua','tools/termbench/pty_fixture.c',
      'studio/src/renderer.c','studio/src/api/system_test.c','studio/data/core/terminalview.lua',
      'studio/data/fonts/monospace.ttf','studio/data/fonts/font.ttf',EXEFILE,executable,fixture}do report.files[path]=digest(path)end
    for _,file in ipairs(report.native_sources.files)do assert(digest(file.path)==file.sha256,'stale terminal binary: '..file.path)end
    for path,expected in pairs(report.renderer_sources)do assert(digest(path)==expected,'stale renderer binary: '..path)end
    local latencies,readbacks={},{}
    for i=1,warmups+samples do
      assert(core.active_view==view and view.remote:can_control(),'benchmark lost terminal control/focus')
      local ox,oy=view:get_content_offset()
      assert(math.floor(ox+view.cw/2)==x and math.floor(oy+view:header_height()+view.lh/2)==y,'benchmark pixel moved')
      local red=65+(i%26);local text=string.char(red)
      local serial=system._test_present_probe().serial;local sent=uv.hrtime()
      system._test_event{type='keypressed',key=text}
      system._test_event{type='textinput',text=text}
      system._test_event{type='keyreleased',key=text}
      local frame=await(function()
        local p=system._test_present_probe()
        if measure.matches(p,serial,sent,red)then return p end
      end,'input '..i..' presented RGB')
      local elapsed=frame.ns-sent;assert(elapsed>=0)
      if i>warmups then
        latencies[#latencies+1]=elapsed;readbacks[#readbacks+1]=frame.readback_ns
        report.raw[#report.raw+1]={input_byte=red,sent_ns=sent,presented_ns=frame.ns,latency_ns=elapsed,
          frame_serial=frame.serial,readback_ns=frame.readback_ns,rgba=frame.rgba}
      end
    end
    report.latency_ns=measure.summary(latencies);report.readback_ns=measure.summary(readbacks)
    local f=assert(io.open(output,'wb'));assert(f:write(json.encode(report),'\n'));assert(f:close())
    print('Validated Studio key-to-present samples: '..samples..'; p50 '..(report.latency_ns.p50/1e6)..' ms; report '..output)
  end,debug.traceback)
  if not ok and os.getenv('BMUX_LATENCY_REPORT')then system.save_screenshot(os.getenv('BMUX_LATENCY_REPORT')..'.bmp')end
  system._test_present_probe(false)
  if joined then joined:disconnect()end
  if admin then admin:close()end
  if daemon then
    daemon:kill('sigterm')
    local deadline=uv.hrtime()+5e9
    while not daemon.done and uv.hrtime()<deadline do coroutine.yield(0)end
    if not daemon.done then
      pcall(uv.process_kill,daemon.handle,'sigkill')
      local until_at=uv.hrtime()+2e9
      while not daemon.done and uv.hrtime()<until_at do coroutine.yield(0)end
    end
    daemon:_cleanup()
    if not daemon.done then ok=false;why=tostring(why)..'\nbenchmark server failed to stop'end
  end
  if not ok then io.stderr:write(tostring(why),'\n');os.exit(1)end
  core.quit(true)
end)
