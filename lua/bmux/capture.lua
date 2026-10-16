-- Native text and trusted owner metadata -> one validated checkpoint document.
local uv=require 'uv';local C=require 'bmux.checkpoint';local M={}
local ended={exited=true,failed=true,stopped=true}
local function clean(s,n)
  if type(s)~='string'or not utf8.len(s)then return '?'end
  s=s:gsub('[%z\1-\31\127]',' '):gsub('\194[\128-\159]',' ')
  if #s>n then s=s:sub(1,(utf8.offset(s,0,n+1)or n+1)-1)end;return s
end
function M.metadata(entry)
  if not entry.term or entry.frozen then return end
  local events=entry.term:events()
  for _,event in ipairs(events)do if event.type=='cwd'then
    local host,path=event.text:match('^file://([^/]*)(/.*)$')
    if path and(host==''or host=='localhost'or host==uv.os_gethostname())then
      path=path:gsub('%%(%x%x)',function(hex)return string.char(tonumber(hex,16))end)
      local info=clean(path,4096)==path and uv.fs_stat(path)
      if info and info.type=='directory'then entry.cwd=path end
    end
  end end
end
function M.collect(control,cache)
  local doc={v=1,layout=control.layout:snapshot(),terminals={},agents={}}
  local terminals,agents={},{ };local bytes=0;local registry=control.terminals
  local function terminal(id,generation,entry)
    if terminals[id]then return terminals[id]end
    local t={id=id,generation=generation,cwd=uv.cwd(),cols=80,rows=24,history=0,launch='saved',lines={}}
    if entry then
      M.metadata(entry);local p=registry:status(entry)
      if entry.restore_shell and entry.term and not entry.frozen then
        local current=entry.term:working_directory()
        if current and clean(current,4096)==current and uv.fs_realpath(entry.cwd)~=current then entry.cwd=current end
      end
      t.cwd=entry.cwd;t.cols,t.rows,t.history=entry.cols,entry.rows,entry.history;t.program=clean(entry.cmd,4096)
      if entry.restore_shell and not entry.closed and not p.process_exited and not ended[p.state]then t.launch='shell'end
      local lines=cache[id]or {};local available=2*1024*1024-bytes
      if entry.term then lines=entry.term:plain_tail(256,math.min(65536,available))end
      -- Retain newest whole lines when the global budget is shared by many panes.
      local from=#lines+1;local size=0
      for i=#lines,1,-1 do if size+#lines[i]>available then break end;size=size+#lines[i];from=i end
      for i=from,#lines do t.lines[#t.lines+1]=lines[i]end;bytes=bytes+size;cache[id]=t.lines
    end
    terminals[id]=t;doc.terminals[#doc.terminals+1]=t;return t
  end
  local function agent(id,rec,s)
    if agents[id]then return agents[id]end
    local a={id=id,generation=rec and rec.generation or 1,provider=clean(rec and rec.provider or 'unknown',128),
      name=clean(rec and(rec.name or rec.kind)or 'Saved agent',256),launch='saved'}
    if rec and type(rec.session_id)=='number'and rec.session_id>0 then a.resume_id=rec.session_id end
    if s and s.entry then
      local entry=s.entry;local t=terminal(entry.id,entry.generation,entry);t.launch='saved'
      a.terminal_id,a.terminal_generation=entry.id,entry.generation
      if s.restore_boggart and a.resume_id and not entry.closed and not entry.frozen and not ended[rec.state]then a.launch='boggart'end
    end
    agents[id]=a;doc.agents[#doc.agents+1]=a;return a
  end
  for _,id in ipairs(registry.order)do local e=registry.entries[id];terminal(id,e.generation,e)end
  for _,id in ipairs(control.fleet.registry.order)do local s=control.fleet.sessions[id];if s then agent(id,s.rec,s)end end
  local function refs(node)
    if node.type=='leaf'then for _,v in ipairs(node.views)do
      if v.kind=='terminal'then terminal(v.terminal_id,v.generation,registry.entries[v.terminal_id])
      else agent(v.agent_id,control.fleet.registry:get(v.agent_id),control.fleet.sessions[v.agent_id])end
    end else refs(node.a);refs(node.b)end
  end
  for _,w in ipairs(doc.layout.workspaces)do for _,s in ipairs(w.surfaces)do refs(s.tree)end end
  for id in pairs(cache)do if not terminals[id]then cache[id]=nil end end
  return C.validate(doc)
end
return M
