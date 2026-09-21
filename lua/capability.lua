-- Versioned host capabilities. Generated Lua receives injected call functions,
-- never this privileged registration module.
local M = {}
local entries = {}
local function copy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}; assert(not seen[v], "cyclic descriptor/data")
  seen[v] = true; local out = {}
  for k, x in pairs(v) do out[k] = copy(x, seen) end
  seen[v] = nil; return out
end
local function equal(a,b)
  if type(a)~=type(b) then return false end
  if type(a)~="table" then return a==b end
  for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
local function finite(n) return type(n)=="number" and n>=0 and n<=9007199254740991 end
local types={object=true,array=true,string=true,number=true,integer=true,boolean=true,["null"]=true}
local keywords={type=true,properties=true,required=true,additionalProperties=true,items=true,
  enum=true,minimum=true,maximum=true,minLength=true,maxLength=true,minItems=true,maxItems=true,
  description=true,title=true,default=true}
local function list(v)
  assert(type(v)=="table", "expected schema list")
  local n=0; for k in pairs(v) do assert(type(k)=="number" and k%1==0 and k>0,"invalid schema list"); n=n+1 end
  for i=1,n do assert(v[i]~=nil,"sparse schema list") end
  return n
end
local function schema(s)
  assert(type(s)=="table", "schema must be a table")
  for k in pairs(s) do assert(keywords[k], "unsupported schema keyword: "..tostring(k)) end
  assert(s.type==nil or types[s.type],"unsupported schema type")
  if s.properties then
    assert(s.type=="object" and type(s.properties)=="table","properties requires object")
    for k,v in pairs(s.properties) do assert(type(k)=="string","invalid property"); schema(v) end
  end
  if s.required then assert(s.type=="object","required requires object"); local n=list(s.required); for i=1,n do assert(type(s.required[i])=="string","invalid required property") end end
  if s.additionalProperties~=nil then assert(s.type=="object","additionalProperties requires object"); assert(type(s.additionalProperties)=="boolean","additionalProperties must be boolean") end
  if s.items then assert(s.type=="array","items requires array"); schema(s.items) end
  if s.enum then assert(list(s.enum)>0,"empty enum") end
  for _,k in ipairs({"minimum","maximum","minLength","maxLength","minItems","maxItems"}) do
    if s[k]~=nil then
      if k=="minimum" or k=="maximum" then assert(s.type=="number" or s.type=="integer",k.." requires numeric type")
      elseif k=="minLength" or k=="maxLength" then assert(s.type=="string",k.." requires string")
      else assert(s.type=="array",k.." requires array") end
      assert(type(s[k])=="number" and s[k]==s[k] and math.abs(s[k])<math.huge,"invalid "..k)
      if k~="minimum" and k~="maximum" then assert(s[k]>=0 and s[k]%1==0,"invalid "..k) end
    end
  end
end
local function validate(s,v,path)
  path=path or "$"; local t=s.type
  if t=="object" or t=="array" then
    if type(v)~="table" then return nil,path.." must be "..t end
  elseif t=="integer" then
    if type(v)~="number" or v%1~=0 then return nil,path.." must be integer" end
  elseif t=="null" then if v~=nil then return nil,path.." must be null" end
  elseif t and type(v)~=t then return nil,path.." must be "..t end
  if type(v)=="number" and (v~=v or math.abs(v)==math.huge) then return nil,path.." must be finite" end
  if s.enum then local found=false; for _,x in ipairs(s.enum) do if equal(v,x) then found=true end end
    if not found then return nil,path.." is not in enum" end end
  if t=="object" then
    for k in pairs(v) do if type(k)~="string" then return nil,path.." requires string keys" end end
    for _,k in ipairs(s.required or {}) do if v[k]==nil then return nil,path.." missing "..k end end
    for k,x in pairs(v) do
      local child=(s.properties or {})[k]
      if child then local ok,err=validate(child,x,path.."."..k); if not ok then return nil,err end
      elseif s.additionalProperties==false then return nil,path.." unexpected property "..k end
    end
  elseif t=="array" then
    local n=0; for k in pairs(v) do if type(k)~="number" or k%1~=0 or k<1 then return nil,path.." invalid array key" end; n=n+1 end
    for i=1,n do if v[i]==nil then return nil,path.." sparse array" end end
    if s.minItems and n<s.minItems or s.maxItems and n>s.maxItems then return nil,path.." array length" end
    if s.items then for i=1,n do local ok,err=validate(s.items,v[i],path.."["..i.."]"); if not ok then return nil,err end end end
  elseif t=="string" then
    if s.minLength and #v<s.minLength or s.maxLength and #v>s.maxLength then return nil,path.." string byte length" end
  end
  if type(v)=="number" and (s.minimum and v<s.minimum or s.maximum and v>s.maximum) then return nil,path.." numeric bound" end
  return true
end
local function validator(d,side)
  local fn=d[side.."_validator"]
  if fn then assert(type(fn)=="function","validator must be callable"); return fn end
  local s=d[side.."_schema"] or {}; schema(s)
  return function(value) return validate(s,value) end
