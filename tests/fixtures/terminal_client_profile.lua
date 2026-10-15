-- Isolated phase benchmark, not the end-to-end BMUX-32 acceptance gate.
if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local Registry=require 'terminal.registry'
local R=require 'terminal.replica';local json=require 'json'
local registry=Registry.new()
local record=assert(registry:open{cmd='/bin/sh',args={'-c','sleep 10'},cols=80,rows=24,history=128})
local entry=registry.entries[record.id]
for i=1,64 do entry.term:feed(string.format('line-%02d 🦊 é\r\n',i))end
local function time(fn)local started=uv.hrtime();local value=fn();return (uv.hrtime()-started)/1e6,value end
for _=1,3 do
  local capture,raw=time(function()return assert(registry.attachments:attach(entry,{generation=1,tail=32}))end)
  local decode,frame=time(function()return assert(R.decode(raw))end)
  local native=time(function()return json.decode(raw)end)
  local apply=time(function()assert(R.new(record.id,1):apply(frame))end)
  print(json.encode{bytes=#raw,capture_ms=capture,checked_decode_ms=decode,native_decode_ms=native,apply_ms=apply})
end
registry:shutdown();uv.run('nowait')
return 0
