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
  self.files={};uv.fs_rmdir(self.bin)
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
  local set=setmetatable({bin=opts.directory..'/bin',files={},commands={}},Set)
  local created,why=uv.fs_mkdir(set.bin,448);if not created then return nil,why end
  for _,profile in ipairs(profiles)do
    local target=profile.command=='boggart' and cli or nil
    if not target then
      for _,dir in ipairs(search)do target=executable(dir..'/'..profile.command);if target then break end end
    end
    if target then
      local patterns={quote('--help'),quote('-h'),quote('--version'),quote('-V')}
      for _,name in ipairs(profile.utilities)do patterns[#patterns+1]=quote(name)end
      local exec='exec '..quote(target)..' "$@"\n'
      local script='#!/bin/sh\n# Temporary BMUX command wrapper.\n'
        ..'if [ "${BOGGART_AGENT_HOOKS-}" = 0 ]; then '..exec..'fi\n'
        ..'case "${1-}" in '..table.concat(patterns,'|')..') '..exec..';;\nesac\n'
        ..'exec '..quote(cli)..' ctl run --best-effort --provider '..quote(profile.provider)..' --name '..quote(profile.name)..' -- '..quote(target)..' "$@"\n'
      local file=set.bin..'/'..profile.command
      local fd,error=uv.fs_open(file,'wx',448)
      if not fd then set:cleanup();return nil,error end
      set.files[#set.files+1]={path=file,identity=uv.fs_fstat(fd)}
      local written,write_error=uv.fs_write(fd,script,-1);uv.fs_close(fd)
      if written~=#script then set:cleanup();return nil,write_error or 'incomplete wrapper write'end
      set.commands[profile.command]=target
    end
  end
  set.path=set.bin..':'..table.concat(parts,':');return set
end
return M
