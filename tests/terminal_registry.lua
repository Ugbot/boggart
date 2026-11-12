if package.config:sub(1,1)=='\\'then return end
local uv=require 'uv';local Registry=require 'terminal.registry';local json=require 'json'
local function await(check)
  local deadline=uv.hrtime()+5e9
  repeat uv.run('nowait');if check()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('terminal registry deadline')
end
local function text(registry,id)
  local page=assert(registry:screen(id));local out={}
  for _,row in ipairs(page.screen)do local line={};for _,cell in ipairs(row.cells)do line[#line+1]=cell.text end;out[#out+1]=table.concat(line)end
  return table.concat(out,'\n')
end
local registry=Registry.new{max_records=2,max_cells=200}
local function open(script,extra)
  local opts={cmd='/bin/sh',args={'-c',script},cols=20,rows=4,history=0}
  for k,v in pairs(extra or {})do opts[k]=v end
  return registry:open(opts)
end
for _,bad in ipairs{false,{cmd=false},{args={false}},{args={extra='bad'}},{env={'X=1','X=2'}},
  {cols=false},{cols=0},{history=-1},{cwd='\0'},{cmd='/bin/sh',control=true}}do
  local result,why=registry:open(bad);assert(not result and why.status==400)
end
assert(#registry.order==0 and registry.used==0,'invalid options have no lifecycle side effects')
local one=assert(open([[stty -echo; printf READY; IFS= read -r line; printf '\r\n%s\r\n' "$line"; exit 7]]))
local two=assert(open([[stty -echo; printf SECOND; IFS= read -r line]]))
await(function()return text(registry,one.id):find('READY',1,true) and text(registry,two.id):find('SECOND',1,true)end)
assert(not open('printf MUST_NOT_START'),'live records are never evicted for another launch')
local before=registry:get(one.id);before.pid=0;assert(registry:get(one.id).pid>0,'metadata is copied')
local result,why=registry:resize(one.id,1,40,4);assert(not result and why.status==503 and registry:get(one.id).cols==20,'resize budget is enforced before geometry changes')
result,why=registry:write(one.id,2,'wrong\n');assert(not result and why.status==409)
result,why=registry:write(one.id,nil,'wrong\n');assert(not result and why.status==400)
result,why=registry:write(one.id,1,string.rep('x',65537));assert(not result and why.status==400,'input requests are bounded before native queuing')
assert(not registry:screen(one.id,1,65) and not registry:list(0,65))
local original_pid=registry:get(one.id).pid
collectgarbage('collect');assert(registry:get(one.id).pid==original_pid,'registry retains native owner across collection')
assert(registry:write(one.id,1,'payload 🦊\n').accepted_bytes==#'payload 🦊\n')
await(function()return registry:get(one.id).state=='failed'end)
assert(registry:get(one.id).exit_status==7 and text(registry,one.id):find('payload 🦊',1,true))
assert(not registry:write(one.id,1,'late'),'exited processes reject input but retain their grid')
local three=assert(open([[printf THIRD; IFS= read -r line]]))
assert(three.id~=one.id and not registry:get(one.id) and registry:get(two.id),'only completed history is evicted')
assert(registry:close(two.id,1).state=='stopped');assert(registry:close(two.id,1).closed,'close is idempotent')
assert(not registry:screen(two.id),'closed grids cannot be read')
local old_pid=registry:get(three.id).pid;registry:shutdown();registry:shutdown()
assert(registry.used==0 and not registry:open{} and not registry:get(three.id))
await(function()return not uv.kill(old_pid,0)end)
registry=Registry.new{max_records=4,max_cells=4096}
local literal=assert(registry:open{cmd='/bin/sh',args={'-c','printf "%s|%s|" "$1" "$BMUX_FIXTURE_VALUE"; /bin/pwd','literal','$HOME $(unchanged) 🦊'},
  env={'BMUX_FIXTURE_VALUE=private-fixture'},cols=80,rows=4,history=0,cwd='/tmp'})
await(function()return registry:get(literal.id).state=='exited'end)
assert(text(registry,literal.id):find('$HOME $(unchanged) 🦊|private-fixture',1,true))
assert(text(registry,literal.id):find('|'..uv.fs_realpath('/tmp'),1,true),'child actually executes in the requested directory')
assert(not json.encode(registry:get(literal.id)):find('private-fixture',1,true),'environment is not exposed as metadata')
assert(registry:resize(literal.id,1,40,4).cols==40,'completed grids can be resized')
local failed=assert(registry:open{cmd='/not/a/real/executable',cols=10,rows=2,history=0})
assert(failed.state=='failed' and failed.error and registry:get(failed.id),'spawn failure remains inspectable')
registry:shutdown();uv.run('nowait')
print('terminal_registry: native ownership, literal input/env, capacity, copied metadata, stale identity, exit/output, resize and shutdown pass')
return 0
