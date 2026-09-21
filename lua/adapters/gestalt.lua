-- Privileged host port. Scope and endpoint are captured, never request arguments.
local M={}
local cap,json=require('capability'),require('json')
local hash=require('workflow').hash
-- Full 256-bit identity in 43 URL-safe bytes; EsStore index names cap at 48.
local function index_identity(value)
  local bytes=hash(value):gsub('..',function(hex)return string.char(tonumber(hex,16))end)
  local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
  local out,acc,bits={},0,0
  for i=1,#bytes do
    acc=(acc<<8)|bytes:byte(i);bits=bits+8
    while bits>=6 do bits=bits-6;local n=(acc>>bits)&63;out[#out+1]=alphabet:sub(n+1,n+1) end
    acc=acc&((1<<bits)-1)
  end
  if bits>0 then local n=(acc<<(6-bits))&63;out[#out+1]=alphabet:sub(n+1,n+1) end
  return 'bg-'..table.concat(out)
end
local function failure(write,why)
  return nil,{status=write and 'uncertain' or 'failed',error={code='gestalt_unavailable',message=why},receipt={remote_policy=false}}
end
function M.new(options)
  assert(type(options)=='table' and type(options.scope)=='string' and options.scope~='','host scope required')
  assert(type(options.namespace)=='string' and options.namespace~='','store namespace required')
  local scope,base=options.scope,assert(options.base_url,'explicit Gestalt endpoint required')
  assert(base:match('^https?://') and not base:find('[?#]'),'invalid endpoint')
  local index=index_identity(options.namespace..'\0'..scope)
  local request=options.request or function(method,path,body)
    return require('gestalt').es_request(base,method,path,body,options.timeout or 3,options.api_key)
  end
  local prefix=options.capability_prefix or ('gestalt.memory.'..hash(base..'\0'..index):sub(1,24))
  local self={index=index,scope=scope}
  local function register(op,effect,runner)
    assert(cap.register({id=prefix..'.'..op,version='1',effect=effect,target='gestalt:'..base,
      resources=function()return {scope=scope,index=index,endpoint=base}end,
      input_schema={type='object'},output_schema={type='object'}},runner))
  end
  register('search','read',function(args)
    local result,err=request('POST','/'..index..'/_search',args)
    if not result or type(result.hits)~='table' or type(result.hits.hits)~='table' then return failure(false,err or 'invalid search response') end
    -- Reject misrouting before invoke can persist remote data as evidence.
    -- Only bounded identities/scores cross this adapter; local memory hydrates.
    local safe={hits={hits={}}}
    if #result.hits.hits>100 then return failure(false,'oversized search response') end
    for _,hit in ipairs(result.hits.hits) do
      local source=hit._source
      if hit._index~=index or type(source)~='table' or source.scope~=scope
        or type(source.source_id)~='string' or #source.source_id>1024
        or hit._id~=hash(source.source_id) or type(source.revision)~='number'
        or source.revision%1~=0 or source.revision<1 or source.revision>9007199254740991
        or type(hit._score)~='number' or hit._score~=hit._score or math.abs(hit._score)==math.huge then return failure(false,'misrouted or malformed search response') end
      safe.hits.hits[#safe.hits.hits+1]={_id=hit._id,_score=hit._score,
        _source={source_id=source.source_id,scope=scope,revision=source.revision}}
    end
    return safe,{status='succeeded',receipt={remote_policy=false,protocol='gestalt-es'}}
  end)
  register('put','write',function(args)
    assert(args.scope==scope and type(args.source_id)=='string','memory_scope_denied')
    local result,err=request('PUT','/'..index..'/_doc/'..hash(args.source_id),args)
    if not result or result._index~=index or result._id~=hash(args.source_id) or not ({created=true,updated=true})[result.result] then return failure(true,err or 'invalid upsert receipt') end
    return {_id=result._id,result=result.result},{status='succeeded',receipt={remote_policy=false,stable_id=true}}
  end)
  register('delete','write',function(args)
    local result,err=request('DELETE','/'..index..'/_doc/'..args.document_id)
    if not result or result._index~=index or result._id~=args.document_id or not ({deleted=true,not_found=true})[result.result] then return failure(true,err or 'invalid deletion receipt') end
    return {_id=result._id,result=result.result},{status='succeeded',receipt={remote_policy=false,stable_id=true}}
  end)
  function self:call(context,op,args)
    assert(({search=true,put=true,delete=true})[op],'invalid memory operation')
    -- Data-bearing evidence belongs to its source scope. Cleanup receipts use
    -- only opaque document identities and can survive source-scope deletion.
    local correlation_scope=scope
    if op=='delete' then args={document_id=hash(args.source_id)};correlation_scope='memory-cleanup:'..index end
    return require('invoke').with_correlation({scope=correlation_scope},function()
      return cap.call(context,prefix..'.'..op,'1',args)
    end)
  end
  function self:features()
    return {protocol='gestalt-es',scope_isolation='named_index_before_ranking',stable_ids=true,
      text='whole_document_bm25',token_limit=4096,token_bytes=64,structured='scalar_terms',graph='relation_fields_only',vector=false,
      conditional_versions=false,remote_policy=false,availability='requires_successful_request'}
  end
  return self
end
return M
