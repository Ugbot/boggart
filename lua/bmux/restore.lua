-- Trusted local startup recipes. Imported documents must be demoted beforehand.
local uv=require 'uv';local Layout=require 'bmux.layout';local Server=require 'bmux.server'
local M={}
local function directory(path)local info=uv.fs_stat(path);return info and info.type=='directory'end
local function seed(entry,saved)
  if #saved.lines>0 then entry.term:feed(table.concat(saved.lines,'\r\n')..'\r\n')end
  entry.term:feed(entry.frozen and '[Saved output; process is inactive]\r\n'or '[Restored output; process restarted]\r\n')
end
function M.apply(control,doc)
  local terminals,agents,owned={},{},{};local registry,fleet=control.terminals,control.fleet
  if #registry.order>0 or next(fleet.sessions)then return nil,{kind='restore',message='Runtime restoration requires an empty server owner'}end
  for _,a in ipairs(doc.agents)do if a.terminal_id then owned[a.terminal_id]=a end end
  local saved={};for _,t in ipairs(doc.terminals)do saved[t.id]=t end
  local function preview(t,why,existing)
    local record,error=registry:preview(t,why,existing);assert(record,error and error.message)
    local entry=assert(registry:find(record.id,record.generation))
    seed(entry,t);return entry
  end
  local ok,result=pcall(function()
    for _,t in ipairs(doc.terminals)do if not owned[t.id]then
      local entry
      if t.launch=='shell'and directory(t.cwd)then
        local r,why=registry:open{cwd=t.cwd,cols=t.cols,rows=t.rows,history=t.history}
        assert(r,why and why.message);entry=registry:find(r.id,r.generation)
        if not entry.term then entry=preview(t,entry.error,entry)
        else seed(entry,t)end
      else entry=preview(t,t.launch=='shell'and 'Saved directory is unavailable'or nil)end
      terminals[t.id]=entry
    end end
    for _,a in ipairs(doc.agents)do
      local t=a.terminal_id and saved[a.terminal_id];local entry,rec
      if a.launch=='boggart'and t and directory(t.cwd)and bog.store.thread_load(a.resume_id)then
        local r,why=fleet:_launch{provider='boggart',name=a.name,resume_id=a.resume_id,cwd=t.cwd,cols=t.cols,rows=t.rows,history=t.history}
        if not r then entry=preview(t,why.message);rec=fleet:saved(a,entry,why.message)
        else
          local s=fleet.sessions[r.agent_id];entry,rec=s.entry,s.rec
          if not entry.term then
            entry=preview(t,entry.error,entry);s.restore_boggart=false
            fleet.registry:update(rec.id,rec.generation,{state='stopped',activity='saved agent; restart failed',error=entry.error})
          else seed(entry,t)end
        end
      else
        local why=a.launch=='boggart'and 'Saved session or directory is unavailable'or nil
        if t then entry=preview(t,why)end
        rec=fleet:saved(a,entry,why)
      end
      agents[a.id]=rec;if t then terminals[t.id]=entry end
    end
    local opts=Server.options(registry,control.server)
    opts.remap=function(v)
      if v.kind=='terminal'then local t=assert(terminals[v.terminal_id]);return {kind='terminal',terminal_id=t.id,generation=t.generation}end
      return {kind='agent',agent_id=assert(agents[v.agent_id]).id}
    end
    local host,why=Layout.restore(doc.layout,opts);assert(host,why and why.message)
    fleet:rebind(host.host_id);control.layout=host
    return {terminals=terminals,agents=agents}
  end)
  if ok then return result end
  -- Startup is not yet published. Retire every new owner if reconstruction fails.
  for _,id in ipairs(registry.order)do local entry=registry.entries[id];if not entry.closed then registry:release(entry)end end
  for _,s in pairs(fleet.sessions)do fleet.registry:retire(s.rec.id,s.rec.generation,'failed','Session restore failed')end
  return nil,{kind='restore',message=('Bmux runtime restore failed: '..tostring(result)):sub(1,512)}
end
return M
