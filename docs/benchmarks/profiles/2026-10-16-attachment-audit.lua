local json=require 'json';local hash=require 'hash_c'
local function read(path)local f=assert(io.open(path,'rb'));local b=f:read('a');f:close();return b end
local function decode(path)return json.decode(read(path))end
local base='docs/benchmarks/2026-10-16-attachment-'
for _,build in ipairs{'normal','asan'}do
  local studio,hashes
  hashes=0
  local function check(path,expected)assert(hash.sha256(read(path))==expected,'identity mismatch: '..path);hashes=hashes+1 end
  if build=='normal'then
    local report=decode(base..'paced-normal.json')
    assert(report.configuration.control_diagnostics and report.configuration.diagnostic_capture_delay_ms==60)
    assert(#report.resources==1 and report.startup.samples==1)
    local resource=report.resources[1]
    assert(resource.panes==100 and resource.attached==100 and resource.visible==1)
    for path,expected in pairs(report.files)do check(path,expected)end
    studio=resource.studio
  else studio=decode(base..'ready-after-asan.json')end
  assert(studio.attached==100 and studio.panes==100)
  assert(studio.first_frame.valid and table.concat(studio.first_frame.rgba,',')=='0,64,192,255')
  for _,file in ipairs(studio.native_sources.files)do check(file.path,file.sha256)end
  for path,expected in pairs(studio.renderer_sources)do check(path,expected)end
  if studio.core_source.kind=="file" then check(studio.core_source.path,studio.core_source.sha256) end
  for _,file in pairs(studio.font_assets)do if file.kind=="file" then check(file.path,file.sha256) end end
  local client=decode(base..'client-after-'..build..'.json')
  local server=decode(base..'server-after-'..build..'.json')
  assert(not client.truncated and not server.truncated,'incomplete trace')
  local snapshots,streams,events={},{},{}
  for _,r in ipairs(client.requests)do
    assert(not r.error,'client error: '..r.path)
    local id=r.path:match('^/terminals/([^/]+)/attachments$')
    if id and r.method=='POST'then
      assert(not snapshots[id] and r.status==200 and r.done_ns)
      snapshots[id]=r;events[#events+1]={r.start_ns,1}
    end
    id=r.path:match('^/terminals/([^/]+)/attachments/[^/]+/stream$')
    if id then
      assert(not streams[id] and r.status==200 and r.events>=1 and r.first_event_ns)
      streams[id]=r;events[#events+1]={r.first_event_ns,-1}
    end
  end
  local count=0
  for id in pairs(snapshots)do assert(streams[id]);count=count+1 end
  assert(count==100 and #events==200)
  table.sort(events,function(a,b)return a[1]<b[1]or a[1]==b[1]and a[2]<b[2]end)
  local active,peak=0,0
  for _,e in ipairs(events)do active=active+e[2];assert(active>=0);peak=math.max(active,peak)end
  assert(active==0 and peak==4,'admission overlap mismatch')
  local handled=0
  for _,r in ipairs(server.requests)do
    if r.method=='POST'and r.path:match('^/terminals/[^/]+/attachments$')then
      assert(r.status==200);handled=handled+1
    end
  end
  assert(handled==100 and server.capture_delay_ms==60)
  local function privacy(t)
    for k,v in pairs(t)do
      assert(k~='body'and k~='token'and k~='authorization'and k~='payload','private field')
      if type(v)=='table'then privacy(v)end
    end
  end
  privacy(client);privacy(server)
  print(('%s: 100 snapshots + 100 first stream events, no client errors, peak handshakes=%d, 100 server attachments, valid first frame, %d current identities verified; complete metadata-only traces'):format(build,peak,hashes))
end
print('ASAN resource sampling is NOT a pass: separate pre-exec child failure BMUX-109, both failed attempts retained.')
