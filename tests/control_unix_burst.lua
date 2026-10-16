-- Queue a full 100-pane join's initial connects before accepting any. The
-- listen backlog must fit this burst inside the existing 256-connection cap.
if package.config:sub(1,1)=='\\'then return 0 end
local uv=require 'uv';local json=require 'json'
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-burst-XXXXXX'));local path=dir..'/sock'
local server=assert(serve.listen{socket=path,handler=function()return 200,json.encode{ok=true},{content_type='application/json'}end})
local clients,errors,done={},{},0;local expired=false
local deadline=uv.new_timer();deadline:start(5000,0,function()expired=true end)
for i=1,100 do
  local c={pipe=uv.new_pipe(false),bytes=''};clients[i]=c
  local function finish(why)
    if c.done then return end;c.done=true;done=done+1
    if why then errors[#errors+1]=why end
    if not c.pipe:is_closing()then c.pipe:close()end
  end
  c.pipe:connect(path,function(why)
    if why then finish(why);return end
    c.pipe:read_start(function(error,bytes)
      if error then finish(error)
      elseif bytes then c.bytes=c.bytes..bytes
      elseif c.bytes:find('200 OK',1,true)and c.bytes:find('"ok":true',1,true)then finish()
      else finish('invalid health response')end
    end)
    c.pipe:write('GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n',function(error)if error then finish(error)end end)
  end)
end
while done<100 and not expired do uv.run('once')end
deadline:stop();deadline:close()
for _,c in ipairs(clients)do if not c.pipe:is_closing()then c.pipe:close()end end
server:stop();uv.run('nowait');assert(uv.fs_rmdir(dir))
assert(not expired and done==100 and #errors==0,'100-connection burst: '..#errors..' failures; first='..tostring(errors[1]))
print('Private control UDS accepts and answers 100 simultaneous initial connects')
return 0
