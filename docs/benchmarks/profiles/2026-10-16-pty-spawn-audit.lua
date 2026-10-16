local json=require 'json';local hash=require 'hash_c'
local function read(path)local f=assert(io.open(path,'rb'));local b=f:read('a');f:close();return b end
local function decode(path)return json.decode(read(path))end
local base='docs/benchmarks/2026-10-16-pty-spawn-'
for _,build in ipairs{'normal','asan'}do
  local r=decode(base..build..'.json')
  assert(r.configuration.control_diagnostics and r.configuration.diagnostic_capture_delay_ms==60)
  assert(#r.resources==1 and r.startup.samples==1)
  local scenario=r.resources[1];local studio=scenario.studio
  assert(scenario.panes==100 and scenario.attached==100 and scenario.visible==1)
  assert(studio.first_frame.valid and table.concat(studio.first_frame.rgba,',')=='0,64,192,255')
  assert(#scenario.raw==1)
  local usage=scenario.raw[1].usage.roles
  assert(usage.pty.count==100 and usage.server.count==1 and usage.studio.count==1)
  assert(#scenario.raw[1].before.processes==102 and #scenario.raw[1].after.processes==102)
  local hashes=0
  local function check(path,expected)assert(hash.sha256(read(path))==expected,'identity mismatch: '..path);hashes=hashes+1 end
  for path,expected in pairs(r.files)do check(path,expected)end
  for _,file in ipairs(studio.native_sources.files)do check(file.path,file.sha256)end
  for path,expected in pairs(studio.renderer_sources)do check(path,expected)end
  if studio.core_source.kind=='file'then check(studio.core_source.path,studio.core_source.sha256)end
  for _,file in pairs(studio.font_assets)do if file.kind=='file'then check(file.path,file.sha256)end end
  local client=decode(base..'client-'..build..'.json')
  local server=decode(base..'server-'..build..'.json')
  assert(not client.truncated and not server.truncated)
  local snapshots,streams,events={},{},{}
  for _,request in ipairs(client.requests)do
    assert(not request.error,'client request failed: '..request.path)
    local id=request.path:match('^/terminals/([^/]+)/attachments$')
    if id and request.method=='POST'then
      assert(not snapshots[id] and request.status==200 and request.done_ns)
      snapshots[id]=request;events[#events+1]={request.start_ns,1}
    end
    id=request.path:match('^/terminals/([^/]+)/attachments/[^/]+/stream$')
    if id then
      assert(not streams[id] and request.status==200 and request.events>=1 and request.first_event_ns)
      streams[id]=request;events[#events+1]={request.first_event_ns,-1}
    end
  end
  local count=0;for id in pairs(snapshots)do assert(streams[id]);count=count+1 end
  assert(count==100 and #events==200)
  table.sort(events,function(a,b)return a[1]<b[1]or a[1]==b[1]and a[2]<b[2]end)
  local active,peak=0,0
  for _,event in ipairs(events)do active=active+event[2];assert(active>=0);peak=math.max(active,peak)end
  assert(active==0 and peak==4)
  local handled=0;for _,request in ipairs(server.requests)do
    if request.method=='POST'and request.path:match('^/terminals/[^/]+/attachments$')then assert(request.status==200);handled=handled+1 end
  end
  assert(handled==100 and server.capture_delay_ms==60)
  print(('%s: 100 live owned PTYs + server/Studio sampled before/after, 100 successful snapshots/first events, peak handshake concurrency=4, valid terminal frame, %d current identities verified'):format(build,hashes))
end
