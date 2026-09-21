local M={version=1}
function M.normalize(r)
  local session=r.sessionId or r.session_id
  if r.type~='user' and r.type~='assistant' then return {},session,'unsupported_record' end
  assert(type(r.message)=='table','message')
  local m=r.message;local content=m.content
  if type(content)=='string' then content={{type='text',text=content}} end
  assert(type(content)=='table','content')
  local out={}
  for i,b in ipairs(content) do
    assert(type(b)=='table','block')
    local e={timestamp=r.timestamp,external_id=r.uuid and r.uuid..':'..i,parent=r.parentUuid,
      context={sidechain=r.isSidechain,source_assistant=r.sourceToolAssistantUUID},role=m.role}
    if b.type=='text' then e.kind='message';e.value=b.text
    elseif b.type=='tool_use' then e.kind='tool.request';e.call_id=b.id;e.name=b.name;e.value=b.input;e.external_id=b.id
    elseif b.type=='tool_result' then e.kind='tool.result';e.call_id=b.tool_use_id;e.value=b.content;e.reported_error=b.is_error;e.external_id=b.tool_use_id
    else e.kind='coverage.omitted';e.value={reason='unsupported_content'} end
    out[#out+1]=e
  end
  return out,session
end
return M
