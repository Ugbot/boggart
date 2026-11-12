-- Real command-built hierarchy with aliases, mixed agent IDs and hidden zoom.
return function()
  local Layout=require 'bmux.layout'
  local host=Layout.new{host_id='checkpoint-old-host',resolve=function(v)
    return v.kind=='terminal'and v.terminal_id=='old-shell'and v.generation==7
      or v.kind=='agent'and(v.agent_id=='old-agent'or v.agent_id==11)
  end}
  local function command(op,fields)
    local c={host_id=host.host_id,revision=host.revision,op=op}
    for k,v in pairs(fields or {})do c[k]=v end
    local value,why=host:command(c);assert(value,why and why.message);return value
  end
  local one=command('workspace_create',{title='Main 🦊'}).workspaces[1]
  local surface=one.surfaces[1];local left=surface.tree.id
  local scope={workspace_id=one.id,surface_id=surface.id}
  local function pane(op,fields)
    local c={};for k,v in pairs(scope)do c[k]=v end;for k,v in pairs(fields)do c[k]=v end
    return command(op,c).workspaces[1].surfaces[1]
  end
  local first=pane('view_add',{pane_id=left,view={kind='terminal',terminal_id='old-shell',generation=7,title='Shell é'}}).tree.views[1].id
  pane('view_add',{pane_id=left,view={kind='terminal',terminal_id='old-shell',generation=7,title='Alias 🇬🇧'}})
  local s=pane('pane_split',{pane_id=left,direction='right',view={kind='agent',agent_id='old-agent',title='Agent 👩‍💻'}})
  pane('split_resize',{split_id=s.tree.id,ratio=.7})
  pane('pane_split',{pane_id=s.tree.b.id,direction='down',view={kind='agent',agent_id=11}})
  pane('pane_focus',{pane_id=left,view_id=first});pane('pane_zoom',{pane_id=left})
  command('surface_create',{workspace_id=one.id,title='Tools'})
  command('surface_select',{workspace_id=one.id,surface_id=surface.id})
  command('workspace_create',{title='Other'})
  command('workspace_select',{workspace_id=one.id})
  return host,{
    v=1,layout=host:snapshot(),
    terminals={
      {id='old-shell',generation=7,cwd='/tmp/work tree',cols=80,rows=24,history=2000,launch='shell',program='/bin/zsh',lines={'earlier é','👩‍💻 🇬🇧',''}},
      {id='old-agent-terminal',generation=9,cwd='/work',cols=100,rows=30,history=2000,launch='saved',program='/path/boggart',lines={'previous agent output'}},
    },
    agents={
      {id='old-agent',generation=3,provider='boggart',name='Boggart TUI',terminal_id='old-agent-terminal',terminal_generation=9,launch='boggart',resume_id=42},
      {id=11,generation=1,provider='boggart',name='Internal record',launch='saved'},
    },
  }
end
