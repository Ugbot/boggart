-- Data-only durable image. Validation never grants process execution authority.
local json=require 'json';local Snapshot=require 'bmux.snapshot'
local Decode=require('terminal.replica').decode
local M={};local MAX=9007199254740991;local MAX_BYTES=4*1024*1024
local function need(ok,message)if not ok then error(message,0)end end
local function integer(n,low,high)return type(n)=='number'and n%1==0 and n>=low and n<=(high or MAX)end
local function object(t,keys)
  need(type(t)=='table'and getmetatable(t)==nil,'plain record required')
  for key in pairs(t)do need(keys[key],'unknown checkpoint field')end
  return t
end
local function array(t,limit)
  if t==json.array then return {}end
  need(type(t)=='table'and getmetatable(t)==nil,'plain array required')
  local n=#t;need(n<=limit,'checkpoint collection limit exceeded');local count=0
  for key in pairs(t)do need(integer(key,1,n),'invalid array index');count=count+1 end
  need(count==n,'sparse checkpoint array');return t
end
local function plain(s,limit,empty)
  return type(s)=='string'and #s<=limit and (empty or #s>0)and utf8.len(s)~=nil
    and not s:find('[%z\1-\31\127]')and not s:find('\194[\128-\159]')
end
local function identifier(s)return type(s)=='string'and #s<=128 and s:match('^[%w_-]+$')end
local function agent_id(id)return plain(id,256)or integer(id,1)end
local function absolute(s)
  return plain(s,4096)and(s:sub(1,1)=='/'or s:match('^%a:[/\\]')or s:sub(1,2)=='\\\\')
end
local function unique(set,id)need(not set[id],'duplicate checkpoint identity');set[id]=true end
local terminal_keys={id=true,generation=true,cwd=true,cols=true,rows=true,history=true,launch=true,program=true,lines=true}
local agent_keys={id=true,generation=true,provider=true,name=true,terminal_id=true,terminal_generation=true,launch=true,resume_id=true}
local function validate(input)
  object(input,{v=true,layout=true,terminals=true,agents=true});need(input.v==1,'unsupported checkpoint version')
  local layout,why=Snapshot.validate(input.layout);need(layout,why and why.message)
  local out={v=1,layout=layout,terminals={},agents={}}
  local terminals,agents,owned={},{},{};local text_bytes=0
  for i,t in ipairs(array(input.terminals,4096))do
    object(t,terminal_keys)
    need(identifier(t.id)and integer(t.generation,1),'invalid saved terminal identity');unique(terminals,t.id)
    need(absolute(t.cwd),'absolute UTF-8 working directory required')
    need(integer(t.cols,1,4096)and integer(t.rows,1,4096)and integer(t.history,0,100000),'invalid saved terminal geometry')
    need(t.launch=='shell'or t.launch=='saved','invalid terminal restart recipe')
    need(t.program==nil or plain(t.program,4096),'invalid informational program')
    local copy={id=t.id,generation=t.generation,cwd=t.cwd,cols=t.cols,rows=t.rows,history=t.history,
      launch=t.launch,program=t.program,lines={}}
    local bytes=0
    for j,line in ipairs(array(t.lines,256))do
      need(plain(line,32768,true),'invalid plain history line');bytes=bytes+#line
      need(bytes<=65536,'saved terminal text limit exceeded');copy.lines[j]=line
    end
    text_bytes=text_bytes+bytes;need(text_bytes<=2*1024*1024,'checkpoint history budget exceeded')
    terminals[t.id]=copy;out.terminals[i]=copy
  end
  for i,a in ipairs(array(input.agents,1024))do
    object(a,agent_keys)
    need(agent_id(a.id)and integer(a.generation,1),'invalid saved agent identity');unique(agents,a.id)
    need(plain(a.provider,128)and plain(a.name,256),'invalid saved agent label')
    need(a.launch=='boggart'or a.launch=='saved','invalid agent restart recipe')
    need(a.resume_id==nil or integer(a.resume_id,1),'invalid saved agent resume identity')
    local copy={id=a.id,generation=a.generation,provider=a.provider,name=a.name,launch=a.launch,resume_id=a.resume_id}
    if a.terminal_id~=nil then
      local t=terminals[a.terminal_id]
      need(t and a.terminal_generation==t.generation,'dangling saved agent terminal')
      need(not owned[a.terminal_id]and t.launch=='saved','duplicate saved execution owner')
      owned[a.terminal_id]=true;copy.terminal_id=a.terminal_id;copy.terminal_generation=a.terminal_generation
    else need(a.terminal_generation==nil,'incomplete saved agent terminal')end
    need(a.launch~='boggart'or a.provider=='boggart'and a.resume_id~=nil and a.terminal_id~=nil,'invalid Boggart resume recipe')
    agents[a.id]=copy;out.agents[i]=copy
  end
  local function references(node)
    if node.type=='leaf'then for _,view in ipairs(node.views)do
      if view.kind=='terminal'then
        local t=terminals[view.terminal_id];need(t and t.generation==view.generation,'dangling saved layout terminal')
      else need(agents[view.agent_id],'dangling saved layout agent')end
    end else references(node.a);references(node.b)end
  end
  for _,w in ipairs(layout.workspaces)do for _,s in ipairs(w.surfaces)do references(s.tree)end end
  return out
end
local function problem(why)return {kind='checkpoint',message=('Invalid Bmux checkpoint: '..tostring(why)):sub(1,512)}end
function M.validate(input)
  local ok,value=pcall(validate,input)
  if ok then return value end
  return nil,problem(value)
end
function M.decode(raw)
  local value,why=Decode(raw);if not value then return nil,problem(why.message)end
  return M.validate(value)
end
-- A decoded document is data, never permission to run its restart recipes.
-- Keep this boundary shared by every import consumer, including local files.
function M.import(raw)
  local value,why=M.decode(raw);if not value then return nil,why end
  for _,t in ipairs(value.terminals)do t.launch='saved'end
  for _,a in ipairs(value.agents)do a.launch='saved'end
  return value
end
local function as_array(t)return #t==0 and json.array or t end
function M.encode(input)
  local value,why=M.validate(input);if not value then return nil,why end
  local function nodes(node)
    if node.type=='leaf'then node.views=as_array(node.views)else nodes(node.a);nodes(node.b)end
  end
  for _,w in ipairs(value.layout.workspaces)do for _,s in ipairs(w.surfaces)do nodes(s.tree)end end
  value.layout.workspaces=as_array(value.layout.workspaces)
  for _,t in ipairs(value.terminals)do t.lines=as_array(t.lines)end
  value.terminals,value.agents=as_array(value.terminals),as_array(value.agents)
  local ok,encoded=pcall(json.encode,value)
  if not ok then return nil,problem('checkpoint encoding failed')end
  if #encoded>MAX_BYTES then return nil,problem('encoded checkpoint size limit exceeded')end
  return encoded
end
return M
