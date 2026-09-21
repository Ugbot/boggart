local json=require('json')
local M={version=1}
local function public_content(content)
  if type(content)~='table' then return content end
  local out={}
  for k,b in pairs(content) do
    if type(b)=='table' and (b.type=='thinking' or b.type=='redacted_thinking' or b.type=='reasoning') then
      out[k]={evidence_marker='unavailable',reason='private_reasoning_omitted'}
    else out[k]=b end
  end
  return out
end
function M.normalize(r)
  if type(r.messages)=='string' then r.messages=json.decode(r.messages) end
  if type(r.messages)=='table' then
    local out={}
    for _,m in ipairs(r.messages) do
      assert(type(m)=='table' and type(m.role)=='string','checkpoint_message')
      out[#out+1]={kind='message',role=m.role,value=public_content(m.content),lane='checkpoint'}
    end
    return out,r.session_id or r.id
  end
  local p=r.payload
  if type(p)=='string' then p=json.decode(p) end
  assert(type(p)=='table','payload')
  local e={timestamp=r.timestamp or r.ts,external_id=r.event_id,parent=r.parent_id,call_id=r.correlation_id,
    source_observation={step_id=r.step_id,attempt_id=r.attempt_id,provenance=r.provenance,
      artifact_refs=r.artifact_refs,origin=r.origin,record_id=r.id,event_id=r.event_id}}
  if r.kind=='entry' or r.kind=='session.entry' then
    assert(type(p.role)=='string' and (type(p.content)=='string' or type(p.content)=='table'),'entry')
    e.kind='message';e.role=p.role;e.value=public_content(p.content);e.external_id=nil;e.lane=r.kind
  else
    assert(type(r.kind)=='string' and r.schema_version==1,'evidence')
    e.kind='historical.'..r.kind;e.value=p
  end
  return {e},r.run_id
end
return M
