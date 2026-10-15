if package.config:sub(1,1)=='\\'then return end
local uv=require 'uv';local proc=require 'proc';local json=require 'json';local control=require 'control'
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-server-XXXXXX'));local socket=dir..'/control.sock'
local input=dir..'/request.json'
local function request(method,path,body,token)
  local file=assert(io.open(input,'w'));file:write(type(body)=='string' and body or json.encode(body or {}));file:close()
  local command='curl -sS --max-time 5 --unix-socket '..q(socket)..' -X '..method..' '
    ..(body~=nil and '--data-binary @'..q(input)..' ' or '')..(token and "-H "..q('Authorization: Bearer '..token)..' ' or '')
    ..q('http://localhost'..path).." -w '\n%{http_code}'"
  local result=proc.run(command,8);assert(result.code==0,result.out)
  local text,status=result.out:match('^(.*)\n(%d+)$');status=tonumber(status)
  local decoded,body=pcall(json.decode,text)
  assert(decoded or status>=400,text);return status,decoded and body or {error=text}
end
assert(control.start{socket=socket,capabilities={'control:GET:/terminals'}})
assert(request('GET','/terminals')==200)
assert(request('POST','/terminals',{cmd='/bin/sh'})==403,'existing scoped policy gates terminal creation')
control.stop();uv.run('nowait')
assert(control.start{socket=socket,token='fixture-token'})
assert(request('GET','/terminals')==401,'transport authenticates before terminal routing')
assert(request('GET','/terminals',nil,'fixture-token')==200)
control.stop();uv.run('nowait')
assert(control.start{socket=socket})
for _,body in ipairs{'{broken','[]','null','{"cmd":false}','{"control":true}'}do assert(request('POST','/terminals',body)==400)end
assert(select(2,request('GET','/terminals')).total==0,'invalid input never spawns')
local status,one=request('POST','/terminals',{cmd='/bin/sh',args={'-c','stty -echo; printf HELD; IFS= read -r line'},cols=40,rows=4,history=0})
assert(status==201 and one.id and one.pid>0)
assert(request('POST','/terminals/'..one.id..'/input',{generation=2,text='stale\n'})==409)
assert(request('POST','/terminals/'..one.id..'/resize',{generation=1,cols=0,rows=4})==400)
assert(request('GET','/terminals?limit=1000')==400 and request('GET','/terminals/'..one.id..'/screen?count=1000')==400)
assert(request('POST','/terminals/'..one.id..'/close',{generation=2})==409)
local pid=one.pid;control.stop();uv.run('nowait')
local deadline=uv.hrtime()+5e9
while uv.kill(pid,0)and uv.hrtime()<deadline do uv.run('nowait');uv.sleep(1)end
assert(not uv.kill(pid,0),'control shutdown retires the actual owned child')

-- A distinct real daemon proves ownership does not depend on this client.
assert(uv.fs_mkdir(dir..'/home',448))
local daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')
  ..' '..q(uv.exepath())..' serve --socket '..q(socket),30)
local function await(check)
  local until_at=uv.hrtime()+8e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(2)until uv.hrtime()>until_at
  error('server terminal deadline: '..daemon:result().out)
end
local function screen(id)
  local code,page=request('GET','/terminals/'..id..'/screen');assert(code==200)
  local out={};for _,row in ipairs(page.screen)do for _,cell in ipairs(row.cells)do out[#out+1]=cell.text end;out[#out+1]='\n'end
  return table.concat(out)
end
local success,failure=xpcall(function()
  await(function()return uv.fs_stat(socket)end)
  local code,terminal=request('POST','/terminals',{cmd='/bin/sh',args={'-c',[[stty -echo; printf 'SERVER_READY\r\n'; IFS= read -r line; printf '%s\r\n' "$line"; stty size; exit 7]]},cols=40,rows=6,history=0})
  assert(code==201 and terminal.pid>0)
  await(function()return screen(terminal.id):find('SERVER_READY',1,true)end)
  -- Every request above has disconnected; the next independent client gets it.
  local _,same=request('GET','/terminals/'..terminal.id)
  assert(same.pid==terminal.pid and same.generation==terminal.generation and same.state=='alive')
  assert(request('POST','/terminals/'..terminal.id..'/resize',{generation=1,cols=72,rows=12})==200)
  assert(request('POST','/terminals/'..terminal.id..'/input',{generation=1,text='FROM_SECOND_CLIENT 🦊\n'})==200)
  await(function()return select(2,request('GET','/terminals/'..terminal.id)).state=='failed'end)
  local output=screen(terminal.id)
  assert(output:find('FROM_SECOND_CLIENT 🦊',1,true) and output:find('12 72',1,true))
  assert(select(2,request('GET','/terminals/'..terminal.id)).exit_status==7)
  assert(request('POST','/terminals/'..terminal.id..'/close',{generation=1})==200)
  local _,held=request('POST','/terminals',{cmd='/bin/sh',args={'-c','trap "" HUP; printf SHUTDOWN_READY; while :; do sleep 1; done'},cols=40,rows=4,history=0})
  await(function()return screen(held.id):find('SHUTDOWN_READY',1,true)end)
  assert(uv.kill(daemon.pid,'sigterm'));local result=daemon:wait()
  assert(result.code==0,result.out);assert(not uv.fs_stat(socket),'idle daemon handles SIGTERM and removes its socket')
  await(function()return not uv.kill(held.pid,0)end)
end,debug.traceback)
if not success then daemon:kill('sigkill');daemon:wait();error(failure)end
uv.fs_unlink(input)
print('terminal_server: scoped/authenticated routes, malformed requests, actual serve daemon, independent clients, same PID input/resize/exit and graceful shutdown pass')
return 0