end
function M.register(descriptor, runner)
  local ok, d = pcall(function()
    local d=copy(descriptor)
    assert(type(d.id)=="string" and d.id~="","capability id required")
    assert(type(d.version)=="string" and d.version~="","capability version required")
    assert(type(runner)=="function","runner required")
    d.effect=d.effect or "unknown"
    assert(({pure=true,read=true,write=true,unknown=true})[d.effect],"invalid effect class")
    d.target=d.target or "local"
    assert(type(d.target)=="string" and d.target~="","target required")
    for _,k in ipairs({"resources","estimate","cancel","reconcile","reconcile_estimate"}) do assert(d[k]==nil or type(d[k])=="function",k.." must be callable") end
    assert(d.requires_approval==nil or type(d.requires_approval)=="boolean","requires_approval must be boolean")
    d.validate_input=validator(d,"input"); d.validate_output=validator(d,"output")
    if d.reconcile_bounded then
      assert(type(d.reconcile_bounded)=="table" and type(d.reconcile_estimate)=="function" and type(d.reconcile)=="function","bounded reconciliation requires hook and estimator")
      for metric,enabled in pairs(d.reconcile_bounded) do assert(type(metric)=="string" and metric~="" and enabled==true,"invalid reconciliation bounded metric") end
    end
    if d.bounded then
      assert(type(d.bounded)=="table" and type(d.estimate)=="function","bounded adapters require estimator")
      for metric,enabled in pairs(d.bounded) do assert(type(metric)=="string" and metric~="" and enabled==true,"invalid bounded metric") end
    end
    assert(not (entries[d.id] and entries[d.id][d.version]),"capability version already registered")
    return d
  end)
  if not ok then return nil,tostring(d) end
  entries[d.id]=entries[d.id] or {}; entries[d.id][d.version]={descriptor=d,runner=runner}
  return copy(d)
end
function M.resolve(id,version)
  if type(version)~="string" then return nil,"exact capability version required" end
  local e=entries[id] and entries[id][version]
  if not e then return nil,"capability/version unavailable: "..tostring(id).."@"..version end
  return copy(e.descriptor)
end
-- Existing names stay intact, and invocation still passes through that registry's
-- gate (including its generation and current permission/resource checks).
function M.adapt(id,version,registry,metadata)
  registry=registry or require("tools")
  local def=registry.registry[id]
  if not def then return nil,"legacy tool unavailable" end
  local resolve,run=require("invoke").adapter(registry,id)
  local source=resolve()
  if not source then return nil,"legacy descriptor unavailable" end
  local d=copy(metadata or {}); d.id=id; d.version=version
  d.input_schema=d.input_schema or def.input_schema; d.output_schema=d.output_schema or def.output_schema
  d.effect=d.effect or source.effect or "unknown"; d.target=d.target or "legacy"
  d.resources=source.resources; d.legacy_name=source.legacy_name or id; d.legacy_args=source.legacy_args
  -- A generic legacy adapter cannot promise provider ceilings.
  if d.bounded then return nil,"legacy runner cannot enforce bounded usage" end
  local registered,err=M.register(d,run)
  if not registered then return nil,err end
  entries[id][version].source=function()
    local current=resolve()
    if not current then return nil end
    for _,field in ipairs({"id","version","effect","_entry","_runner","_body","_resources"}) do
      if current[field]~=source[field] then return nil end
    end
    return true
  end
  return registered
end
local function dispatch(context,id,version,args,options)
  options=options or {}
  local d,err=M.resolve(id,version)
  if not d then return {status="failed",error={code="version_unavailable",message=err,retryable=false},usage={},receipt={dispatched=false,id=id,version=version}} end
  local e=entries[id][version]
  local owner={}
  local function runner(_,input,execution)
      if options.guard then options.guard(execution) end
      local result,meta=(options.runner or e.runner)(input,execution)
      meta=meta or {status="succeeded"}
      assert(type(meta)=="table","execution metadata must be separate table")
      meta=copy(meta); meta.status=meta.status or "succeeded"
      assert(({succeeded=true,failed=true,cancelled=true,uncertain=true})[meta.status],"invalid execution status")
      if meta.usage then for metric,value in pairs(meta.usage) do assert(type(metric)=="string" and finite(value),"invalid actual usage") end end
      return result,meta
    end
  require("invoke").bind(owner,function(name) if name==id and (not e.source or e.source()) then return e.descriptor end end,runner,nil,true)
  local result,call_error,receipt=require("invoke").call(context,id,args,{registry=owner,operation_id=options.operation_id,reuse=options.reuse,reconcile=options.reconcile,runner=options.runner and runner or nil})
  return {status=receipt.status,result=result,error=call_error,usage=receipt.usage or {},
    artifacts=receipt.artifacts,receipt=receipt}
end
function M.call(context,id,version,args,options)
  return dispatch(context,id,version,args,{operation_id=options and options.operation_id,guard=options and options.guard})
end
-- These are trusted host helpers; source Lua cannot select runners or receipts.
function M.reconcile(context,id,version,args,operation_id,guard)
  local d=M.resolve(id,version)
  if not d or not d.reconcile then return {status='uncertain',error={code='reconciliation_unavailable'}} end
  return dispatch(context,id,version,args,{operation_id=operation_id,runner=d.reconcile,guard=guard,reconcile=true})
end
function M.reuse(context,id,version,args,outcome,kind)
  local result=dispatch(context,id,version,args,{reuse=true,runner=function(_,execution)
    local usage={}
    for metric in pairs(execution.ceilings) do usage[metric]=0 end
    return copy(outcome.result),{status='succeeded',usage=usage,artifacts=copy(outcome.artifacts),receipt={reuse=kind,
      original_invocation_id=outcome.receipt and outcome.receipt.invocation_id,
      historical_usage=copy(outcome.usage or {})}}
  end})
  return result
end
return M
