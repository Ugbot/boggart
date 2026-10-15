-- Profiles launch native executables, never a shell-expanded prompt string.
local core=require 'core'
local agents=require 'core.fleetagents'
local uv=require 'uv'
local M={}
local suffix=package.config:sub(1,1)=='\\' and '.exe' or ''
local function file(path)
  local info=system.get_file_info(path);return info and info.type=='file' and path or nil
end
function M.boggart_command()
  local sibling=file(EXEDIR..'/boggart'..suffix);if sibling then return sibling end
  local real=DATADIR~='@assets' and uv.fs_realpath(DATADIR)
  local source=real and real:match('^(.*)/studio/data$')
  return (source and file(source..'/boggart'..suffix)) or 'boggart'
end
function M.launch(profile,opts)
  opts=opts or {};assert(type(profile)=='table' and type(profile.cmd)=='string' and profile.cmd~='' and #profile.cmd<=4096 and not profile.cmd:find('\0',1,true), 'agent executable required')
  assert(opts.cwd==nil or type(opts.cwd)=='string' and #opts.cwd<=4096 and not opts.cwd:find('\0',1,true),'invalid agent directory')
  assert(profile.args==nil or type(profile.args)=='table','invalid agent arguments')
  local args={}
  local source=profile.args or {}
  local count=#source;assert(count<=128,'too many agent arguments')
  for key in pairs(source)do assert(type(key)=='number' and key%1==0 and key>=1 and key<=count,'invalid agent argument index')end
  for i=1,count do
    local arg=source[i]
    assert(i<=128 and type(arg)=='string' and #arg<=16384 and not arg:find('\0',1,true),'invalid agent argument')
    args[i]=arg
  end
  local rec=agents.registry:register{provider=profile.provider,name=profile.name,cwd=opts.cwd or core.project_dir,session_id=opts.session_id}
  local ok,view=pcall(require('shell.workspaces.bmux').open,opts.dir,
    {cmd=profile.cmd,args=args,title=profile.name,cwd=opts.cwd,control=profile.provider=='boggart'})
  if not ok then agents.registry:retire(rec.id,rec.generation,'failed',tostring(view));return nil,view end
  rec.cwd=view.bmux_cwd
  agents.bind(rec,view)
  core.redraw=true
  return rec,view
end
function M.boggart(resume_id)
  local args={'--tui'}
  if resume_id then args[#args+1]='--resume';args[#args+1]=tostring(resume_id)end
  if resume_id then
    for _,rec in ipairs(agents.registry:records())do
      if rec.provider=='boggart' and tostring(rec.session_id)==tostring(resume_id) and rec.capabilities and rec.capabilities.focus
        and rec.state~='exited' and rec.state~='failed' and rec.state~='stopped' then
        agents.registry:control(rec.id,rec.generation,'focus');return rec
      end
    end
  end
  return M.launch({provider='boggart',name='Boggart TUI',cmd=M.boggart_command(),args=args},{session_id=resume_id})
end
function M.choose()
  local choices={
    {text='Boggart TUI',provider='boggart',cmd=M.boggart_command(),args={'--tui'},name='Boggart TUI'},
    {text='Resume Boggart TUI',resume=true},
    {text='Codex',provider='codex',cmd='codex',name='Codex'},
    {text='Claude Code',provider='claude',cmd='claude',name='Claude Code'},
    {text='Custom agent command',custom=true},
  }
  require('shell.modal').chooser('New agent',choices,function(pick)
    if pick.resume then
      local sessions={}
      for _,s in ipairs(bog.store.sess_list(50))do
        sessions[#sessions+1]={text=tostring(s.id)..'  '..(s.title or '(untitled)'),session_id=s.id}
      end
      if #sessions==0 then core.log('No saved Boggart sessions');return end
      require('shell.modal').chooser('Resume Boggart TUI',sessions,function(s)M.boggart(s.session_id)end)
    elseif pick.custom then
      core.command_view:enter('Agent command (quoted arguments)',function(text)
        local ok,argv=pcall(require('agentargv').parse,text)
        if not ok then core.error('%s',argv);return end
        local args={};for i=2,#argv do args[#args+1]=argv[i]end
        M.launch{provider='custom',name=argv[1]:match('([^/\\]+)$') or 'Custom agent',cmd=argv[1],args=args}
      end)
    else M.launch(pick)end
  end)
end
return M
