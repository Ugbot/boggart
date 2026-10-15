-- Additive per-session Claude plugin; no user/provider settings are rewritten.
local json=require 'json'
local M={events={'Setup','SessionStart','UserPromptSubmit','PreToolUse','PermissionRequest',
  'PostToolUse','PostToolUseFailure','Notification','Stop','StopFailure','SessionEnd'}}
local function quote(s)return "'"..s:gsub("'","'\\''").."'"end
function M.install(set,cli)
  local root=set.root..'/claude-fleet';local hooks={}
  for _,event in ipairs(M.events)do hooks[event]={{hooks={{type='command',command=quote(cli)..' ctl notify --provider claude',timeout=3}}}}end
  for _,dir in ipairs{root,root..'/.claude-plugin',root..'/hooks'}do
    local ok,why=set:directory(dir);if not ok then return nil,why end
  end
  for path,value in pairs{
    [root..'/.claude-plugin/plugin.json']={name='bmux-fleet',version='1.0.0',description='Report agent activity to the local BMUX Fleet'},
    [root..'/hooks/hooks.json']={description='Observational local Fleet events',hooks=hooks},
  }do local ok,why=set:write(path,json.encode(value));if not ok then return nil,why end end
  set.claude_plugin=root;return true
end
return M
