local Control=require 'agentcontrol';local json=require 'json'
local function fixture()
  local incoming,outgoing={},{};local rev=0;local closed=false
  local channel={send=function(_,bytes)outgoing[#outgoing+1]=json.decode(bytes);return true end,
    receive=function()return table.remove(incoming,1)end,close=function()closed=true;rev=rev+1 end,
    revision=function()return rev end,state=function()return {closed=closed}end}
  local c=Control.new(channel,'runtime',2)
  local function push(value)
    rev=rev+1;incoming[#incoming+1]=type(value)=='string' and value or json.encode(value)
  end
  local function state(sequence,fields)
    local value={v=1,type='state',id='runtime',generation=2,sequence=sequence,state='idle',session_id=44,
      model='fixture',input_revision=0,draft_bytes=0,capabilities={prompt=true,interrupt=false,approve=false}}
    for k,v in pairs(fields or {})do value[k]=v end;push(value)
  end
  assert(outgoing[1].type=='bind' and outgoing[1].generation==2)
  return c,push,state,outgoing,channel
end
local c,push,state,out=fixture()
assert(not c:command('prompt',{text='before handshake'}))
state(1);assert(c:poll().session_id==44)
local sent,id=c:command('prompt',{text='literal / ! command',input_revision=9});assert(sent)
assert(out[#out].input_revision==9 and out[#out].text=='literal / ! command' and out[#out].command_seq==1)
push{v=1,type='result',id='runtime',generation=2,command_id=id,accepted=false,error='draft changed'}
assert(c:poll().control_result.error=='draft changed' and c.pending_count==0)
for _=1,32 do assert(c:command('prompt',{text='pending'}))end
assert(not c:command('prompt',{text='overflow'}) and c.pending_count==32)
state(1);assert(c:poll().error=='invalid agent state' and not c:command('prompt',{text='after error'}))
for _,bad in ipairs({'not json',json.encode{v=1,type='state',id='wrong',generation=2}})do
  local x,add=fixture();add(bad);assert(x:poll().capabilities.prompt==false)
end
do
  local x,_,send_state=fixture();send_state(1,{capabilities={prompt='yes',interrupt=false,approve=false}})
  assert(x:poll().error=='invalid agent capability')
  send_state(2);assert(x:poll()==nil and not x.status,'a failed channel cannot restore stale buffered capabilities')
end
do
  local x,_,send_state,_,channel=fixture();send_state(1);x:poll();channel:close()
  local fields=x:poll();assert(fields.state=='alive' and not fields.capabilities.prompt and not x:command('interrupt'))
end
print('Agent host: bind/metadata, command identity/revision, bounded pending requests, malformed/stale frames and channel-loss capabilities pass')
return 0
