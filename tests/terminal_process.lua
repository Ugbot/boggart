local terminal = require 'terminal'
local uv = require 'uv'
if package.config:sub(1,1) == '\\' then
  local t, err = terminal.open{cmd='cmd.exe'}
  assert(t == nil and type(err) == 'string') -- BMUX-22 provides ConPTY later.
  print('Unix PTY unavailable; ConPTY remains BMUX-22')
  return
end
local function text(t)
  local out = {}
  for _, row in ipairs(t:snapshot().screen) do
    for _, cell in ipairs(row.cells) do out[#out+1] = cell.text ~= '' and cell.text or ' ' end
    out[#out+1] = '\n'
  end
  return table.concat(out)
end
local function shell(script, extra)
  local opts = extra or {}; opts.cmd='/bin/sh'; opts.args={'-c',script}
  local t, err = terminal.open(opts); assert(t, err); return t
end
local function run(t, status)
  local deadline = uv.new_timer()
  deadline:start(5000,0,function() t:close(); error('terminal process deadline') end)
  deadline:unref(); uv.run()
  deadline:stop(); deadline:close(); uv.run('nowait')
  local p=t:process_state()
  assert(p.exited and p.eof and not p.error and p.exit_status==(status or 0))
  return p
end
local plain <close> = terminal.new()
assert(plain:process_state()==nil and not pcall(plain.write,plain,'x'))
for _, opts in ipairs{
  {cmd=''}, {cmd='sh\0x'}, {cmd=7}, {cmd='/bin/sh',cwd='\0'},
  {cmd='/bin/sh',args={'-c',7}}, {cmd='/bin/sh',args={'\0'}},
  {cmd='/bin/sh',cols=0}, {cmd='/bin/sh',rows=4097}, {cmd='/bin/sh',history=-1},
} do assert(not pcall(terminal.open,opts)) end
for _, opts in ipairs{{cmd='/no/such/bmux-command'},{cmd='/bin/sh',cwd='/no/such/bmux-dir'}} do
  local t, err=terminal.open(opts); assert(t==nil and type(err)=='string'); uv.run()
end
do
  local t <close> = shell([[printf '\033[31mred\033[0m e\314\201\033]0;native-title\007'; exit 7]],{cols=40,rows=4})
  local p=run(t,7); assert(p.bytes_read>0 and p.read_callbacks>0)
  assert(text(t):find('red é',1,true))
  assert(t:row(1).cells[1].style.fg == terminal.COLOR_INDEXED | 1)
  local events,dropped=t:events(); assert(#events==1 and events[1].text=='native-title' and dropped==0)
  assert(t:replies()=='')
end
do
  local t <close> = shell([[stty raw -echo; printf '\033[6n'; reply=$(dd bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \n'); [ "$reply" = "1b5b313b3152" ] && printf REPLY_OK]])
  run(t); assert(text(t):find('REPLY_OK',1,true) and t:replies()=='')
end
do
  local t <close> = shell([[stty raw -echo; printf READY; IFS= read -r line; printf '%s\r\n' "$line"; stty size]])
  local deadline=uv.new_timer(); deadline:start(5000,0,function() t:close(); error('ready deadline') end); deadline:unref()
  while not text(t):find('READY',1,true) do uv.run('once') end
  deadline:stop(); deadline:close(); uv.run('nowait')
  assert(t:foreground_group()==t:process_state().pid)
  local before=t:process_state(); for _=1,100 do assert(t:process_state().read_callbacks==before.read_callbacks) end
  t:resize(123,45); assert(t:write('payload\n')==8); run(t)
  assert(text(t):find('payload',1,true) and text(t):find('45 123',1,true))
  assert(t:snapshot().cols==123 and t:snapshot().rows==45)
  t:resize(40,4); assert(t:snapshot().cols==40) -- frozen grid still resizes after EOF.
end
do
  local t <close> = shell([[printf '%s %s' "$TERM" "$COLORTERM"]]); run(t)
  assert(text(t):find('xterm-256color truecolor',1,true))
end
for i=1,20 do
  local t <close> = shell('printf early; exit '..(i%10)); run(t,i%10)
  assert(text(t):find('early',1,true))
end
do
  local t=shell([[trap '' HUP; printf READY; while :; do sleep 1; done]])
  while not text(t):find('READY',1,true) do uv.run('once') end
  t:close(); assert(not pcall(t.state,t)); uv.run()
end
do
  local t=shell('sleep 10'); t=nil; collectgarbage('collect'); uv.run()
end
do
  local h=worker.spawn([[
    rawset(_G,'retained_terminal',assert(require('terminal').open{cmd='/bin/sh',args={'-c','sleep 30'}}))
    worker.post('worker owns live PTY')
  ]])
  assert(worker.recv(h,5000)=='worker owns live PTY'); assert(worker.join(h))
end
-- Finalizers can drain/feed/close a terminal at allocation boundaries.
-- Events must use an immutable rooted image, with no borrowed live queue.
local triggered=0
local old_pause=collectgarbage('param','pause',100)
local old_step=collectgarbage('param','stepsize',0)
for i=1,30 do
  collectgarbage('collect'); collectgarbage('stop')
  local t=terminal.new(); t:feed(('\27]0;captured\a'):rep(256))
  local inside,ran=false,false
  do local garbage=setmetatable({}, {__gc=function()
    ran=true
    if inside then triggered=triggered+1; t:close() end
  end}); garbage=nil end
  collectgarbage('incremental'); collectgarbage('restart'); inside=true
  local ok,events=pcall(t.events,t); inside=false
  if ok then assert(#events==256 and events[1].text=='captured' and events[256].text=='captured') else assert(tostring(events):find('closed terminal',1,true)) end
  collectgarbage('collect'); assert(ran); t:close()
end
assert(triggered>0,'event finalizer must run inside event retrieval')
collectgarbage('incremental'); collectgarbage('restart')
collectgarbage('param','pause',old_pause); collectgarbage('param','stepsize',old_step)
print('native-fed Lua PTYs, automatic replies, resize, events, early exit and deferred GC close pass')
