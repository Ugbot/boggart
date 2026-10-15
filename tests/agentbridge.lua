local Bridge=require 'tui.agentbridge'
local json=require 'json'
local Input=require 'tui.input'
local queue,sent={},{}
local channel={send=function(_,s)sent[#sent+1]=json.decode(s);return true end,
  receive=function()return table.remove(queue,1)end,state=function()return {}end,close=function()end}
local st={box=Input.new(),coord={session={id=123,model='fixture',inbox={}}},entries={}}
local bridge=Bridge.new(st,channel);local serial=0
queue[1]=json.encode{v=1,type='bind',id='runtime',generation=4};bridge:poll()
assert(sent[#sent].type=='state' and sent[#sent].state=='idle')
assert(not bridge.workers and sent[#sent].capabilities.worker_stop==false,'worker reports require feature negotiation')
local function command(action,fields)
  serial=serial+1
  local c={v=1,type='command',id='runtime',generation=4,command_seq=serial,command_id='cmd'..serial,
    input_revision=bridge.revision,action=action}
  for k,v in pairs(fields or {})do c[k]=v end
  queue[1]=json.encode(c);bridge:poll()
  for i=#sent,1,-1 do if sent[i].command_id==c.command_id then return sent[i],c end end
  error('no command acknowledgement')
end
assert(command('prompt',{text='first'}).accepted);assert(bridge:take_prompt()=='first')
st.box:paste('human draft');bridge:poll()
assert(not command('prompt',{text='unsafe'}).accepted and st.box.line=='human draft')
st.box:_set('');bridge:poll()
assert(not command('prompt',{text='stale',input_revision=0}).accepted)
assert(not command('prompt',{text='wrong runtime',generation=3}).accepted)
st.running=true;assert(command('prompt',{text='steer'}).accepted and st.coord.session.inbox[1]=='steer')
local result,c=command('interrupt');assert(result.accepted and st.abort)
queue[1]=json.encode(c);bridge:poll();assert(sent[#sent].error=='replayed command')
st.pending={name='write',summary='fixture write'};bridge:poll();local first=bridge.request_id
assert(not command('approve',{request_id='wrong',decision='approve'}).accepted and not st.pending.decision)
assert(command('approve',{request_id=first,decision='reject'}).accepted and st.pending.decision=='reject')
st.pending={name='write',summary='same text, new live request'};bridge:poll()
assert(bridge.request_id~=first and not command('approve',{request_id=first,decision='approve'}).accepted)
assert(not command('prompt',{text='blocked dialog'}).accepted)
assert(command('approve',{request_id=bridge.request_id,decision='approve'}).accepted)
print('TUI bridge: actual composer draft guards, prompt/steer, generation/replay checks, interrupt and exact approval identity pass')
return 0
