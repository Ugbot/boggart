-- Executes the generated plugin's real commands, without a provider/model call.
local uv=require 'uv';local json=require 'json';local proc=require 'proc'
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local plugin=assert(os.getenv('BMUX_HOOK_FIXTURE_PLUGIN'))
local file=assert(io.open(plugin..'/hooks/hooks.json'));local hooks=json.decode(file:read('*a')).hooks;file:close()
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-hook-input-XXXXXX'));local input=dir..'/event.json'
local sid='fixture-'..uv.os_getpid()
io.stdout:setvbuf('no')
local function event(name,extra)
  local data={hook_event_name=name,session_id=sid,prompt='PRIVATE_PROMPT'}
  for k,v in pairs(extra or {})do data[k]=v end
  local f=assert(io.open(input,'w'));f:write(json.encode(data));f:close()
  for _,group in ipairs(assert(hooks[name]))do for _,hook in ipairs(group.hooks)do
    local result=proc.run(hook.command..' < '..q(input),5)
    assert(result.code==0,result.out)
  end end
end
event('SessionStart');print('HOOK_READY')
for line in io.lines()do
  if line=='quit'then event('SessionEnd');break
  elseif line=='crash'then uv.fs_unlink(input);uv.fs_rmdir(dir);return 7
  elseif line=='run'then event('UserPromptSubmit')
  elseif line=='approval'then event('PermissionRequest')
  elseif line=='answer'then event('PreToolUse',{tool_name='AskUserQuestion'})
  elseif line=='tool'then event('PostToolUse')
  elseif line=='stop'then event('Stop')
  elseif line=='child'then event('Stop',{agent_id='child'})end
  print('HOOK_SENT:'..line)
end
uv.fs_unlink(input);assert(uv.fs_rmdir(dir));return 0
