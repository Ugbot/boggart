-- Strict network shapes. Execution and capability checks stay with the owner.
local json=require 'json';local M={};local MAX=9007199254740991
function M.integer(n,min)return type(n)=='number' and n%1==0 and n>=(min or 1)and n<=MAX end
local function text(s,n,empty)return type(s)=='string'and #s<=(n or 256)and (empty or #s>0)and not s:find('%z')and utf8.len(s)~=nil end
local function label(s,n)return text(s,n)and not s:find('[\1-\31\127]')end
local function object(t)return type(t)=='table'and getmetatable(t)==nil end
local function only(t,keys)for k in pairs(t)do if not keys[k]then return false end end;return true end
local envelope={host_id=true,client_id=true,command_seq=true}
local launch={provider=true,name=true,cmd=true,args=true,cwd=true,cols=true,rows=true,history=true,resume_id=true}
local actions={prompt={text=true,input_revision=true},interrupt={},approve={request_id=true,decision=true},stop={}}
for k in pairs(envelope)do launch[k]=true end
function M.validate(route,b)
  if not object(b)or not label(b.host_id,128)or not label(b.client_id,64)or not b.client_id:match('^[%w_-]+$')or not M.integer(b.command_seq)then return nil,'invalid Fleet command envelope'end
  if route=='launch'then
    if not only(b,launch)or not label(b.provider,128)or b.name~=nil and not label(b.name,256)
      or b.cmd~=nil and not text(b.cmd,4096)or b.cwd~=nil and not text(b.cwd,4096)
      or b.resume_id~=nil and not (M.integer(b.resume_id)or label(b.resume_id,128))then return nil,'invalid agent launch options'end
    if b.resume_id~=nil and (b.provider~='boggart'or b.args~=nil)then return nil,'resume requires a Boggart default profile'end
    for _,k in ipairs{'cols','rows','history'}do
      if b[k]~=nil and not (M.integer(b[k],k=='history'and 0 or 1)and b[k]<=(k=='history'and 100000 or 4096))then return nil,'invalid agent geometry'end
    end
    if b.args~=nil and b.args~=json.array then
      if not object(b.args)or #b.args>128 then return nil,'invalid literal agent arguments'end
      local count,bytes=0,0
      for k,v in pairs(b.args)do
        if not M.integer(k)or k>#b.args or not text(v,16384,true)then return nil,'invalid literal agent argument'end
        count=count+1;bytes=bytes+#v
      end
      if count~=#b.args or bytes>65536 then return nil,'agent argument limit exceeded'end
    end
    if b.provider~='boggart'and b.cmd==nil then return nil,'foreign agent executable required'end
  else
    local schema=actions[b.action];if not schema or not label(b.agent_id,256)or not M.integer(b.generation)then return nil,'invalid agent action'end
    local allowed={agent_id=true,generation=true,action=true};for k in pairs(envelope)do allowed[k]=true end;for k in pairs(schema)do allowed[k]=true end
    if not only(b,allowed)then return nil,'unknown agent command field'end
    if b.action=='prompt'and (not text(b.text,16384,true)or not M.integer(b.input_revision,0))then return nil,'prompt text and observed input revision required'end
    if b.action=='approve'and (not label(b.request_id,128)or b.decision~='approve'and b.decision~='reject')then return nil,'exact approval request and decision required'end
  end
  return true
end
return M
