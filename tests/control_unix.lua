-- Real UDS transport, native client, endpoint ownership and handle teardown.
if package.config:sub(1,1)=='\\' then return end
local uv=require 'uv';local proc=require 'proc';local json=require 'json'
local function quote(s)return "'"..s:gsub("'","'\\''").."'"end
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-control-XXXXXX'))
local path=dir..'/control.sock';local reached=0
local function handler(req)
  reached=reached+1
  assert(req.authenticated and req.remote=='unix')
  if req.path=='/events' then return 'stream' end
  if req.path=='/error' then error(string.rep('x',2048))end
  return 200,json.encode{ok=true,body=req.body}
end
local server=assert(serve.listen{socket=path,body_limit=64,handler=handler})
assert(server:socket()==path and server:port()==nil)
assert(uv.fs_stat(path).mode%512==384,'socket permissions are 0600')
local function request(extra)
  local r=proc.run('curl -sS --max-time 3 --unix-socket '..quote(path)..' '..(extra or '')..' http://localhost/health',5)
  assert(r.code==0,r.out);return r.out
end
assert(json.decode(request()).ok,'UDS request reaches Lua with authenticated local peer')
for _,headers in ipairs{"-H 'Origin: http://localhost'","-H 'Host: evil.invalid'"}do
  assert(request(headers.." -o /dev/null -w '%{http_code}'")=='403','browser origins/foreign host refused')
end
assert(reached==1,'transport rejects before route dispatch')
assert(request("-H 'Content-Length: 65' -d x -o /dev/null -w '%{http_code}'")=='400','per-listener body cap')
assert(json.decode(request("-X POST -d 'hello' ")).body=='hello')
assert(request("--request-target /error -o /dev/null -w '%{http_code}'")=='500','long Lua error is bounded')
local cli=quote(uv.exepath())..' ctl --socket '..quote(path)
local health=proc.run(cli..' health',5);assert(health.code==0 and json.decode(health.out).ok,health.out)
local collision=serve.listen{socket=path,handler=handler};assert(not collision and uv.fs_stat(path),'live socket is never replaced')
local public=assert(uv.fs_mkdtemp('/tmp/bmux-public-XXXXXX'));assert(uv.fs_chmod(public,493))
assert(not serve.listen{socket=public..'/unsafe.sock',handler=handler},'public parent refused')
assert(uv.fs_rmdir(public))
assert(not serve.listen{socket='relative.sock',handler=handler},'relative socket refused')
local link=dir..'/link';assert(uv.fs_symlink(path,link))
assert(not serve.listen{socket=link,handler=handler},'symlink collision refused');assert(uv.fs_unlink(link))
assert(serve.verify_token('secret','secret') and not serve.verify_token('secret','secrex') and not serve.verify_token('secret','secret\0'))

-- A retained replacement must survive both stop and libuv's close callback.
assert(uv.fs_unlink(path));local file=assert(io.open(path,'w'));file:write('replacement');file:close()
assert(server:stop() and not server:stop());uv.run('nowait')
file=assert(io.open(path));assert(file:read('*a')=='replacement');file:close();assert(uv.fs_unlink(path))
server=nil;collectgarbage('collect');uv.run('nowait')
local lock_path=path..'.lock'
file=assert(io.open(lock_path,'w'));file:write('user file');file:close();assert(uv.fs_chmod(lock_path,384))
assert(not serve.listen{socket=path,handler=handler},'an unrelated lock-path file is not adopted')
file=assert(io.open(lock_path));assert(file:read('*a')=='user file');file:close();assert(uv.fs_unlink(lock_path))
assert(uv.fs_symlink(path,lock_path));assert(not serve.listen{socket=path,handler=handler},'a lock-path symlink is refused')
assert(uv.fs_lstat(lock_path).type=='link');assert(uv.fs_unlink(lock_path))

-- SIGKILL cannot unlink its socket. A private stale inode is recoverable,
-- while the live/file/link collision checks above retain their guarantees.
local stale=proc.start('BOGGART_TEST_SOCKET='..quote(path)..' '..quote(uv.exepath())..' --eval tests/fixtures/control_stale.lua',10)
local until_stale=uv.hrtime()+3e9
repeat uv.run('nowait');if uv.fs_lstat(path)then break end;uv.sleep(1)until uv.hrtime()>until_stale
assert(uv.fs_lstat(path));stale:kill('sigkill');stale:wait()
assert(uv.fs_lstat(path),'crash leaves the owned socket inode')
server=assert(serve.listen{socket=path,handler=handler});server:stop();uv.run('nowait')

local function await(check)
  local deadline=uv.hrtime()+2e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('UDS callback deadline')
end
-- Collect an owner while native clients and pending writes still exist.
for i=1,12 do
  server=assert(serve.listen{socket=path,handler=handler})
  local client=uv.new_pipe(false);local connected,done=false,false
  client:connect(path,function(err)
    assert(not err,err);connected=true
    client:read_start(function(read_error,data)
      assert(not read_error,read_error)
      if not data then done=true;client:close()end
    end)
    client:write('GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n')
  end)
  await(function()return connected and server:clients()==1 end)
  server:broadcast('fixture',string.rep('q',65536))
  server=nil;collectgarbage('collect')
  await(function()return done end)
  assert(not uv.fs_stat(path),'GC removes only owned socket')
end

-- High-level routes share this transport; no bearer is needed for private UDS.
local control=require 'control';server=assert(control.start{socket=path})
assert(json.decode(request()).ok);control.stop();uv.run('nowait')

-- Application shutdown must close retained listeners before luv finalization.
local r=proc.run('BOGGART_TEST_SOCKET='..quote(path)..' '..quote(uv.exepath())..' --eval tests/fixtures/control_shutdown.lua',5)
assert(r.code==0,r.out);assert(not uv.fs_stat(path),'application shutdown removes retained socket')
local w=worker.spawn(string.format([[
  rawset(_G,'retained_control_listener',assert(serve.listen{socket=%q,
    handler=function()return 200,'{}'end}))
  worker.post('worker owns control listener')
]],path))
assert(worker.recv(w,5000)=='worker owns control listener');assert(worker.join(w))
assert(not uv.fs_stat(path),'worker shutdown removes retained socket')
assert(uv.fs_rmdir(dir));print('control_unix: permissions, real requests, native ctl, ownership, GC and shutdown pass')
return 0
