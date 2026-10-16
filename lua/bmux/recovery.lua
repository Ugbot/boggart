-- Explicit recovery writes only the current owned state. Original bytes are data.
local Files=require 'bmux.sessionfiles';local Capture=require 'bmux.capture';local Codec=require 'bmux.checkpoint'
local M={}
local function failure(status,message)return nil,{status=status,message=tostring(message):sub(1,512)}end
local function call(j,method,...)
  local ok,value,why=pcall(j.store[method],...)
  if not ok then return failure(503,value)end
  if value==nil and why then return failure(503,why)end
  return value
end
local function admitted(j,inspect)
  if j.closed or j.recovering or not inspect and not j.blocked then return failure(409,'Recovery requires a blocked, idle session')end
  if not j.claimed then return failure(409,'This server does not own the saved session; choose another session name')end
  local owner,why=call(j,'kv_get',j.owner_key);if why then return nil,why end
  if owner~=j.owner then return failure(409,'Saved session ownership changed; recovery cannot take it over')end
  return true
end
function M.prepare(j)
  local ok,why=admitted(j,true);if not ok then return nil,why end
  local raw;raw,why=call(j,'kv_get',j.key);if why then return nil,why end
  if not j.blocked then
    if raw==j.last then return failure(409,'Saved session is healthy; recovery is unnecessary')end
    j:_fail('Saved checkpoint changed; explicit recovery requested')
  end
  if raw and #raw>64*1024*1024 then return failure(413,'Original checkpoint exceeds the 64 MiB recovery archive limit')end
  local id=serve.token(16);local path;path,why=Files.recovery_location(bog.userdir,id)
  if not path then return failure(503,why.message)end
  local host=j.control.layout
  local preview={host_id=host.host_id,revision=host.revision,name=j.name,recovery_id=id,
    archive={id=id,path=path,bytes=raw and #raw or 0,present=raw~=nil},
    workspaces=#host.workspaces,terminals=#j.control.terminals.order,agents=0}
  for _ in pairs(j.control.fleet.sessions)do preview.agents=preview.agents+1 end
  j.recovery_plan={raw=raw,owner=j.owner,preview=preview}
  -- Public records are copied; no caller can edit the privately pinned plan.
  return require('json').decode(require('json').encode(preview))
end
local function commit(j,body,plan)
  local p=plan.preview;local host=j.control.layout
  local ok,why=admitted(j);if not ok then return nil,why end
  j.recovering=true
  j:_subscribe()
  local doc;doc,why=Capture.collect(j.control,j.cache);if not doc then return failure(503,why.message)end
  local text;text,why=Codec.encode(doc);if not text then return failure(503,why.message)end
  ok,why=Files.archive(p.archive.path,plan.raw or '',{v=1,name=j.name,host_id=p.host_id,revision=p.revision,
    original_bytes=p.archive.bytes,present=p.archive.present,created_at=os.time()})
  if not ok then return failure(503,why.message)end
  if j.control.layout~=host or host.host_id~=p.host_id or host.revision~=p.revision then
    return failure(409,'Layout changed during recovery; original bytes remain archived')
  end
  local written;written,why=call(j,'kv_compare_set',j.key,plan.raw,text,j.owner_key,plan.owner)
  if why then return nil,why end
  if not written then return failure(409,'Checkpoint or owner changed; no saved data was replaced')end
  j.last=text;j.writes=j.writes+1;j.blocked=false;j.error=nil;j.storage_error=nil
  j.last_recovery={id=p.archive.id,path=p.archive.path,bytes=p.archive.bytes,present=p.archive.present}
  j:changed()
  return {recovered=true,host_id=host.host_id,revision=host.revision,archive=j.last_recovery,status=j:status()}
end
function M.commit(j,body)
  if type(body)~='table'or getmetatable(body)then return failure(400,'Recovery command object required')end
  for k in pairs(body)do if k~='host_id'and k~='revision'and k~='recovery_id'then return failure(400,'Unknown recovery command field')end end
  local plan=j.recovery_plan;local p=plan and plan.preview;local host=j.control.layout
  if not host or not p or body.host_id~=p.host_id or body.revision~=p.revision or body.recovery_id~=p.recovery_id
    or host.host_id~=p.host_id or host.revision~=p.revision then return failure(409,'Recovery preview changed; inspect it again explicitly')end
  if j.recovering then return failure(409,'Recovery is already running')end
  j.recovery_plan=nil -- A preview is consumed once, including failed attempts.
  local ok,value,why=pcall(commit,j,body,plan);j.recovering=false
  if not ok then return failure(503,value)end
  return value,why
end
return M
