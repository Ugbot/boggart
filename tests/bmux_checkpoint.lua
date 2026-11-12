local C=require 'bmux.checkpoint';local json=require 'json'
local fixture=assert(loadfile('tests/fixtures/bmux_checkpoint.lua'))()
local host,document=fixture()
local valid,why=C.validate(document);assert(valid,why and why.message)
assert(valid~=document and valid.layout~=document.layout and valid.terminals[1].lines~=document.terminals[1].lines)
document.terminals[1].lines[1]='modified';document.agents[1].resume_id=99
assert(valid.terminals[1].lines[1]=='earlier é'and valid.agents[1].resume_id==42)
local encoded=assert(C.encode(valid));local decoded=assert(C.decode(encoded))
assert(assert(C.encode(decoded))==encoded,'canonical checkpoint round trip')
local imported=assert(C.import(encoded))
for _,t in ipairs(imported.terminals)do assert(t.launch=='saved')end
for _,a in ipairs(imported.agents)do assert(a.launch=='saved')end
assert(imported.agents[1].resume_id==42 and imported.terminals[1].lines[2]=='👩‍💻 🇬🇧')
assert(C.decode(encoded).terminals[1].launch=='shell'and C.decode(encoded).agents[1].launch=='boggart',
  'import demotes copied recipes without changing source bytes or resume/history references')
