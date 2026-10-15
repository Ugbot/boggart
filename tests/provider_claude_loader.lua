-- Opt-in compatibility probe: actual Claude Setup hooks, no model turn.
local uv=require 'uv';local proc=require 'proc';local json=require 'json'
local claude=assert(os.getenv('BMUX_CLAUDE_PROBE'),'set BMUX_CLAUDE_PROBE to the installed Claude executable')
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local root=assert(uv.fs_mkdtemp('/tmp/bmux-claude-loader-XXXXXX'))
assert(uv.fs_mkdir(root..'/home',448));assert(uv.fs_mkdir(root..'/project',448))
local registry=require('fleet').new{prefix='loader',max_records=4}
local service=require('manualfleet').new{registry=registry,clock=function()return uv.hrtime()/1e9 end,ttl=60}
local pane=service:pane{focus=function()return true end,alive=function()return true end}
local accepted={}
local server=assert(serve.listen{socket=root..'/control.sock',handler=function(req)
  local status,body,headers=service:handle(req)
  if req.path=='/bmux/agents/notify' and status==200 then accepted[#accepted+1]=json.decode(req.body).event.hook_event_name end
  return status,body,headers
end})
local hooks=assert(require('agenthooks').install{directory=root,executable=uv.exepath(),path=claude:match('^(.*)/')..':/usr/bin:/bin',cwd=root})
-- A second plugin proves the injected hook set coexists with caller plugins.
local other=root..'/existing-plugin';local marker=root..'/existing-hook-ran'
for _,path in ipairs{other,other..'/.claude-plugin',other..'/hooks'}do assert(hooks:directory(path))end
assert(hooks:write(other..'/.claude-plugin/plugin.json',json.encode{name='existing-fixture',version='1.0.0'}))
local existing=json.encode{hooks={Setup={{hooks={{type='command',command='printf existing > '..q(marker)}}}}}}
assert(hooks:write(other..'/hooks/hooks.json',existing))
local result=proc.run('cd '..q(root..'/project')..' && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN '
  ..'HOME='..q(root..'/home')..' CLAUDE_CONFIG_DIR='..q(root..'/home/.claude')..' CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 '
  ..'BOGGART_SOCKET='..q(root..'/control.sock')..' BOGGART_PANE_ID='..q(pane.id)..' BOGGART_PANE_TOKEN='..q(pane.token)..' '
  ..q(uv.exepath())..' ctl run --provider claude -- '..q(claude)..' '..q('--plugin-dir='..hooks.claude_plugin)
  ..' '..q('--plugin-dir='..other)
  .." --setting-sources '' --init-only",35)
local f=assert(io.open(other..'/hooks/hooks.json'));assert(f:read('*a')==existing);f:close()
f=io.open(marker);local additive=f and f:read('*a')=='existing';if f then f:close()end
server:stop();uv.run('nowait');hooks:cleanup()
print('provider_claude_loader: native exit '..tostring(result.code)..'; accepted events '..table.concat(accepted,','))
-- The isolated provider may create its own settings/cache here; retain for inspection.
print('provider_claude_loader: isolated artifacts '..root)
assert(result.code==0,result.out)
local setup=false;for _,name in ipairs(accepted)do if name=='Setup'then setup=true end end
assert(setup,'installed Claude did not execute the generated Setup hook: '..result.out)
assert(additive,'installed Claude did not preserve the other plugin hook')
print('provider_claude_loader: existing plugin hook preserved and executed')
return 0
