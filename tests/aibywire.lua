local adapter=require('adapters.aibywire')
local json,invoke,cap=require('json'),require('invoke'),require('capability')
local db=assert(require('db').open(os.tmpname()))
assert(require('evidence').configure{db=db})
local passed=0
local function check(v,label) assert(v,label);passed=passed+1 end
local jobs,calls={},{}
local malformed,timeout=false,false
local private_fields
local conn={}
function conn:list_tools()
 return json.encode{tools={{name='list_tools',inputSchema={type='object'}},{name='submit_workflow_dag',inputSchema={type='object'}},{name='get_dag',inputSchema={type='object'}},{name='get_dag_status',inputSchema={type='object'}},{name='cancel_dag',inputSchema={type='object'}}}}
end
function conn:call(name,body)
 local args=json.decode(body);calls[#calls+1]={name=name,args=args}
 local result
 if name=='list_tools' then result={status='OK',data={{tool_id='synthetic',input_schema={type='object',properties={value={type='integer'},items={type='array',items={type='string'}}}}}},delegation={contract='boggart-durable-v1',backend='python-native-sqlite',atomic_submit=true,retry_owner='aibywire',policy_ack=false,usage_ack=false}}
 elseif name=='submit_workflow_dag' then
   local d=args.definition
   check(d.context.operation_id and d.dag_id=='boggart:'..d.context.operation_id,'persistable remote identity')
   jobs[d.dag_id]=jobs[d.dag_id] or {backend='python-native-sqlite',remote_run_id=d.dag_id,operation_id=d.context.operation_id,state='running',result=json.null,artifacts={},policy_ack=false,usage_ack=false,retry_owner='aibywire'}
   if timeout then return nil,'timeout after dispatch' end
   result={status='OK',delegation=jobs[d.dag_id]}
 else result={status='OK',delegation=jobs[args.dag_id]} end
 if malformed then result={status='OK',delegation={state='succeeded'}} end
 if private_fields then result.debug=private_fields end
 return json.encode{content={{type='text',text=json.encode(result)}}}
end
local ctx=invoke.context{state={mode='auto',guards=false}}
local a=adapter.new{mcp=conn,id='fixture',db=db}
assert(a:discover(ctx))
local d=assert(a:register('synthetic',{id='jobs.synthetic',version='1',effect='write'}))
local first=a:submit(ctx,d.id,d.version,{value=2,items={}}, {operation_id='test:one'})
check(first.status=='succeeded' and first.result.state=='running','submit returns durable acknowledgement')
check(first.result.remote_run_id=='boggart:test:one','remote identity is stable')
check(calls[#calls].args.definition.nodes[1].depends_on==nil,'absent optional empty deps retains schema default')
local before=#calls
local resumed=a:reconnect(ctx,d.id,d.version,{value=2,items={}},'test:one')
check(resumed.result.remote_run_id==first.result.remote_run_id and calls[#calls].name=='get_dag','reconnect reads existing job')
check(#calls==before+1,'no client submission retry')
local denied=invoke.context{state={mode='auto',guards=false,tool_policy={[d.id]='deny'}}}
before=#calls
check(a:reconnect(denied,d.id,d.version,{value=2,items={}},'test:one').status~='succeeded' and #calls==before,'current authority gates reconnect')
timeout=true
local lost=a:submit(ctx,d.id,d.version,{value=3},{operation_id='test:lost'})
check(lost.status=='uncertain','lost submission reply uncertain')
timeout=false
check(a:reconnect(ctx,d.id,d.version,{value=3},'test:lost').result.remote_run_id=='boggart:test:lost','lost acknowledgement reconnect')
malformed=true
check(a:submit(ctx,d.id,d.version,{value=4},{operation_id='test:bad'}).status=='uncertain','malformed receipt uncertain')
malformed=false
before=#calls
check(a:submit(ctx,d.id,d.version,{value=1000000000000000}).error.code=='unsupported_encoding' and #calls==before,'unsafe integer refused pre-send')
local remote=jobs['boggart:test:one'];remote.state='succeeded';remote.result={value=42}
check(a:cancel(ctx,d.id,d.version,{value=2,items={}},'test:one').result.state=='succeeded','cancel race retains success')
check(a:status(ctx,d.id,d.version,{value=2,items={}},'test:one').result.result.value==42,'terminal receipt observed')
check(first.result.policy_ack==false and first.result.usage_ack==false,'no invented remote policy or usage claims')
before=#calls
check(a:status(ctx,d.id,d.version,{value=999},'test:one').status~='succeeded' and #calls==before,'different resource arguments cannot reconnect')
check(first.result.result_representation.empty_container_kind=='unavailable' and type(first.result.response_json)=='string','result projection explicitly references exact JSON')
local exact=json.decode(first.result.response_json)
check(exact.delegation.remote_run_id==first.result.remote_run_id,'exact source matches receipt identity')
-- Inspect actual persisted rows, including opaque JSON fields in receipts.
local function persisted_contains(needle)
  local function contains(value)
    if type(value)=='string' then return value:find(needle,1,true)~=nil end
    if type(value)=='table' then for key,item in pairs(value) do if contains(key) or contains(item) then return true end end end
    return false
  end
  for _,row in ipairs(assert(db:query('SELECT body FROM evidence_events'))) do
    if contains(json.decode(row.body)) then return true end
  end
  for _,row in ipairs(assert(db:query('SELECT body FROM evidence_artifacts'))) do
    if contains(json.decode(row.body)) then return true end
  end
  return false
end
local escaped='fixture-alpha\nfixture-beta'
remote.result={value=42,password=escaped}
local private_result=a:status(ctx,d.id,d.version,{value=2,items={}},'test:one')
check(not persisted_contains(escaped) and not persisted_contains(json.encode(escaped):sub(2,-2)),'escaped sensitive result is absent from persisted evidence')
check(private_result.status=='succeeded' and private_result.result.response_json==nil
  and private_result.result.result_representation.exact_source=='unavailable'
  and private_result.result.result_representation.source_status=='redacted','sanitized receipt does not claim exact source')
remote.result={value=42}
local outside='outside-credential\nwith-escape'
private_fields={api_key=outside}
local private_outer=a:cancel(ctx,d.id,d.version,{value=2,items={}},'test:one')
check(not persisted_contains(outside) and not persisted_contains(json.encode(outside):sub(2,-2)),'sensitive field outside delegation is absent from persisted evidence')
check(private_outer.status=='succeeded' and private_outer.result.response_json==nil
  and private_outer.result.result.value==42,'outside sanitization retains useful delegation result without opaque JSON')
private_fields=nil
print('aibywire: '..passed..' checks passed')
