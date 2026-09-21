local json=require('json')
local M={version=1}
local function message(e,content)
  e.kind='message'
  if type(content)=='string' then e.value=content;return end
  if type(content)~='table' then
    e.content_omissions={unsupported=1};e.value_provenance='missing';return
  end
  local out,omitted={},0
  for _,b in ipairs(content) do
    if type(b)=='table' and (b.type=='input_text' or b.type=='output_text' or b.type=='text') and type(b.text)=='string' then
      out[#out+1]=b.text
    else omitted=omitted+1 end
  end
  if #out>0 then e.value=table.concat(out,'\n') end
  if omitted>0 or #out==0 then
    e.content_omissions={unsupported=omitted,empty=#out==0}
    e.value_provenance=#out>0 and 'partial' or 'missing'
  end
end
function M.normalize(r)
  local p=r.payload;assert(type(p)=='table','payload')
  if r.type=='session_meta' then return {{kind='context',external_id='session_meta',value={version=p.cli_version,parent=p.parent_thread_id},timestamp=r.timestamp}},p.id or p.session_id end
  local e={timestamp=r.timestamp,external_id=p.id}
  if r.type=='response_item' then
    if p.type=='message' or p.type=='agent_message' then e.role=p.role or p.author;message(e,p.content)
    elseif p.type=='function_call' or p.type=='custom_tool_call' then
      e.kind='tool.request';e.call_id=p.call_id;e.external_id=p.call_id;e.name=p.name;e.namespace=p.namespace;e.value=p.arguments or p.input
      if p.type=='function_call' and type(e.value)=='string' then
        local ok,decoded=pcall(json.decode,e.value);if ok then e.decoded_arguments=decoded;e.arguments_decoded=true end
      end
      e.encoding=type(e.value)=='string' and (p.type=='function_call' and 'json_string' or 'text') or nil
    elseif p.type=='function_call_output' or p.type=='custom_tool_call_output' then e.kind='tool.result';e.call_id=p.call_id;e.external_id=p.call_id;e.value=p.output
    else return {},nil,'unsupported_record' end
  elseif r.type=='event_msg' and p.type=='item_completed' then
    local item=p.item;assert(type(item)=='table','item');e.external_id=item.id
    if item.type=='UserMessage' or item.type=='AgentMessage' then
      e.role=item.type=='UserMessage' and 'user' or 'assistant';message(e,item.content)
    elseif item.type=='CommandExecution' or item.type=='FileChange' or item.type=='SubAgentActivity' or item.type=='Extension' then
      -- Completion summaries are contextual observations, never second operations/costs.
      e.kind='context.summary';e.value={type=item.type,command=item.command,output=item.aggregated_output or item.stdout,
        stderr=item.stderr,status=item.status,exit_code=item.exit_code,changes=item.changes,agent_thread_id=item.agent_thread_id}
    else return {},nil,'unsupported_record' end
  elseif r.type=='turn_context' then
    e.kind='context';e.external_id=p.turn_id;e.value={model=p.model,turn_id=p.turn_id,summary=p.summary}
  elseif r.type=='event_msg' and (p.type=='task_started' or p.type=='task_complete') then
    e.kind='context';e.external_id=p.turn_id and p.type..':'..p.turn_id;e.value={type=p.type,turn_id=p.turn_id}
  else return {},nil,'unsupported_record' end
  return {e},p.session_id or p.thread_id
end
return M
