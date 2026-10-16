-- Copy a complete bounded Fleet publication before changing presentation.
local json=require 'json';local M={};local MAX=9007199254740991
local function need(ok,why)if not ok then error(why,0)end end
local function int(n,min)return type(n)=='number'and n%1==0 and n>=(min or 1)and n<=MAX end
local function object(t)need(type(t)=='table'and getmetatable(t)==nil,'plain object required');return t end
local function text(s,n,empty)
  need(type(s)=='string'and #s<=n and (empty or #s>0)and not s:find('[%z\1-\31\127]')and utf8.len(s)~=nil,'invalid Fleet text');return s
end
local function identity(v)if type(v)=='number'then need(int(v),'invalid Fleet identity');return v end;return text(v,256)end
local function host(v)text(v,128);need(v:match('^[%w_-]+$'),'invalid host identity');return v end
local function array(t)
  if t==json.array then return {}end
  object(t);need(#t<=1024,'Fleet record limit exceeded');local count=0
  for k in pairs(t)do need(int(k)and k<=#t,'invalid Fleet array index');count=count+1 end
  need(count==#t,'sparse Fleet array');return t
end
local caps={'stop','prompt','interrupt','approve'}
local function record(r)
  object(r);need(int(r.generation),'invalid runtime generation')
  local out={id=identity(r.id),generation=r.generation,provider=text(r.provider,128),name=text(r.name,256),
    state=text(r.state,128),activity=text(r.activity,256,true),capabilities={}}
  for _,k in ipairs{'cwd','model','error'}do if r[k]~=nil then out[k]=text(r[k],k=='cwd'and 4096 or 1024,true)end end
  for _,k in ipairs{'pid','exit_status','term_signal','bytes','session_id','input_revision','draft_bytes','worker_incarnation'}do
    if r[k]~=nil then need(int(r[k],k=='exit_status'and -1 or 0),'invalid Fleet number');out[k]=r[k]end
  end
  if r.parent~=nil then out.parent=identity(r.parent);need(out.parent~=out.id,'self-parented Fleet record')end
  if r.terminal_id~=nil or r.terminal_generation~=nil then
    out.terminal_id=host(r.terminal_id);need(int(r.terminal_generation),'invalid terminal generation');out.terminal_generation=r.terminal_generation
  end
  object(r.capabilities)
  for _,k in ipairs(caps)do
    need(r.capabilities[k]==nil or type(r.capabilities[k])=='boolean','invalid Fleet capability')
    out.capabilities[k]=r.capabilities[k]==true
    need(not out.capabilities[k]or out.terminal_id,'capability has no execution reference')
  end
  if r.request~=nil then
    local v=object(r.request);need(v.kind=='approval','unsupported Fleet request')
    out.request={id=text(v.id,128),kind=v.kind,name=text(v.name,256,true),summary=text(v.summary,2048,true)}
  end
  if r.control_result~=nil then
    local v=object(r.control_result);need(type(v.accepted)=='boolean','invalid control result')
    out.control_result={id=text(v.id,128),accepted=v.accepted}
    if v.error~=nil then out.control_result.error=text(v.error,1024,true)end
  end
  need(not out.capabilities.prompt or out.input_revision~=nil,'prompt capability has no input revision')
  need(not out.capabilities.approve or out.request,'approval capability has no request')
  if out.state=='exited'or out.state=='failed'or out.state=='stopped'then
    for _,k in ipairs(caps)do need(not out.capabilities[k],'ended runtime advertises execution')end
  end
  return out
end
local function validate(input)
  object(input);need(input.v==1 and int(input.revision,0),'invalid Fleet version/revision')
  local out={v=1,host_id=host(input.host_id),revision=input.revision,agents={}};local ids={}
  for i,r in ipairs(array(input.agents))do
    local copy=record(r);need(not ids[copy.id],'duplicate Fleet identity');ids[copy.id]=copy;out.agents[i]=copy
  end
  for _,r in ipairs(out.agents)do
    local parent=r.parent;local seen={[r.id]=true};local depth=0
    while parent and ids[parent]do
      need(not seen[parent]and depth<32,'cyclic/deep Fleet parent chain');seen[parent]=true;depth=depth+1;parent=ids[parent].parent
    end
  end
  return out,ids
end
function M.validate(input)
  local ok,snapshot,ids=pcall(validate,input)
  if not ok then return nil,{kind='protocol',message='Invalid Fleet snapshot: '..tostring(snapshot)}end
  return snapshot,ids
end
return M
