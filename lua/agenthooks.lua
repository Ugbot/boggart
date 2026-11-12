-- Ephemeral command wrappers; provider activity still requires native hooks.
local uv=require 'uv'
local M={};local Set={};Set.__index=Set
local profiles={
  {command='codex',provider='codex',name='Codex',utilities={'help','completion','login','logout','mcp','mcp-server','debug','features',
    'agents','plugin','app-server','remote-control','app','update','doctor','sandbox','apply','a','queue','archive','delete','migrate-rollouts','unarchive','cloud','exec-server'}},
  {command='claude',provider='claude',name='Claude Code',utilities={'-v','doctor','install','update','upgrade','mcp','plugin','plugins','auth',
    'agents','auto-mode','gateway','import','logs','purge','respawn','rm','setup-token','stop','kill'}},
  {command='opencode',provider='opencode',name='OpenCode',utilities={'-v','auth','upgrade','uninstall','completion','debug','models','mcp'}},
  {command='gemini',provider='gemini',name='Gemini CLI',utilities={'-v','extensions','mcp'}},
  {command='boggart',provider='boggart',name='Boggart',utilities={'ctl','init','doctor','models','tracker','story','serve','--eval','--reset'}},
}
local function quote(s)return "'"..s:gsub("'","'\\''").."'"end
local function executable(path)
  local info=uv.fs_stat(path)
  return info and info.type=='file' and uv.fs_access(path,'X') and path or nil
end
local function absolute(path,cwd)return path:sub(1,1)=='/' and path or cwd..'/'..path end
local function same(a,b)return a and b and a.dev==b.dev and a.ino==b.ino end
function Set:cleanup()
  for _,entry in ipairs(self.files)do
    if same(uv.fs_lstat(entry.path),entry.identity)then uv.fs_unlink(entry.path)end
  end
  self.files={}
  for i=#self.directories,1,-1 do local entry=self.directories[i]
    if same(uv.fs_lstat(entry.path),entry.identity)then uv.fs_rmdir(entry.path)end
  end
  self.directories={}
end
function Set:directory(path)
  local ok,why=uv.fs_mkdir(path,448);if not ok then return nil,why end
  self.directories[#self.directories+1]={path=path,identity=uv.fs_lstat(path)};return true
end
function Set:write(path,text,mode)
  local fd,why=uv.fs_open(path,'wx',mode or 384);if not fd then return nil,why end
  self.files[#self.files+1]={path=path,identity=uv.fs_fstat(fd)}
  local written,error=uv.fs_write(fd,text,-1);uv.fs_close(fd)
  if written~=#text then return nil,error or 'incomplete wrapper write'end
  return true
end
function Set:arguments(provider,args)
  local out={}
  if provider=='claude' and self.claude_plugin then out[1]='--plugin-dir='..self.claude_plugin end
  for _,arg in ipairs(args or {})do out[#out+1]=arg end;return out
end
function M.install(opts)
  if opts.disabled or package.config:sub(1,1)=='\\' then return nil,'automatic wrappers disabled'end
  local info=uv.fs_lstat(opts.directory)
  if not info or info.type~='directory' or info.mode&63~=0 or info.uid~=uv.os_get_passwd().uid then return nil,'wrapper parent must be private and owned'end
  local cwd=opts.cwd or uv.cwd()
  local path=opts.path or '/usr/bin:/bin';if #path>60000 or path:find('\0',1,true)then return nil,'invalid wrapper PATH'end
  local previous=opts.previous_bin and uv.fs_stat(opts.previous_bin)
  local parts,search={},{}
  for part in (path..':'):gmatch('(.-):')do
    local dir=absolute(part=='' and '.' or part,cwd)
    if not same(uv.fs_stat(dir),previous)then parts[#parts+1]=part;search[#search+1]=dir end
  end
  local cli
  if opts.executable:find('/',1,true)then cli=executable(absolute(opts.executable,cwd))
  else for _,dir in ipairs(search)do cli=executable(dir..'/'..opts.executable);if cli then break end end end
  if not cli then return nil,'native boggart executable unavailable'end
  local set=setmetatable({bin=opts.directory..'/bin',root=opts.directory,files={},directories={},commands={}},Set)
  local created,why=set:directory(set.bin);if not created then return nil,why end
  -- Resolve first so the optional plugin exists before its command is written.
  for _,profile in ipairs(profiles)do
    local target=profile.command=='boggart' and cli or nil
    if not target then for _,dir in ipairs(search)do target=executable(dir..'/'..profile.command);if target then break end end end
    set.commands[profile.command]=target
  end
  if set.commands.claude then
    local installed,error=require('providerhooks').install(set,cli)
    if not installed then set:cleanup();return nil,error end
  end
  for _,profile in ipairs(profiles)do
    local target=set.commands[profile.command]
    if target then
      local patterns={quote('--help'),quote('-h'),quote('--version'),quote('-V')}
      for _,name in ipairs(profile.utilities)do patterns[#patterns+1]=quote(name)end
      local exec='exec '..quote(target)..' "$@"\n'
      local options='';for _,arg in ipairs(set:arguments(profile.provider))do options=options..' '..quote(arg)end
      local script='#!/bin/sh\n# Temporary BMUX command wrapper.\n'
        ..'if [ "${BOGGART_AGENT_HOOKS-}" = 0 ]; then '..exec..'fi\n'
        ..'case "${1-}" in '..table.concat(patterns,'|')..') '..exec..';;\nesac\n'
        ..'exec '..quote(cli)..' ctl run --best-effort --provider '..quote(profile.provider)..' --name '..quote(profile.name)..' -- '..quote(target)..options..' "$@"\n'
      local file=set.bin..'/'..profile.command
      local written,error=set:write(file,script,448)
      if not written then set:cleanup();return nil,error end
    end
  end
  set.path=set.bin..':'..table.concat(parts,':');return set
end
return M