assert(decoded.layout.workspaces[1].surfaces[1].zoomed_pane_id~=json.null)
local calls=0
local function reject(change)
  local bad=json.decode(encoded);change(bad);calls=calls+1
  local value,error=C.validate(bad)
  assert(not value and error.kind=='checkpoint'and #error.message<=512,'must reject case '..calls)
end
for _,change in ipairs{
  function(c)c.v=2 end,
  function(c)c.commands={'touch marker'}end,
  function(c)c.control_token='secret'end,
  function(c)c.terminals[1].argv={'-c','touch marker'}end,
  function(c)c.terminals[1].env={'SECRET=value'}end,
  function(c)c.terminals[1].launch='command'end,
  function(c)c.terminals[1].cwd='relative/path'end,
  function(c)c.terminals[1].cwd='file:///tmp'end,
  function(c)c.terminals[1].cwd='/tmp/\0x'end,
  function(c)c.terminals[1].cwd='/tmp/\255'end,
  function(c)c.terminals[1].cols=4097 end,
  function(c)c.terminals[1].rows=0 end,
  function(c)c.terminals[1].history=100001 end,
  function(c)c.terminals[1].generation=0 end,
  function(c)c.terminals[1].program='sh\27-c' end,
  function(c)c.terminals[1].lines={'\27]52;c;payload\7'}end,
  function(c)c.terminals[1].lines={'x\nnext'}end,
  function(c)c.terminals[1].lines={'x\194\1552J'}end,
  function(c)c.terminals[1].lines={'\255'}end,
  function(c)c.terminals[1].lines={[1]='first',[3]='sparse'}end,
  function(c)c.terminals[1].lines={string.rep('x',32769)}end,
  function(c)c.terminals[1].lines={string.rep('x',32768),string.rep('x',32768),'x'}end,
  function(c)c.terminals[1].lines={};for i=1,257 do c.terminals[1].lines[i]=''end end,
  function(c)c.terminals[3]=c.terminals[1]end,
  function(c)c.terminals[1].id='changed-reference'end,
  function(c)c.terminals[1].generation=8 end,
  function(c)c.agents[1].id='changed-agent'end,
  function(c)c.agents[1].terminal_generation=1 end,
  function(c)c.agents[1].terminal_id='not-there'end,
  function(c)c.agents[1].terminal_id=nil end,
  function(c)c.agents[1].capabilities={prompt=true}end,
  function(c)c.agents[1].request={id='stale-approval'}end,
  function(c)c.agents[1].launch='boggart';c.agents[1].resume_id=nil end,
  function(c)c.agents[1].provider='custom'end,
  function(c)c.agents[1].resume_id='42'end,
  function(c)c.terminals[2].launch='shell'end,
  function(c)c.agents[3]=c.agents[1]end,
  function(c)c.agents[3]={id='duplicate-owner',generation=1,provider='boggart',name='Other',launch='saved',terminal_id='old-agent-terminal',terminal_generation=9}end,
  function(c)c.terminals={};for i=1,4097 do c.terminals[i]={}end end,
  function(c)c.agents={};for i=1,1025 do c.agents[i]={}end end,
  function(c)c.layout.workspaces[1].selected_surface_id='missing'end,
  function(c)c.layout.workspaces[1].surfaces[1].tree.a=c.layout.workspaces[1].surfaces[1].tree end,
  function(c)c.terminals=setmetatable({},{__index=function()error('metatable must not run')end})end,
  function(c)
    local lines={string.rep('x',32768),string.rep('y',32768)}
    for i=3,35 do c.terminals[i]={id='budget-'..i,generation=1,cwd='/tmp',cols=80,rows=24,history=256,launch='saved',lines=lines}end
  end,
}do reject(change)end
for _,raw in ipairs{'','[]','null','{broken','{"v":1}',string.rep(' ',4*1024*1024+1)}do
  local value,error=C.decode(raw);assert(not value and error.kind=='checkpoint'and #error.message<=512)
end
local extra=json.decode(encoded)
extra.terminals[1].cwd='C:\\work\\tree';extra.terminals[2].cwd='\\\\server\\share'
extra.agents[3]={id='11',generation=1,provider='custom',name='String ID',launch='saved'}
assert(C.validate(extra),'absolute Windows cwd and distinct numeric/string agent IDs')
local bare={v=1,layout=require('bmux.layout').new{resolve=function()return true end}:snapshot(),terminals={},agents={}}
local empty=assert(C.encode(bare));assert(empty:find('"workspaces":[]',1,true)and empty:find('"terminals":[]',1,true)and empty:find('"agents":[]',1,true))
local metadata={v=1,layout=bare.layout,terminals={},agents={}}
for i=1,1100 do metadata.terminals[i]={id='metadata-'..i,generation=1,cwd='/'..string.rep('x',4095),cols=80,rows=24,history=0,launch='saved',lines={}}end
local oversized,error=C.encode(metadata)
assert(not oversized and error.message:find('encoded checkpoint size limit',1,true),'metadata cannot bypass encoded document budget')
local deepest=json.decode(encoded);local node_id,focused=0
local function chain(level)
  node_id=node_id+1;local id=node_id
  if level==24 then
    focused=id;return {id=id,type='leaf',views={{id='deep-view',kind='terminal',terminal_id='old-shell',generation=7}},active_view_id='deep-view'}
  end
  local a=chain(level+1);node_id=node_id+1
  return {id=id,type='hsplit',divider=.5,a=a,b={id=node_id,type='leaf',views=json.array,active_view_id=json.null}}
end
local workspace=deepest.layout.workspaces[1];local surface=workspace.surfaces[1]
deepest.layout.workspaces={workspace};workspace.surfaces={surface}
surface.tree=chain(1);surface.focused_pane_id=focused;surface.zoomed_pane_id=json.null
local deepest_encoded=assert(C.encode(deepest))
local decode=json.decode;json.decode=json.lua_decode
assert(C.decode(encoded));assert(C.decode(deepest_encoded),'full supported tree depth fits fallback JSON preflight')
assert(not C.decode(string.rep('{"nested":',34)..'null'..string.rep('}',34)))
json.decode=decode
assert(host.host_id=='checkpoint-old-host'and #host.workspaces==2,'codec never mutates the source host')
print('Bmux checkpoint: copied canonical data, recipes/ownership/refs, Unicode/history budgets, malformed/deep JSON and no execution fields pass ('..calls..' rejection cases)')
return 0
