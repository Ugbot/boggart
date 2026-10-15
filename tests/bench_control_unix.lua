-- Diagnostic only; no timing assertion. Run with the native CLI --eval.
local uv=require 'uv';local json=require 'json';local control=require 'control'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-rtt-XXXXXX'));local path=dir..'/control.sock'
local registrar=os.getenv('BMUX_BENCH_REGISTRAR')=='1'
local server
if registrar then
  local service=require('manualfleet').new{registry=require('fleet').default,clock=function()return uv.hrtime()/1e9 end}
  server=assert(serve.listen{socket=path,body_limit=32768,handler=function(req)return service:handle(req)end})
else server=assert(control.start{socket=path})end
local samples={}
for i=1,1100 do
  local client=uv.new_pipe(false);local done=false;local received='';local start=uv.hrtime()
  client:connect(path,function(err)
    assert(not err,err)
    client:read_start(function(read_error,data)
      assert(not read_error,read_error)
      if data then received=received..data else
        local elapsed=(uv.hrtime()-start)/1000
        if i>100 then samples[#samples+1]=elapsed end
        done=true;client:close()
      end
    end)
    client:write('GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n')
  end)
  while not done do uv.run('once')end
  assert(received:find('200 OK',1,true) and received:find('"ok":true',1,true))
end
if registrar then server:stop()else control.stop()end
uv.run('nowait');assert(uv.fs_rmdir(dir));table.sort(samples)
print(json.encode{benchmark='control_unix_health',transport='HTTP/1.1 over UDS',samples=#samples,warmup=100,
  unit='microseconds',min=samples[1],median=samples[500],p95=samples[950],p99=samples[990],max=samples[1000],
  route=registrar and 'manual Fleet registrar health' or 'full policy-scoped control health',
  scope='same-process libuv client/listener, connect through response EOF; no Studio frame scheduling or process startup'})
return 0
