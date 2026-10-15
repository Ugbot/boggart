local terminal=require 'terminal';local json=require 'json';local R=require 'terminal.replica'
local native=terminal.new(12,3,8)
native:feed('one\r\ntwo\r\nthree\r\nfour\r\n\27[31m🦊é\27[0m\27]8;id=test;https://example.com\7X\27]8;;\7')
local function copy(v)return json.decode(json.encode(v))end
local function snapshot()
  local screen,history={},{};for y=1,3 do screen[y]=native:row(y)end
  local versions=native:row_versions(4)
  for i=1,#versions.scrollback do history[i]=native:row(versions.history-#versions.scrollback+i,true)end
  return {v=1,id='term-test',generation=1,attachment_id='reader',after=0,cursor=1,kind='snapshot',cols=12,rows=3,
    screen=screen,state=native:state(),scrollback={first=versions.history-#history+1,total=versions.history,rows=history},
    process={id='term-test',generation=1,state='alive',cmd='/bin/sh',cwd='/tmp',cols=12,rows=3,history=8,
      bytes=10,queued_bytes=0,revision=1,pid=123,closed=false,attachment_controlled=true}}
end
local frame=snapshot();local replica=R.new(frame.id,1)
assert(replica:apply(frame));assert(json.encode(replica.view.screen)==json.encode(frame.screen))
assert(json.encode(replica.view.scrollback)==json.encode(frame.scrollback));assert(replica:apply(frame)==false)
assert(replica:apply{v=1,id=frame.id,generation=1,attachment_id='reader',after=1,cursor=1,kind='unchanged'}==false)
local delta={v=1,id=frame.id,generation=1,attachment_id='reader',after=1,cursor=2,kind='delta',cols=12,rows=3,
  changes={{index=1,row=frame.screen[2]}},state=frame.state,process=frame.process,scrollback=false}
local before=json.encode(replica.view)
local function bad(edit)
  local broken=copy(delta);edit(broken);local changed,why=replica:apply(broken)
  assert(changed==nil and why.kind=='protocol');assert(json.encode(replica.view)==before,'invalid frame partially published')
end
bad(function(f)f.changes[2]={index=3,row=copy(frame.screen[3])};f.changes[2].row.cells[12].text='\255'end)
bad(function(f)f.changes[2]={index=1,row=frame.screen[1]}end)
bad(function(f)f.after=2;f.cursor=3 end)
bad(function(f)f.generation=2 end)
bad(function(f)f.attachment_id='other'end)
bad(function(f)f.cols=4096;f.rows=4096 end)
bad(function(f)f.changes[1].row.cells[1].codepoint=0xd800 end)
bad(function(f)f.changes[1].row.cells[1].style.attrs=-1 end)
bad(function(f)f.changes[1].index=4 end)
bad(function(f)f.scrollback={first=1,total=2,rows={}}end)
bad(function(f)f.state.alternate=not f.state.alternate end)
assert(replica:apply(delta));assert(replica.view.cursor==2 and replica.view.screen[1].cells[1].text==frame.screen[2].cells[1].text)
assert(not R.decode(string.rep('[',33)..'0'..string.rep(']',33)))
local saved_decode=json.decode;json.decode=json.lua_decode
assert(not R.decode('{"nested":'..string.rep('[',33)..'0'..string.rep(']',33)..'}'))
assert(R.decode('{"text":"[\\\"🦊]"}').text=='["🦊]')
json.decode=saved_decode
assert(not R.decode('{broken'));native:close()
print('terminal_replica: exact Unicode/style/link/history, independent atomic application and adversarial frames pass')
return 0
