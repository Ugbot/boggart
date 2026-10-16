if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local control=require 'control';local Codec=require 'bmux.checkpoint';local J=require 'bmux.journal'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-recovery-XXXXXX'));local socket=dir..'/sock'
local name='recovery-'..serve.token(8);local key='bmux.session.v1:'..name;local owner='bmux.owner.v1:'..name
local store=bog.store;local archives={};local archived_directory=assert(uv.fs_realpath(bog.userdir))..'/bmux-recovery'
local function bytes(path)local f=assert(io.open(path,'rb'));local raw=f:read('a');f:close();return raw end
local function preview(j)
  local p,e=j:recovery_preview();assert(p,e and e.message);archives[#archives+1]=p.archive.path;return p
end
local function recover(j,p,extra)
  local body={host_id=p.host_id,revision=p.revision,recovery_id=p.recovery_id}
  for k,v in pairs(extra or {})do body[k]=v end
  return j:recover(body)
end
local function await(fn)
  local deadline=uv.hrtime()+5e9
  repeat uv.run('nowait');if fn()then return end;uv.sleep(1)until uv.hrtime()>deadline
  error('recovery deadline')
end
local ok,why=xpcall(function()
  local original='\255\0{broken\27[31m\r\n'
  store.kv_set(key,original)
  bog.db:run('UPDATE kv SET value=CAST(value AS BLOB) WHERE key=?',{key})
  assert(control.start{socket=socket,session=name});local j=control.journal
  assert(j.blocked and j.claimed and #control.terminals.order==0)
  local p=preview(j);assert(p.archive.bytes==#original and p.archive.present and not uv.fs_lstat(p.archive.path))
  local value,e=recover(j,p,{commands={'touch marker'}});assert(not value and e.status==400 and store.kv_get(key)==original)
  value,e=recover(j,p,{recovery_id='stale'});assert(not value and e.status==409)
  assert(not uv.fs_lstat(p.archive.path),'preview/invalid commands never write an archive')
  local result=assert(recover(j,p));assert(result.recovered and not j.blocked and bytes(p.archive.path)==original)
  assert(uv.fs_stat(p.archive.path).mode&63==0)
  local metadata=require('json').decode(bytes(p.archive.path..'.json'))
  assert(metadata.present and metadata.original_bytes==#original and metadata.name==name)
  assert(Codec.decode(store.kv_get(key))and not recover(j,p),'a recovery preview is consumed once')
  -- A corrupt-startup journal had no subscriptions. Recovery must install them
  -- so later layout and real PTY output are saved without another explicit action.
  local host=control.layout
  assert(host:command{host_id=host.host_id,revision=host.revision,op='workspace_create',title='After recovery 🦊'})
  local r=assert(control.terminals:open{cmd='/bin/sh',args={'-c','printf RECOVERED_OUTPUT; IFS= read -r line'},cwd=dir,cols=40,rows=4,history=8})
  await(function()local doc=Codec.decode(store.kv_get(key));return doc and #doc.layout.workspaces==1
    and #doc.terminals==1 and table.concat(doc.terminals[1].lines):find('RECOVERED_OUTPUT',1,true)end)
  assert(uv.kill(r.pid,0));control.stop();assert(not store.kv_get(owner))
  assert(control.start{socket=socket,session=name});assert(control.journal.restored and not control.journal.blocked)
  local entry=control.terminals.entries[control.terminals.order[1]];assert(entry.frozen and not entry.pid)
  assert(bytes(p.archive.path)==original,'later saves/restarts never alter the original archive');control.stop()

  -- Exact layout/data/owner guards are independently enforced.
  store.kv_set(key,'{first');assert(control.start{socket=socket,session=name});j=control.journal;p=preview(j)
  host=control.layout;assert(host:command{host_id=host.host_id,revision=host.revision,op='workspace_create',title='Changed'})
  value,e=recover(j,p);assert(not value and e.status==409 and not uv.fs_lstat(p.archive.path))
  p=preview(j);store.kv_set(key,'{newer')
  value,e=recover(j,p);assert(not value and e.status==409 and store.kv_get(key)=='{newer'and bytes(p.archive.path)=='{first')
  p=preview(j);store.kv_set(owner,'different owner')
  value,e=recover(j,p);assert(not value and e.status==409 and store.kv_get(owner)=='different owner')
  control.stop();assert(store.kv_get(owner)=='different owner');store.kv_del(owner)
  store.kv_set(owner,'invalid owner');assert(control.start{socket=socket,session=name})
  value,e=control.journal:recovery_preview();assert(not value and e.status==409 and store.kv_get(owner)=='invalid owner')
  control.stop();store.kv_del(owner)

  -- An already claimed live name cannot be forced by another journal.
  store.kv_set(key,'{live');assert(control.start{socket=socket,session=name})
  local rival=J.new(control,name);assert(rival.blocked and not rival.claimed)
  value,e=rival:recovery_preview();assert(not value and e.status==409);rival:close();control.stop()

  -- CAS sees ownership loss between preview and its native commit, not merely
  -- before capture. Failure preserves both source bytes and the new owner's row.
  assert(control.start{socket=socket});local fault={is_open=store.is_open,kv_get=store.kv_get}
  fault.kv_compare_set=function(k,expected,replacement,guard,lease)
    if k==key and replacement then store.kv_set(owner,'raced owner')end
    return store.kv_compare_set(k,expected,replacement,guard,lease)
  end
  local broken=J.new(control,name,fault);assert(broken.blocked and broken.claimed);p=preview(broken)
  value,e=recover(broken,p);assert(not value and e.status==409 and store.kv_get(key)=='{live')
  assert(store.kv_get(owner)=='raced owner'and bytes(p.archive.path)=='{live');broken:close();store.kv_del(owner)
  control.stop()

  -- Archive write failure must occur before any SQLite replacement.
  store.kv_set(key,'{archive failure');assert(control.start{socket=socket,session=name});j=control.journal;p=preview(j)
  local f=assert(io.open(p.archive.path,'w'));f:write('existing archive');f:close()
  value,e=recover(j,p);assert(not value and e.status==503 and store.kv_get(key)=='{archive failure'and bytes(p.archive.path)=='existing archive')
  assert(j.blocked);control.stop()
  -- Empty data is distinct from an absent key in both preview and sidecar.
  store.kv_set(key,'');assert(control.start{socket=socket,session=name});j=control.journal;p=preview(j)
  assert(p.archive.present and p.archive.bytes==0);assert(recover(j,p));assert(bytes(p.archive.path)=='')
  assert(require('json').decode(bytes(p.archive.path..'.json')).present);control.stop();store.kv_del(key)
  assert(control.start{socket=socket})
  local unavailable=true;local failing={is_open=store.is_open,kv_get=store.kv_get,kv_compare_set=function(k,...)
    if k==key and unavailable then return nil,'fixture disk full'end;return store.kv_compare_set(k,...)
  end}
  local pending=J.new(control,name,failing);assert(not pending:flush()and pending.blocked);p=preview(pending)
  assert(not p.archive.present and p.archive.bytes==0)
  value,e=recover(pending,p);assert(not value and e.status==503 and not store.kv_get(key)and bytes(p.archive.path)=='')
  assert(not require('json').decode(bytes(p.archive.path..'.json')).present)
  unavailable=false;p=preview(pending);assert(recover(pending,p));pending:close();control.stop()
  -- Explicit inspection detects idle external corruption without requiring
  -- the user to manufacture terminal output just to trigger another save.
  assert(control.start{socket=socket,session=name});j=control.journal;assert(not j.blocked)
  value,e=j:recovery_preview();assert(not value and e.status==409)
  store.kv_set(key,'{idle corruption');p=preview(j)
  assert(j.blocked and assert(recover(j,p)).recovered and bytes(p.archive.path)=='{idle corruption');control.stop()
  assert(control.start{socket=socket})
  for i=1,8 do control.terminals:watch('fixture-'..i,function()end)end
  local made,blocked=pcall(J.new,control,name)
  assert(made and blocked.blocked and blocked.claimed,'subscription failure is returned as an observable blocked journal')
  blocked:close();assert(not store.kv_get(owner),'subscription failure does not leak the owner lease')
  control.stop()
end,debug.traceback)
control.stop();store.kv_del(key);store.kv_del(owner);uv.run('nowait')
for _,path in ipairs(archives)do uv.fs_unlink(path);uv.fs_unlink(path..'.json')end
uv.fs_rmdir(archived_directory);uv.fs_rmdir(dir);assert(ok,why)
print('Recovery: exact binary archives, owner/data/layout guards, one-shot previews, resumed journal observers and subsequent restart pass')
return 0
