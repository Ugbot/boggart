-- Separate-process system benchmark. Run with boggart --eval from repo root.
package.path='tools/?.lua;'..package.path
local uv=require 'uv';local json=require 'json';local hash=require 'hash_c'
local Client=require 'terminal.client';local measure=require 'termbench.measure'
local owned,clients={},{};local root=uv.cwd()
local startup_trace=os.getenv('BMUX_SYSTEM_STARTUP_TRACE')=='1'
assert(not os.getenv('BMUX_SYSTEM_STARTUP_TRACE')or startup_trace,'invalid BMUX_SYSTEM_STARTUP_TRACE')
local function setting(name,default,lo,hi)
  local n=tonumber(os.getenv(name)or default)
  assert(n and n%1==0 and n>=lo and n<=hi,'invalid '..name);return n
end
local function read(path)
  local f=io.open(path,'rb');if not f then return end
  local bytes=f:read('a');f:close();return bytes
end
local function digest(path)return hash.sha256(assert(read(path),'cannot read '..path))end
local function environment(home,extra)
  local values={PATH='/usr/bin:/bin:/usr/sbin:/sbin',HOME=home,BOGGART_HOME=home..'/.boggart',
    SHELL='/bin/sh',TERM='xterm-256color',LANG='C',TMPDIR='/tmp'}
  for _,k in ipairs{'DISPLAY','XAUTHORITY','WAYLAND_DISPLAY','XDG_RUNTIME_DIR','SDL_VIDEODRIVER'}do values[k]=os.getenv(k)end
  for k,v in pairs(extra or {})do values[k]=v end
  local out={};for k,v in pairs(values)do out[#out+1]=k..'='..v end;return out
end
local function spawn(executable,args,home,label,extra)
  local p={log=home..'/'..label..'.log',label=label}
  local fd=assert(uv.fs_open(p.log,'w',384))
  p.start_ns=uv.hrtime()
  p.handle,p.pid=uv.spawn(executable,{args=args,cwd=root,env=environment(home,extra),stdio={nil,fd,fd}},function(code,signal)
    p.done=true;p.code=code;p.signal=signal
    if p.handle and not p.handle:is_closing()then p.handle:close()end
  end)
  uv.fs_close(fd);assert(p.handle,'spawn '..label..': '..tostring(p.pid));owned[#owned+1]=p;return p
end
local function await(fn,label,ms)
  local expired=false;local timer=uv.new_timer();timer:start(ms or 30000,0,function()expired=true end)
  local ok,result=xpcall(function()
    repeat
      local value=fn();if value then return value end
      assert(not expired,'deadline: '..label)
      uv.run('once')
    until false
  end,debug.traceback)
  timer:stop();timer:close();if not ok then error(result,0)end;return result
end
local function sleep(ms)
  local done=false;local timer=uv.new_timer();timer:start(ms,0,function()done=true end)
  await(function()return done end,'idle interval',ms+1000);timer:stop();timer:close()
end
local function stop(p,signal)
  if not p or p.done then return end
  assert(p.handle:kill(signal or 'sigterm'))
  local ok=pcall(await,function()return p.done end,'stop '..p.label,5000)
  if not ok and not p.done then p.handle:kill('sigkill');await(function()return p.done end,'kill '..p.label,5000)end
end
local function stop_normal(p,signal)
  stop(p,signal)
  assert(p.code==0 and p.signal==0,p.label..' did not exit normally: '..tostring(p.code)..'/'..tostring(p.signal)..' '..tostring(read(p.log)))
end
local function call(c,method,path,body)
  local done,why,value,elapsed=false;local begin=uv.hrtime()
  c:request(method,path,body,function(e,v)elapsed=uv.hrtime()-begin;why=e;value=v;done=true end)
  await(function()return done end,'request '..path,10000)
  assert(not why,why and why.message..' '..tostring(why.status));return value,elapsed
end
local function check(p)assert(not p.done,p.label..' exited: '..tostring(read(p.log)))end
local function mkdir(path)assert(uv.fs_mkdir(path,448));return path end
local function client(socket)
  local c=Client.new{socket=socket};clients[#clients+1]=c;return c
end
local function serve(executable,dir,app_home)
  local home=mkdir(dir..'/server');local socket=dir..'/sock'
  local p=spawn(executable,{'serve','--socket',socket},home,'server',app_home and {HOME=app_home,BOGGART_HOME=app_home..'/.boggart'})
  -- Socket observation uses a 1 ms repeating timer. Its error is included in
  -- process-to-health readiness, never in timed request callbacks below.
  local pulse=uv.new_timer();pulse:start(1,1,function()end)
  local ok,why=xpcall(function()
    await(function()check(p);local st=uv.fs_lstat(socket);return st and st.type=='socket'and st.mode&63==0 end,'private server socket')
  end,debug.traceback)
  pulse:stop();pulse:close();if not ok then error(why,0)end
  local c=client(socket);p.readiness_probes=0
  -- bind/chmod make a private socket observable BEFORE uv_listen is ready.
  -- Only a successfully decoded health reply proves startup readiness. Retry
  -- this safe GET during startup; measured RTT requests below never retry.
  local healthy=false;local deadline=p.start_ns+30e9
  repeat
    check(p);p.readiness_probes=p.readiness_probes+1
    local success,value=pcall(call,c,'GET','/health')
    healthy=success and value.ok==true
    if not healthy then sleep(1)end
  until healthy or uv.hrtime()>deadline
  assert(healthy,'server never became healthy: '..tostring(read(p.log)))
  p.ready_ns=uv.hrtime();return p,c,socket
end
local function setup(c,fixture,n)
  local layout=call(c,'GET','/layout')
  local function edit(op,args)
    local body={op=op,host_id=layout.host_id,revision=layout.revision}
    for k,v in pairs(args or {})do body[k]=v end
    layout=call(c,'POST','/layout/commands',body);return layout
  end
  edit('workspace_create',{title='System benchmark'})
  local w=layout.workspaces[1];local s=w.surfaces[1];local records={};local queue={s.tree.id};local head=1
  local function parent(node,id)
    if node.type~='leaf'then
      if node.a.id==id or node.b.id==id then return node end
      return parent(node.a,id)or parent(node.b,id)
    end
  end
  for i=1,n do
    local r=call(c,'POST','/terminals',{cmd=fixture,cols=80,rows=24,history=2000});records[i]=r
    assert(r.pid and r.state=='alive','fixture failed to launch')
    local args={workspace_id=w.id,surface_id=s.id,pane_id=queue[head],
      view={kind='terminal',terminal_id=r.id,generation=r.generation,title='Fixture '..i}}
    if i==1 then edit('view_add',args)
    else
      args.direction=i%2==0 and 'right'or 'down';edit('pane_split',args)
      -- Splitting preserves the old leaf ID and gives its parent a NEW ID.
      local split=assert(parent(layout.workspaces[1].surfaces[1].tree,queue[head]))
      head=head+1;queue[#queue+1]=split.a.id;queue[#queue+1]=split.b.id
    end
  end
  -- Breadth-first splits bound tree depth; focus/zoom only after all real
  -- panes exist. Every hidden view remains attached in the Studio pool.
  local function first(node)
    if node.type~='leaf'then return first(node.a)or first(node.b)end
    for _,v in ipairs(node.views)do if v.terminal_id==records[1].id then return node.id end end
  end
  local pane=assert(first(layout.workspaces[1].surfaces[1].tree))
  edit('pane_focus',{workspace_id=w.id,surface_id=s.id,pane_id=pane})
  if n>1 then edit('pane_zoom',{workspace_id=w.id,surface_id=s.id,pane_id=pane})end
  assert(call(c,'GET','/terminals').total==n,'wrong resident PTY count')
  return records,layout
end
local function studio(executable,dir,socket,n,app_home)
  local home=mkdir(dir..'/studio');local ready=home..'/ready.json'
  local p=spawn(executable,{'.'},home,'studio',{BOGGART_STUDIO_SCRIPT=root..'/tools/termbench/studio_system.lua',
    BMUX_SYSTEM_SOCKET=socket,BMUX_SYSTEM_READY=ready,BMUX_SYSTEM_PANES=tostring(n),
    BOGGART_STUDIO_STARTUP_TRACE=startup_trace and '1'or nil,
    HOME=app_home or home,BOGGART_HOME=(app_home or home)..'/.boggart'})
  local pulse=uv.new_timer();pulse:start(1,1,function()end)
  local ok,out=xpcall(function()
    return await(function()check(p);local bytes=read(ready);if bytes then return assert(json.decode(bytes))end end,'Studio first frame and all attachments',45000)
  end,debug.traceback)
  pulse:stop();pulse:close();if not ok then error(out,0)end
  assert(out.pid==p.pid and out.panes==n and out.attached==n and out.first_present_ns>=p.start_ns,'invalid Studio readiness')
  assert(uv.fs_realpath(out.store)==uv.fs_realpath((app_home or home)..'/.boggart'),'Studio used an unexpected application store')
  assert(out.first_frame.valid and out.first_frame.rgba[1]==0 and out.first_frame.rgba[2]==64
    and out.first_frame.rgba[3]==192 and out.first_frame.rgba[4]==255,'unvalidated Studio frame')
  for _,f in ipairs(out.native_sources.files)do assert(digest(f.path)==f.sha256,'stale native binary: '..f.path)end
  for path,expected_hash in pairs(out.renderer_sources)do assert(digest(path)==expected_hash,'stale renderer binary: '..path)end
  if startup_trace then
    out.startup_phases=measure.startup_phases(assert(read(p.log)),p.start_ns,out.first_present_ns)
    for _,name in ipairs{'script_loaded','first_step_enter','first_draw_enter','first_draw_return',
      'first_present_enter','first_present_return','join_requested','join_callback','terminal_probe_armed'}do
      local stamp=assert(out.startup_milestones[name],'missing startup milestone '..name)
      assert(stamp>=p.start_ns and stamp<=out.all_attached_ns,'invalid startup milestone')
    end
  end
  return p,out
end
local function snapshot(sampler,dir,pids)
  local args={};for _,pid in ipairs(pids)do args[#args+1]=tostring(pid)end
  local p=spawn(sampler,args,dir,'sample')
  await(function()return p.done end,'native per-PID sampler',10000)
  assert(p.code==0 and p.signal==0,'sampler failed: '..tostring(read(p.log)))
  local data=assert(json.decode(assert(read(p.log))));assert(#data.processes==#pids,'sampler omitted PID');return data
end
local function main()
  assert(uv.os_uname().sysname=='Darwin'or uv.os_uname().sysname=='Linux','sampler requires macOS/Linux')
  local output=assert(os.getenv('BMUX_SYSTEM_REPORT'),'BMUX_SYSTEM_REPORT required')
  local executable=assert(uv.exepath());local studio_bin=assert(os.getenv('BMUX_SYSTEM_STUDIO'),'BMUX_SYSTEM_STUDIO required')
  local fixture=assert(os.getenv('BMUX_BENCH_FIXTURE'),'BMUX_BENCH_FIXTURE required')
  local sampler=assert(os.getenv('BMUX_SYSTEM_SAMPLER'),'BMUX_SYSTEM_SAMPLER required')
  local starts=setting('BMUX_SYSTEM_STARTS',20,1,200);local idle_samples=setting('BMUX_SYSTEM_IDLE_SAMPLES',3,1,20)
  local idle_ms=setting('BMUX_SYSTEM_IDLE_MS',5000,100,60000);local settle_ms=setting('BMUX_SYSTEM_SETTLE_MS',1000,0,60000)
  local rtt_samples=setting('BMUX_SYSTEM_RTT_SAMPLES',1000,1,10000);local rtt_warm=setting('BMUX_SYSTEM_RTT_WARMUPS',100,1,1000)
  local home_profile=os.getenv('BMUX_SYSTEM_HOME_PROFILE')or 'shared-existing'
  assert(home_profile=='separate-new'or home_profile=='shared-new'or home_profile=='shared-existing','invalid home profile')
  local starts_only=os.getenv('BMUX_SYSTEM_STARTS_ONLY')=='1'
  local panes={};for part in (os.getenv('BMUX_SYSTEM_PANES')or '1,10,100'):gmatch('[^,]+')do
    local n=tonumber(part);assert(n and n%1==0 and n>=1 and n<=100,'invalid pane count');panes[#panes+1]=n
  end
  assert(#panes>0 and #panes<=3,'one to three pane scenarios required')
  assert(collectgarbage('isrunning'),'normal GC required')
  local dir=assert(uv.fs_mkdtemp('/tmp/bmux-system-XXXXXX'))
  -- The excluded warmup initializes this private home. Measured trials always
  -- use fresh processes and a fresh named Bmux session/socket, retaining the
  -- installed application store/config. No real user home is touched.
  local retained=home_profile=='shared-existing'and mkdir(dir..'/initialized-home')or nil
  local report={schema=1,scope='separate-process startup, full-policy control RTT, idle per-PID CPU/RSS',
    environment={uname=uv.os_uname(),cpu=uv.cpu_info()[1].model,memory_bytes=uv.get_total_memory(),libuv=uv.version_string(),
      lua=_VERSION,boggart=bog.version,utc=os.date('!%Y-%m-%dT%H:%M:%SZ'),video_driver=os.getenv('SDL_VIDEODRIVER')},
    build_label=os.getenv('BMUX_BENCH_BUILD_LABEL')or 'unspecified; binary hashes authoritative',
    configuration={project_dir=root,home_profile=home_profile,startup_only=starts_only,
      startup_trace=startup_trace,startup_trace_cost='opt-in phase clocks and stderr writes perturb startup; keep uninstrumented latency alongside attribution',
      home='controlled private homes; shared-existing reuses warmup initialized HOME across startup trials; shared-new uses one new HOME per pair; separate-new uses independent new homes',
      resource_home=home_profile=='separate-new'and 'independent new homes per pair'or 'one new shared home per resource scenario; sampled after app initialization',
      credentials='no user credentials/config inherited',
      history_capacity=2000,geometry={80,24},visible_panes=1,topology='balanced split tree, first pane zoomed, ALL N views attached',
      idle_ms=idle_ms,idle_samples=idle_samples,settle_ms=settle_ms,resource_scope='server, Studio and explicitly owned fixture PIDs; coordinator/sampler/other helpers excluded',
      rss='resident bytes; role sums do not deduplicate shared pages',cpu='user+system delta / per-PID monotonic interval; percent of one CPU, summed by role',
      startup='fresh processes, warm filesystem caches; home/store initialization defined by home_profile; no global cache flush',
      server_ready='before uv.spawn to first fully decoded healthy /health reply; 1ms socket observation and safe readiness GET retries included',
      studio_ready='before uv.spawn to first RGB-validated SDL present API return; ready-file observation excluded',
      full_start='before server uv.spawn through readiness probe, native PTY/layout setup and Studio spawn to first validated terminal present',
      rtt='native client request call through complete decoded health reply; new UDS connection each time; separate server process',
      persistence='normal named SQLite journal enabled',frame_probe='disabled after first validated frame; no sampling thread/timer during idle'},
    files={},startup={warmups=1,samples=starts,raw={}},resources={},logs=dir}
  for _,path in ipairs{executable,studio_bin,fixture,sampler,'tools/termbench/system.lua','tools/termbench/studio_system.lua',
    'tools/termbench/process_sample.c','tools/termbench/measure.lua','tools/termbench/pty_fixture.c',
    'src/lserve.c','src/bogembed.c','studio/src/main.c','lua/terminal/transport.lua','CMakeLists.txt'}do report.files[path]=digest(path)end
  local server_times,studio_times,full_times={},{},{}
  for i=0,starts do
    io.stderr:write('system termbench: startup ',i,'/',starts,'\n');io.stderr:flush()
    local trial=mkdir(dir..'/start-'..i)
    local app_home=retained or home_profile=='shared-new'and mkdir(trial..'/home')or nil
    local server,c,socket=serve(executable,trial,app_home)
    setup(c,fixture,1);local ui,ready=studio(studio_bin,trial,socket,1,app_home)
    if i>0 then
      local a,b=server.ready_ns-server.start_ns,ready.first_present_ns-ui.start_ns
      local full=ready.first_present_ns-server.start_ns
      server_times[#server_times+1]=a;studio_times[#studio_times+1]=b
      full_times[#full_times+1]=full
      report.startup.raw[#report.startup.raw+1]={server_pid=server.pid,studio_pid=ui.pid,server_readiness_probes=server.readiness_probes,
        server_spawn_ns=server.start_ns,server_ready_ns=server.ready_ns,server_ns=a,
        studio_spawn_ns=ui.start_ns,first_present_ns=ready.first_present_ns,studio_ns=b,full_start_ns=full,studio=ready}
    end
    stop_normal(ui,'sigusr1');c:close();stop_normal(server)
  end
  report.startup.server_ns=measure.summary(server_times);report.startup.studio_ns=measure.summary(studio_times)
  report.startup.full_start_ns=measure.summary(full_times)
  for _,n in ipairs(starts_only and {}or panes)do
    io.stderr:write('system termbench: ',n,' resident/attached panes\n');io.stderr:flush()
    local trial=mkdir(dir..'/panes-'..n)
    local app_home=home_profile~='separate-new'and mkdir(trial..'/home')or nil
    local server,c,socket=serve(executable,trial,app_home)
    local records,layout=setup(c,fixture,n);local ui,ready=studio(studio_bin,trial,socket,n,app_home)
    sleep(settle_ms)
    local pids,roles={server.pid,ui.pid},{[server.pid]='server',[ui.pid]='studio'}
    for _,r in ipairs(records)do pids[#pids+1]=r.pid;assert(not roles[r.pid],'duplicate owned PID');roles[r.pid]='pty'end
    local scenario={panes=n,attached=ready.attached,visible=1,studio=ready,layout=layout,raw={}}
    for i=1,idle_samples do
      check(server);check(ui)
      local before=snapshot(sampler,trial,pids);sleep(idle_ms);local after=snapshot(sampler,trial,pids)
      local result=measure.resources(before,after,roles);assert(result.roles.pty.count==n)
      scenario.raw[i]={before=before,after=after,usage=result}
    end
    -- Time real client callbacks, not a 1ms poll loop or Studio frame cadence.
    local times={}
    for i=1,rtt_warm+rtt_samples do
      local value,elapsed=call(c,'GET','/health');assert(value.ok==true)
      if i>rtt_warm then times[#times+1]=elapsed end
    end
    scenario.rtt={warmups=rtt_warm,raw_ns=times,ns=measure.summary(times)}
    report.resources[#report.resources+1]=scenario
    stop_normal(ui,'sigusr1');c:close();stop_normal(server)
  end
  local f=assert(io.open(output,'wb'));assert(f:write(json.encode(report),'\n'));assert(f:close())
  print('System termbench: '..home_profile..'; '..starts..' process starts; '
    ..(starts_only and 'startup only'or 'pane scenarios '..table.concat(panes,','))..'; report '..output)
end
local ok,why=xpcall(main,debug.traceback)
for _,c in ipairs(clients)do c:close()end
for i=#owned,1,-1 do local cleaned,err=pcall(stop,owned[i]);if not cleaned then ok=false;why=tostring(why)..'\n'..tostring(err)end end
uv.run('nowait')
if not ok then io.stderr:write(tostring(why),'\n');return 1 end
return 0
